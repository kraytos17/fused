// check.odin — read-only structural consistency scanner (checker Stage A).
//
// Walks every CME and CE table straight from disk (never the alloc
// cache), validates flags, ranges, chain links, and sector ownership,
// and compares an independent free-sector count against
// alloc_cache_count_free. Directory reachability and orphan analysis
// need the directory walk (Stage B): this pass proves the allocation
// substrate — no overlaps, no dangling links, no cycles — and a
// coherent free count.
//
// The scan is read-only: the only writes it performs are none (all
// sector I/O is sector_read). Findings carry stable machine-readable
// codes; the caller decides exit status.
#+build linux
package fs

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

// Check_Severity distinguishes scan failures (Error) from suspicious but
// tolerable states (Warning). Stage A emits errors only.
Check_Severity :: enum {
	Error,
	Warning,
}

// Check_Finding is one scan result. cluster/index locate the record
// (index is -1 and cluster is max(u64) when not applicable). detail is
// heap-allocated with the report allocator.
Check_Finding :: struct {
	severity: Check_Severity,
	code:     string,
	cluster:  u64,
	index:    int,
	detail:   string,
}

// Check_Report aggregates scan findings. Destroy with
// check_report_destroy.
Check_Report :: struct {
	errors:   int,
	warnings: int,
	findings: [dynamic]Check_Finding,
}

// check_report_destroy frees finding details and the finding array.
check_report_destroy :: proc(r: ^Check_Report) {
	for &f in r.findings {
		delete(f.detail)
	}
	delete(r.findings)
	r^ = {}
}

// _check_add appends a finding with a formatted detail string.
@(private = "file")
_check_add :: proc(
	r: ^Check_Report,
	sev: Check_Severity,
	code: string,
	cluster: u64,
	index: int,
	allocator: mem.Allocator,
	format: string,
	args: ..any,
) {
	detail := strings.clone(fmt.tprintf(format, ..args), allocator)
	append(&r.findings, Check_Finding{severity = sev, code = code, cluster = cluster, index = index, detail = detail})
	if sev == .Error {
		r.errors += 1
	} else {
		r.warnings += 1
	}
}

