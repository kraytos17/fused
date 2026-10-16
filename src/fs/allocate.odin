// allocate.odin — Sector allocator.
#+build linux
package fs

import "core:container/bit_array"
import "core:log"

@(cold)
_allocate_io_err_single :: proc() -> FS_Error { return .Sector_Write_Error }

@(cold)
_allocate_io_err :: proc() -> (Cluster, Sector_Offset, FS_Error) {
	return 0, 0, .Sector_Write_Error
}

// _plan_append records one CE-table write in the in-progress plan,
// flushing a full chunk through the journal first (log-before-home per
// ADR-001). Same-slot repeats collapse to the latest value: a link patch
// supersedes the initial write, and each flushed chunk stays
// independently replayable.
@(private = "file")
_plan_append :: proc(vol: ^Volume, plan: ^[dynamic]Journal_Entry, e: Journal_Entry) -> FS_Error {
	for &w in plan^ {
		if w.cluster == e.cluster && w.ce_index == e.ce_index {
			w = e
			return .None
		}
	}
	if len(plan) >= MAX_JOURNAL_ENTRIES {
		if ferr := journal_flush_chunk(vol, plan[:]); ferr != .None {
			return ferr
		}
		clear(plan)
	}
	append(plan, e)
	return .None
}

@(private = "file")
_find_contiguous_free :: proc(
	bitmap: ^bit_array.Bit_Array,
	total_sectors: u64,
	needed: u16,
) -> (
	start: u16,
	available: u16,
	ok: bool,
) {
	run_start: Maybe(u16)
	run_len: u16 = 0
	max_s := int(min(total_sectors, 65535))
	it := bit_array.make_iterator(bitmap)
	for set, s in bit_array.iterate_by_all(&it) {
		if s >= max_s {
			break
		}
		if set {
			if st, found := run_start.?; found && run_len >= needed {
				return st, run_len, true
			}

			run_start = nil
			run_len = 0
		} else {
			if run_start == nil {
				run_start = u16(s)
			}

			run_len += 1
			if st, found := run_start.?; found && run_len >= needed {
				return st, run_len, true
			}
		}
	}
	if st, found := run_start.?; found && run_len > 0 {
		return st, run_len, true
	}
	return 0, 0, false
}

// _is_cluster_full checks whether every sector in the cluster bitmap is allocated.
@(private = "file")
_is_cluster_full :: proc(bitmap: ^bit_array.Bit_Array, total_sectors: u64) -> bool {
	max_s := int(min(total_sectors, 65535))
	it := bit_array.make_iterator(bitmap)
	for set, s in bit_array.iterate_by_all(&it) {
		if s >= max_s {
			break
		}
		if !set {
			return false
		}
	}
	return true
}

// _cluster_entry_state_for returns the Cluster_Entry_State corresponding to the
// given Allocation_Kind (e.g. Directory, File_Content, Cluster_Map, LFN).
@(private = "file")
_cluster_entry_state_for :: proc(kind: Allocation_Kind) -> Cluster_Entry_State {
	switch kind {
	case .Directory:
		return {.Directory}
	case .File_Content:
		return {.File_Content}
	case .Cluster_Map:
		return {.Cluster_Map}
	case .LFN:
		return {.LFN}
	case .XAttr:
		return {.XAttr}
	}
	return {}
}

// _allocate_additional_needed subtracts existing coverage from sectors_needed.
// Returns covered=true when the chain already spans the request (caller
// returns start unchanged). Lookup failures propagate as FS_Error.
@(private = "file")
_allocate_additional_needed :: proc(
	vol: ^Volume,
	start: Chain_Location,
	sectors_needed: u64,
) -> (
	additional: u64,
	covered: bool,
	err: FS_Error,
) {
	if start.cluster == 0 {
		return sectors_needed, false, .None
	}

	existing := resolve_extents(vol, start) or_return
	defer delete(existing)

	existing_sectors: u64
	for r in existing {
		existing_sectors += u64(r.count)
	}
	if sectors_needed <= existing_sectors {
		return 0, true, .None
	}
	return sectors_needed - existing_sectors, false, .None
}