// check_image runs the Stage A structural scan over vol. Read-only:
// every sector access is a sector_read; the alloc cache is consulted
// only for the final free-count comparison.
check_image :: proc(vol: ^Volume, allocator := context.allocator) -> Check_Report {
	r: Check_Report
	r.findings = make([dynamic]Check_Finding, 0, 32, allocator)

	cs := u64(vol.master.cluster_size)
	map_size := u64(vol.master.cluster_map_size)
	if cs == 0 || map_size == 0 {
		_check_add(&r, .Error, "Geometry", max(u64), -1, allocator, "zero cluster size or map size")
		return r
	}

	// Image size in sectors: prefer the opened volume's record, fall
	// back to fstat (test volumes opened on bare fds have no size).
	sector_count := u64(vol.image_size) / SECTOR_SIZE
	if sector_count == 0 {
		if fi, ferr := os.fstat(vol.disk, context.temp_allocator); ferr == nil {
			sector_count = u64(fi.size) / SECTOR_SIZE
		}
	}

	// Metadata region bounds with overflow-safe arithmetic.
	cm_sectors := (map_size + u64(CLUSTER_MAP_ENTRIES_PER_SECTOR) - 1) / u64(CLUSTER_MAP_ENTRIES_PER_SECTOR)
	cm_end := u64(vol.master.cluster_map_offset) + cm_sectors
	if cm_end < u64(vol.master.cluster_map_offset) || (sector_count > 0 && cm_end > sector_count) {
		_check_add(&r, .Error, "CmeBounds", max(u64), -1, allocator, "cluster-map region [%d, %d) outside image (%d sectors)", u64(vol.master.cluster_map_offset), cm_end, sector_count)
	}
	J := u64(journal_region_base(&vol.master))
	M := journal_region_size(&vol.master)
	if M == 0 || J + M < J || (sector_count > 0 && J + M > sector_count) {
		_check_add(&r, .Error, "JournalBounds", max(u64), -1, allocator, "journal region [%d, %d) outside image (%d sectors)", J, J + M, sector_count)
	}

	total := map_size * cs
	owned := make([]bool, total, context.temp_allocator)
	owner_c := make([]u64, total, context.temp_allocator)
	owner_i := make([]int, total, context.temp_allocator)
	verified := make([]bool, map_size * u64(CLUSTER_ENTRIES_PER_SECTOR), context.temp_allocator)
	read_errors := 0

	// _mark claims one global sector for (cluster, index): false when
	// already owned (caller reports DoubleOwnership with the first owner).
	_mark :: proc(
		owned: []bool, owner_c: []u64, owner_i: []int, sec: u64,
		c: u64, idx: int,
	) -> (prev_c: u64, prev_i: int, clash: bool) {
		if owned[sec] {
			return owner_c[sec], owner_i[sec], true
		}
		owned[sec] = true
		owner_c[sec] = c
		owner_i[sec] = idx
		return 0, 0, false
	}

	free_scan: u64 = 0
	for ci in 0 ..< map_size {
		cme, cerr := read_cluster_map_entry(vol, Cluster(ci))
		if cerr != .None {
			_check_add(&r, .Error, "CmeRead", ci, -1, allocator, "cannot read cluster-map entry: %v", cerr)
			read_errors += 1
			continue
		}
		if .Reserved in cme.flags && .Allocated in cme.flags {
			_check_add(&r, .Error, "FlagCombo", ci, -1, allocator, "cluster map entry is both Reserved and Allocated")
		}
		if u64(cme.sector_index) >= cs {
			_check_add(&r, .Error, "TableRange", ci, -1, allocator, "table sector index %d outside cluster size %d", u64(cme.sector_index), cs)
		}

		// Mirror alloc_cache_count_free: Reserved/Full clusters
		// contribute nothing; other clusters contribute unset bits.
		// The table sector bit matches the cache build (set whenever
		// the index is in range, even for unallocated CMEs).
		reserved_or_full := .Reserved in cme.flags || .Full in cme.flags
		table_bit := u64(cme.sector_index) < cs

		if .Allocated not_in cme.flags {
			if !reserved_or_full && table_bit {
				free_scan += cs - 1
			} else if !reserved_or_full {
				free_scan += cs
			}
			continue
		}

		table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
		if terr := read_cluster_entry_table(vol, Cluster(ci), &table); terr != .None {
			_check_add(&r, .Error, "TableRead", ci, -1, allocator, "cannot read entry table: %v", terr)
			read_errors += 1
			continue
		}

		// The table sector is metadata: claim it before data ranges.
		tsec := ci * cs + u64(cme.sector_index)
		if table_bit {
			if pc, pi, clash := _mark(owned, owner_c, owner_i, tsec, ci, -1); clash {
				_check_add(&r, .Error, "DoubleOwnership", ci, -1, allocator, "table sector %d owned by cluster %d entry %d", tsec, pc, pi)
			}
		}
		live_bytes: u64 = 0
		for &e, ei in table {
			if .Allocated not_in e.state { continue }
			if e.allocation_size == 0 {
				_check_add(&r, .Error, "ZeroSize", ci, ei, allocator, "allocated entry has zero size")
				continue
			}
			if u64(e.sector_start) + u64(e.allocation_size) > cs {
				_check_add(&r, .Error, "Range", ci, ei, allocator, "extent [%d, %d) outside cluster size %d", u64(e.sector_start), u64(e.sector_start) + u64(e.allocation_size), cs)
				continue
			}
			// The Cluster_Map pseudo-entry describes the table sector
			// itself (format writes it as [sector_index, +1)): sharing
			// that one sector is by design, not double ownership.
			is_map := .Cluster_Map in e.state
			map_ok := is_map && u64(e.sector_start) == u64(cme.sector_index) && e.allocation_size == 1
			for off in 0 ..< u64(e.allocation_size) {
				sec := ci * cs + u64(e.sector_start) + off
				if pc, pi, clash := _mark(owned, owner_c, owner_i, sec, ci, ei); clash {
					if map_ok && pc == ci && pi == -1 {
						// Already counted via the table bit (set
						// semantics, like the cache bitmap); just
						// record the pseudo-entry as the owner.
						owner_c[sec], owner_i[sec] = ci, ei
					} else {
						_check_add(&r, .Error, "DoubleOwnership", ci, ei, allocator, "sector %d owned by cluster %d entry %d", sec, pc, pi)
					}
				} else {
					live_bytes += 1
				}
			}
			// Chain links: walk with the same rules as _chain_step
			// (offset match + Allocated + nonzero size, guard bound),
			// skipping entries already verified by an earlier walk.
			if e.next_cluster != 0 && !verified[ci*u64(CLUSTER_ENTRIES_PER_SECTOR)+u64(ei)] {
				_check_walk(vol, &r, verified, allocator, map_size, ci, ei, e)
			}
		}
		if !reserved_or_full {
			free_scan += cs - (1 if table_bit else 0) - live_bytes
		}
	}

	// Free agreement against the cache view (independent raw-disk reads
	// above vs. cached bitmaps below). Suppressed when reads failed:
	// those clusters are skipped on both sides and would add noise.
	if read_errors == 0 {
		free_cached := alloc_cache_count_free(vol)
		if free_scan != free_cached {
			_check_add(&r, .Error, "FreeMismatch", max(u64), -1, allocator, "independent free %d != cache free %d", free_scan, free_cached)
		}
	}
	return r
}