// _allocate_init_fresh marks a never-allocated cluster live and zeroes its
// entry table sector. I/O failures propagate as FS_Error.
@(private = "file")
_allocate_init_fresh :: proc(vol: ^Volume, cluster_idx: u64, cme: ^Cluster_Map_Entry) -> FS_Error {
	cme.flags += {.Allocated}
	cme.sector_index = 0
	write_cluster_map_entry(vol, Cluster(cluster_idx), cme) or_return

	zero_buf: [SECTOR_SIZE]u8
	table_sector := Sector(cluster_idx * vol.master.cluster_size + u64(cme.sector_index))
	if sector_write(vol, table_sector, zero_buf[:]) != .None {
		return .Sector_Write_Error
	}
	return .None
}

// _note_full_deferred records a cluster whose fill completes in this op.
// Full-marks apply only after the fills are durable (see the final flush
// below): marking eagerly would strand free space and corrupt the free
// count if the op later failed. The bitmaps stay authoritative, so an
// unmarked full cluster only costs a re-scan.
@(private = "file")
_note_full_deferred :: proc(marks: ^[dynamic]u64, cluster_idx: u64) {
	for m in marks^ {
		if m == cluster_idx { return }
	}
	append(marks, cluster_idx)
}

// _allocate_append_link records the predecessor's link patch in the plan.
// The patch carries the tracked table index (never re-derived from the
// sector offset). When the slot already left the plan through a mid-scan
// flush, the flushed write is verified on disk first; a missing
// predecessor fails the allocation. Nothing is written home here.
@(private = "file")
_allocate_append_link :: proc(
	vol: ^Volume,
	plan: ^[dynamic]Journal_Entry,
	prev_cluster: Cluster,
	prev_idx: int,
	prev_entry: Cluster_Entry,
) -> FS_Error {
	rec := journal_entry_from_cluster_entry(prev_entry, u64(prev_cluster), u8(prev_idx))
	in_plan := false
	for w in plan^ {
		if w.cluster == rec.cluster && w.ce_index == rec.ce_index { in_plan = true; break }
	}
	if !in_plan {
		prev_table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
		read_cluster_entry_table(vol, prev_cluster, &prev_table) or_return
		pidx, pok := ce_find_by_offset(prev_table, Sector_Offset(prev_entry.sector_start))
		if !pok || pidx != prev_idx || .Allocated not_in prev_table[pidx].state {
			log.errorf("allocate: predecessor entry not found (corrupted)")
			return .Entry_Not_Found
		}
	}
	return _plan_append(vol, plan, rec)
}

// allocate_sectors allocates contiguous sectors on a volume.
//
// Extension logic: if start.cluster != 0, existing extents are resolved and
// their sector count is subtracted from sectors_needed to compute additional_needed.
// If the existing chain already covers the request, start is
// returned immediately.
//
// Cluster-map scan: starting from vol.cache.hint, each cluster-map entry is examined.
// Fresh (unallocated) clusters are initialised and zeroed. A per-cluster bitmap is
// consulted via _find_contiguous_free; if no run is found the CME is marked Full and
// skipped. An unused slot in the cluster-entry table is located and filled with a new
// Cluster_Entry carrying the allocation size, sector start, and state derived from kind.
//
// Journaling (ADR-001): the scan collects CE writes into a plan without
// touching home; full chunks flush through the journal mid-scan and the
// tail chunk flushes at the end (log before home). A failed op persists
// nothing uncommitted; committed chunks replay idempotently.
//
// Tail-chain linking: when extending an existing chain (start.cluster != 0),
// _link_tail_to_new walks the old chain and appends the first newly allocated cluster,
// persisting the updated predecessor entry.
//
// Error returns: .Sector_Write_Error on I/O failure, .Entry_Not_Found if the tail
// cannot be located, or .No_Space when the cluster map is exhausted.
allocate_sectors :: proc(
	vol: ^Volume,
	start: Chain_Location,
	sectors_needed: u64,
	kind: Allocation_Kind,
) -> (
	first_cluster: Cluster,
	first_offset: Sector_Offset,
	err: FS_Error,
) {
	if sectors_needed == 0 {
		return start.cluster, start.offset, .None
	}

	additional_needed, covered := _allocate_additional_needed(vol, start, sectors_needed) or_return
	if covered {
		return start.cluster, start.offset, .None
	}

	remaining: u64 = additional_needed
	is_first := true
	prev_cluster: Cluster
	prev_idx := -1
	prev_entry: Cluster_Entry
	prev_has_prev := false

	// Plan-first collection: the scan records CE writes without touching
	// home; chunks flush through the journal as they fill (see
	// _plan_append) and the tail chunk flushes at the end. Any error
	// below drops the unflushed tail plan, persisting nothing new.
	plan := make([dynamic]Journal_Entry, 0, MAX_JOURNAL_ENTRIES + 1)
	defer delete(plan)
	full_marks := make([dynamic]u64, 0, 8)
	defer delete(full_marks)

	start_hint := vol.cache.hint
	for iter in 0 ..< vol.master.cluster_map_size {
		cluster_idx := (start_hint + iter) % vol.master.cluster_map_size
		cme := read_cluster_map_entry(vol, Cluster(cluster_idx)) or_continue
		if .Reserved in cme.flags || .Full in cme.flags {
			continue
		}
		if .Allocated not_in cme.flags {
			if ierr := _allocate_init_fresh(vol, cluster_idx, &cme); ierr != .None {
				return 0, 0, ierr
			}
		}

		bitmap, used, var_err := alloc_cache_ensure(&vol.cache, vol, cluster_idx)
		if var_err != .None {
			continue
		}

		free_start, free_avail, free_ok := _find_contiguous_free(
			&bitmap,
			vol.master.cluster_size,
			u16(min(remaining, 65535)),
		)
		if !free_ok {
			_note_full_deferred(&full_marks, cluster_idx)
			continue
		}

		take := u16(min(u64(free_avail), remaining))
		if take == 0 {
			continue
		}

		table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
		read_cluster_entry_table(vol, Cluster(cluster_idx), &table) or_continue
		free_idx := -1
		#unroll for j in 0 ..< CLUSTER_ENTRIES_PER_SECTOR {
			if free_idx < 0 && .Allocated not_in table[j].state {
				free_idx = j
			}
		}
		if free_idx < 0 {
			continue
		}

		new_entry := Cluster_Entry {
			state             = _cluster_entry_state_for(kind) | {.Allocated},
			allocation_size   = take,
			sector_start      = free_start,
			next_cluster      = 0,
			next_sector_index = 0,
		}

		if perr := _plan_append(
			vol,
			&plan,
			journal_entry_from_cluster_entry(new_entry, cluster_idx, u8(free_idx)),
		); perr != .None {
			return 0, 0, perr
		}
		if is_first {
			first_cluster = Cluster(cluster_idx)
			first_offset = Sector_Offset(free_start)
			is_first = false
		} else if prev_has_prev {
			prev_entry.next_cluster = u64(cluster_idx)
			prev_entry.next_sector_index = u16(free_start)
			if lerr := _allocate_append_link(vol, &plan, prev_cluster, prev_idx, prev_entry); lerr != .None {
				return 0, 0, lerr
			}
		}

		prev_cluster = Cluster(cluster_idx)
		prev_idx = free_idx
		prev_entry = new_entry
		prev_has_prev = true
		remaining -= u64(take)
		if used + take >= u16(vol.master.cluster_size) {
			_note_full_deferred(&full_marks, cluster_idx)
		}
		if remaining == 0 {
			break
		}
	}
	if remaining > 0 {
		log.errorf("allocate: No_Space — needed %d, %d remaining", sectors_needed, remaining)
		return 0, 0, .No_Space
	}
	if start.cluster != 0 && !is_first {
		if lerr := _link_tail_to_new(vol, &plan, start, Chain_Location{first_cluster, first_offset});
		   lerr != .None {
			return 0, 0, lerr
		}
	}

	log.debugf("allocate: ok — %d sectors across %d clusters", sectors_needed, first_cluster)
	vol.cache.hint = (u64(first_cluster) + 1) % vol.master.cluster_map_size
	if ferr := journal_flush_chunk(vol, plan[:]); ferr != .None {
		return 0, 0, ferr
	}
	// The fills are durable now: publish deferred Full-marks best-effort.
	// A failed mark only costs the next scan a re-walk (bitmaps rule).
	for mc in full_marks {
		if mcme, merr := read_cluster_map_entry(vol, Cluster(mc)); merr == .None {
			if .Full not_in mcme.flags {
				mcme.flags += {.Full}
				_ = write_cluster_map_entry(vol, Cluster(mc), &mcme)
			}
		}
	}
	if start.cluster != 0 && !is_first {
		return start.cluster, start.offset, .None
	}
	return first_cluster, first_offset, .None
}