// _check_walk validates one chain from its head entry, mirroring
// _chain_step: offset match + Allocated + nonzero size per hop, end at
// next_cluster == 0, abort past map_size+1 links or on revisit.
@(private = "file")
_check_walk :: proc(
	vol: ^Volume,
	r: ^Check_Report,
	verified: []bool,
	allocator: mem.Allocator,
	map_size: u64,
	head_c: u64,
	head_i: int,
	head: Cluster_Entry,
) {
	seen := make([dynamic]u64, 0, 16, context.temp_allocator)
	mark_seen :: proc(seen: ^[dynamic]u64, verified: []bool, c: u64, idx: int) {
		append(seen, c*u64(CLUSTER_ENTRIES_PER_SECTOR)+u64(idx))
		verified[c*u64(CLUSTER_ENTRIES_PER_SECTOR)+u64(idx)] = true
	}
	mark_seen(&seen, verified, head_c, head_i)

	cur_c := u64(head.next_cluster)
	cur_o := u64(head.next_sector_index)
	for _ in 0 ..< int(map_size) + 1 {
		if cur_c >= map_size {
			_check_add(r, .Error, "BadLink", head_c, head_i, allocator, "link %d/%d: cluster %d outside map (size %d)", cur_c, cur_o, cur_c, map_size)
			return
		}
		table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
		if terr := read_cluster_entry_table(vol, Cluster(cur_c), &table); terr != .None {
			_check_add(r, .Error, "LinkRead", head_c, head_i, allocator, "link %d/%d: table unreadable: %v", cur_c, cur_o, terr)
			return
		}
		found := -1
		for &e, ei in table {
			if u64(e.sector_start) == cur_o && .Allocated in e.state {
				found = ei
				break
			}
		}
		if found < 0 || table[found].allocation_size == 0 {
			_check_add(r, .Error, "DanglingLink", head_c, head_i, allocator, "link %d/%d: no live entry", cur_c, cur_o)
			return
		}
		key := cur_c*u64(CLUSTER_ENTRIES_PER_SECTOR)+u64(found)
		for s in seen {
			if s == key {
				_check_add(r, .Error, "Cycle", head_c, head_i, allocator, "link %d/%d revisits entry", cur_c, cur_o)
				return
			}
		}
		mark_seen(&seen, verified, cur_c, found)
		if table[found].next_cluster == 0 {
			return
		}
		cur_c = u64(table[found].next_cluster)
		cur_o = u64(table[found].next_sector_index)
	}
	_check_add(r, .Error, "Cycle", head_c, head_i, allocator, "chain exceeds link bound %d", map_size + 1)
}