// deallocate_sectors frees a chain of cluster entries starting at start.
// Each entry has its Allocated flag cleared; if the owning CME was marked
// Full, that flag is also removed. Clears collect into a plan and flush
// through the journal log-before-home (ADR-001), so a crash cannot resurrect
// the freed chain and a failed op persists nothing uncommitted.
deallocate_sectors :: proc(vol: ^Volume, start: Chain_Location) -> FS_Error {
	if start.cluster == 0 {
		return .None
	}

	plan := make([dynamic]Journal_Entry, 0, MAX_JOURNAL_ENTRIES + 1)
	defer delete(plan)

	current_cluster := start.cluster
	current_offset := start.offset
	for guard in 0 ..< int(vol.master.cluster_map_size) + 1 {
		if guard == int(vol.master.cluster_map_size) {
			log.errorf("deallocate: chain too long (corrupted)")
			return .Entry_Not_Found
		}

		// The table index comes from the allocated-entry lookup itself, so a
		// stale duplicate offset can never divert the write to the wrong slot.
		table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
		freed_idx := -1
		entry := find_cluster_entry(vol, current_cluster, current_offset, &table, &freed_idx) or_return
		entry.state -= {.Allocated}
		cme, cme_err := read_cluster_map_entry(vol, current_cluster)
		if cme_err == .None && .Full in cme.flags {
			cme.flags -= {.Full}
			write_cluster_map_entry(vol, current_cluster, &cme) or_return
		}

		if perr := _plan_append(
			vol,
			&plan,
			journal_entry_from_cluster_entry(entry, u64(current_cluster), u8(freed_idx)),
		); perr != .None {
			return perr
		}
		if entry.next_cluster == 0 {
			break
		}

		current_cluster = Cluster(entry.next_cluster)
		current_offset = Sector_Offset(entry.next_sector_index)
	}
	if ferr := journal_flush_chunk(vol, plan[:]); ferr != .None {
		return ferr
	}

	log.debugf("deallocate: ok — cluster=%d offset=%d", start.cluster, start.offset)
	return .None
	}

// _link_tail_to_new walks the existing chain from start to its final
// entry and records the next_cluster / next_sector_index patch in the
// plan, effectively appending the newly allocated cluster(s). A missing
// tail entry fails the allocation. Nothing is written home here.
@(private = "file")
_link_tail_to_new :: proc(vol: ^Volume, plan: ^[dynamic]Journal_Entry, start, first: Chain_Location) -> FS_Error {
	walk := _chain_walk_start(vol, start.cluster, start.offset)
	for walk.guard < walk.limit {
		tail, tc, step := _chain_next(vol, &walk)
		if step == .Corrupted {
			log.errorf("allocate: tail chain too long (corrupted)")
			return .Corrupt_Master_Record
		}
		if tail.next_cluster == 0 {
			tail.next_cluster = u64(first.cluster)
			tail.next_sector_index = u16(first.offset)
			tail_table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
			if rerr := read_cluster_entry_table(vol, tc, &tail_table); rerr != .None {
				return rerr
			}
			tidx, tok := ce_find_by_offset(tail_table, walk.cursor.offset)
			if !tok || .Allocated not_in tail_table[tidx].state {
				log.errorf("allocate: tail entry not found (corrupted)")
				return .Entry_Not_Found
			}
			if perr := _plan_append(vol, plan, journal_entry_from_cluster_entry(tail, u64(tc), u8(tidx))); perr != .None {
				return perr
			}
			break
		}
	}
	return .None
}
