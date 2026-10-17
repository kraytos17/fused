// check_test.odin — checker Stage A regression tests.
//
// Each test formats an isolated scratch image, optionally seeds one
// corruption with raw sector writes (bypassing validation, like disk
// rot would), and asserts the scanner reports the stable finding code.
// Scratch images are removed afterwards; the shared image is untouched.
#+build linux
package tests

import "core:os"
import "core:testing"
import "src:fs"

// check_has_code reports whether the report contains a finding code.
check_has_code :: proc(r: ^fs.Check_Report, code: string) -> bool {
	for &f in r.findings {
		if f.code == code {
			return true
		}
	}
	return false
}

// check_read_raw_table reads a cluster's entry table with raw sector
// I/O (no validation), for seeding corruption.
check_read_raw_table :: proc(
	t: ^testing.T,
	vol: ^fs.Volume,
	c: fs.Cluster,
) -> (
	table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry,
	ok: bool,
) {
	cme, cerr := fs.read_cluster_map_entry(vol, c)
	testing.expect_value(t, cerr, fs.FS_Error.None)
	if cerr != .None { return {}, false }
	sec := fs.sector_for(c, fs.Sector_Offset(cme.sector_index), vol.master.cluster_size)
	buf: [fs.SECTOR_SIZE]u8
	if serr := fs.sector_read(vol, sec, buf[:]); serr != .None {
		testing.expect_value(t, serr, fs.FS_Error.None)
		return {}, false
	}
	raw := (^ [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry)(raw_data(buf[:]))
	return raw^, true
}

// check_write_raw_table writes a cluster's entry table with raw sector
// I/O (no validation), for seeding corruption.
check_write_raw_table :: proc(
	t: ^testing.T,
	vol: ^fs.Volume,
	c: fs.Cluster,
	table: ^[fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry,
) -> bool {
	cme, cerr := fs.read_cluster_map_entry(vol, c)
	testing.expect_value(t, cerr, fs.FS_Error.None)
	if cerr != .None { return false }
	sec := fs.sector_for(c, fs.Sector_Offset(cme.sector_index), vol.master.cluster_size)
	buf: [fs.SECTOR_SIZE]u8
	dst := (^ [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry)(raw_data(buf[:]))
	dst^ = table^
	werr := fs.sector_write(vol, sec, buf[:])
	testing.expect_value(t, werr, fs.FS_Error.None)
	return werr == .None
}

// check_open_scratch formats an isolated image and opens a volume on it.
check_open_scratch :: proc(t: ^testing.T) -> (fs.Volume, bool) {
	fd, ok := jtxn_format(t, JTXN_SCRATCH)
	if !ok { return {}, false }
	vol, vok := open_volume_on_fd(fd)
	if !vok { os.close(fd); os.remove(JTXN_SCRATCH); return {}, false }
	return vol, true
}

// test_check_healthy_empty — a fresh format is clean.
@(test)
test_check_healthy_empty :: proc(t: ^testing.T) {
	vol, ok := check_open_scratch(t)
	if !ok { return }
	defer { close_test_volume(&vol); os.remove(JTXN_SCRATCH) }

	r := fs.check_image(&vol)
	defer fs.check_report_destroy(&r)
	testing.expect_value(t, r.errors, 0)
	testing.expect_value(t, len(r.findings), 0)
}

// test_check_healthy_alloc — live chains are clean and free agrees.
@(test)
test_check_healthy_alloc :: proc(t: ^testing.T) {
	vol, ok := check_open_scratch(t)
	if !ok { return }
	defer { close_test_volume(&vol); os.remove(JTXN_SCRATCH) }

	hc, ho, aerr := fs.allocate_sectors(&vol, {}, 3, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }
	defer fs.deallocate_sectors(&vol, fs.Chain_Location{hc, ho})

	r := fs.check_image(&vol)
	defer fs.check_report_destroy(&r)
	testing.expect_value(t, r.errors, 0)
	testing.expect_value(t, len(r.findings), 0)
}

// test_check_double_ownership — a duplicated live range is flagged.
@(test)
test_check_double_ownership :: proc(t: ^testing.T) {
	vol, ok := check_open_scratch(t)
	if !ok { return }
	defer { close_test_volume(&vol); os.remove(JTXN_SCRATCH) }

	hc, ho, aerr := fs.allocate_sectors(&vol, {}, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }
	defer fs.deallocate_sectors(&vol, fs.Chain_Location{hc, ho})

	table, tok := check_read_raw_table(t, &vol, hc)
	if !tok { return }
	empty: fs.Cluster_Entry_State
	src := -1
	dst := -1
	for j in 0 ..< len(table) {
		if .Allocated in table[j].state && src < 0 {
			src = j
		}
		if table[j].state == empty && dst < 0 {
			dst = j
		}
	}
	testing.expect(t, src >= 0 && dst >= 0, "live and free slots found")
	if src < 0 || dst < 0 { return }
	table[dst] = table[src]
	if !check_write_raw_table(t, &vol, hc, &table) { return }

	r := fs.check_image(&vol)
	defer fs.check_report_destroy(&r)
	testing.expect(t, check_has_code(&r, "DoubleOwnership"), "overlap flagged")
	testing.expect_value(t, r.errors, 1)
}

// test_check_stale_cache_free_mismatch — a live entry planted without
// cache invalidation (simulating a missed invalidate) makes the cache
// disagree with the independent scan. The structure itself is valid, so
// only FreeMismatch fires: the checker must not trust the cache.
@(test)
test_check_stale_cache_free_mismatch :: proc(t: ^testing.T) {
	vol, ok := check_open_scratch(t)
	if !ok { return }
	defer { close_test_volume(&vol); os.remove(JTXN_SCRATCH) }

	hc, ho, aerr := fs.allocate_sectors(&vol, {}, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }
	defer fs.deallocate_sectors(&vol, fs.Chain_Location{hc, ho})

	// Build the cache, then plant a valid standalone entry with raw I/O
	// (no invalidation, like a missed invalidate would leave behind).
	_ = fs.alloc_cache_count_free(&vol)

	table, tok := check_read_raw_table(t, &vol, hc)
	if !tok { return }
	empty: fs.Cluster_Entry_State
	dst := -1
	for j in 0 ..< len(table) {
		if table[j].state == empty {
			dst = j
			break
		}
	}
	testing.expect(t, dst >= 0, "free slot found")
	if dst < 0 { return }
	// Claim the first data sector past the table: owned by nobody else
	// on a fresh scratch cluster... instead reuse the head's own range
	// shape: a second live entry is only valid on a distinct range, so
	// find any free sector in this cluster via the bitmap rule.
	found := false
	for s := 1; s < int(vol.master.cluster_size); s += 1 {
		clash := false
		for &e in table {
			if .Allocated in e.state {
				for off in 0 ..< int(e.allocation_size) {
					if int(e.sector_start) + off == s {
						clash = true
						break
					}
				}
			}
			if clash { break }
		}
		if !clash {
			table[dst] = fs.Cluster_Entry{
				state           = {.Allocated, .File_Content},
				allocation_size = 1,
				sector_start    = u16(s),
			}
			found = true
			break
		}
	}
	testing.expect(t, found, "free sector found")
	if !found { return }
	if !check_write_raw_table(t, &vol, hc, &table) { return }

	r := fs.check_image(&vol)
	defer fs.check_report_destroy(&r)
	testing.expect(t, check_has_code(&r, "FreeMismatch"), "stale cache disagrees")
	testing.expect_value(t, r.errors, 1)
}

// test_check_zero_size — an allocated zero-size entry is corrupt (the
// chain walker treats it as Corrupted).
@(test)
test_check_zero_size :: proc(t: ^testing.T) {
	vol, ok := check_open_scratch(t)
	if !ok { return }
	defer { close_test_volume(&vol); os.remove(JTXN_SCRATCH) }

	hc, ho, aerr := fs.allocate_sectors(&vol, {}, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }
	defer fs.deallocate_sectors(&vol, fs.Chain_Location{hc, ho})

	table, tok := check_read_raw_table(t, &vol, hc)
	if !tok { return }
	slot: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	idx := -1
	_, ferr := fs.find_cluster_entry(&vol, hc, ho, &slot, &idx)
	testing.expect_value(t, ferr, fs.FS_Error.None)
	testing.expect(t, idx >= 0, "own entry found")
	if ferr != .None || idx < 0 { return }
	table[idx].allocation_size = 0
	if !check_write_raw_table(t, &vol, hc, &table) { return }

	r := fs.check_image(&vol)
	defer fs.check_report_destroy(&r)
	testing.expect(t, check_has_code(&r, "ZeroSize"), "zero size flagged")
	testing.expect_value(t, r.errors, 1)
}

// test_check_out_of_range — an extent past the cluster end is corrupt.
@(test)
test_check_out_of_range :: proc(t: ^testing.T) {
	vol, ok := check_open_scratch(t)
	if !ok { return }
	defer { close_test_volume(&vol); os.remove(JTXN_SCRATCH) }

	hc, ho, aerr := fs.allocate_sectors(&vol, {}, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }
	defer fs.deallocate_sectors(&vol, fs.Chain_Location{hc, ho})

	table, tok := check_read_raw_table(t, &vol, hc)
	if !tok { return }
	slot: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	idx := -1
	_, ferr := fs.find_cluster_entry(&vol, hc, ho, &slot, &idx)
	testing.expect_value(t, ferr, fs.FS_Error.None)
	testing.expect(t, idx >= 0, "own entry found")
	if ferr != .None || idx < 0 { return }
	table[idx].sector_start = u16(vol.master.cluster_size)
	if !check_write_raw_table(t, &vol, hc, &table) { return }

	r := fs.check_image(&vol)
	defer fs.check_report_destroy(&r)
	testing.expect(t, check_has_code(&r, "Range"), "out-of-range flagged")
	testing.expect_value(t, r.errors, 1)
}

// test_check_bad_link — a next pointer outside the map is corrupt.
@(test)
test_check_bad_link :: proc(t: ^testing.T) {
	vol, ok := check_open_scratch(t)
	if !ok { return }
	defer { close_test_volume(&vol); os.remove(JTXN_SCRATCH) }

	hc, ho, aerr := fs.allocate_sectors(&vol, {}, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }
	defer fs.deallocate_sectors(&vol, fs.Chain_Location{hc, ho})

	table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	idx := -1
	_, ferr := fs.find_cluster_entry(&vol, hc, ho, &table, &idx)
	testing.expect_value(t, ferr, fs.FS_Error.None)
	if ferr != .None || idx < 0 { return }
	raw, tok := check_read_raw_table(t, &vol, hc)
	if !tok { return }
	raw[idx].next_cluster = u64(vol.master.cluster_map_size) + 7
	raw[idx].next_sector_index = 0
	if !check_write_raw_table(t, &vol, hc, &raw) { return }

	r := fs.check_image(&vol)
	defer fs.check_report_destroy(&r)
	testing.expect(t, check_has_code(&r, "BadLink"), "bad link flagged")
	testing.expect_value(t, r.errors, 1)
}

// test_check_cycle — a two-entry loop is corrupt and reported once.
@(test)
test_check_cycle :: proc(t: ^testing.T) {
	vol, ok := check_open_scratch(t)
	if !ok { return }
	defer { close_test_volume(&vol); os.remove(JTXN_SCRATCH) }

	ha, oa, aerr := fs.allocate_sectors(&vol, {}, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }
	hb, ob, berr := fs.allocate_sectors(&vol, {}, 1, .File_Content)
	testing.expect_value(t, berr, fs.FS_Error.None)
	if berr != .None { return }
	// No deallocate defers: the entries form a cycle below, and chain
	// teardown refuses corrupt chains. The scratch image is removed.

	ta: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	ia := -1
	_, ferr := fs.find_cluster_entry(&vol, ha, oa, &ta, &ia)
	testing.expect_value(t, ferr, fs.FS_Error.None)
	if ferr != .None || ia < 0 { return }
	tb: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	ib := -1
	_, gerr := fs.find_cluster_entry(&vol, hb, ob, &tb, &ib)
	testing.expect_value(t, gerr, fs.FS_Error.None)
	if gerr != .None || ib < 0 { return }

	ra, aok := check_read_raw_table(t, &vol, ha)
	if !aok { return }
	rb, bok := check_read_raw_table(t, &vol, hb)
	if !bok { return }
	ra[ia].next_cluster = u64(hb)
	ra[ia].next_sector_index = u16(ob)
	if ha == hb {
		// Same table: mutate the one copy, write once.
		ra[ib].next_cluster = u64(ha)
		ra[ib].next_sector_index = u16(oa)
		if !check_write_raw_table(t, &vol, ha, &ra) { return }
	} else {
		rb[ib].next_cluster = u64(ha)
		rb[ib].next_sector_index = u16(oa)
		if !check_write_raw_table(t, &vol, ha, &ra) { return }
		if !check_write_raw_table(t, &vol, hb, &rb) { return }
	}

	r := fs.check_image(&vol)
	defer fs.check_report_destroy(&r)
	testing.expect(t, check_has_code(&r, "Cycle"), "cycle flagged")
	testing.expect_value(t, r.errors, 1)
}

// test_check_flag_combo — a Reserved+Allocated CME is corrupt.
@(test)
test_check_flag_combo :: proc(t: ^testing.T) {
	vol, ok := check_open_scratch(t)
	if !ok { return }
	defer { close_test_volume(&vol); os.remove(JTXN_SCRATCH) }

	// Reserved cluster 1 (never the root): flip on Allocated, keeping
	// Reserved. Its table sector is zeroed by format, so no cascade.
	rc := fs.Cluster(1)
	cme, cerr := fs.read_cluster_map_entry(&vol, rc)
	testing.expect_value(t, cerr, fs.FS_Error.None)
	if cerr != .None { return }
	sec := fs.Sector(vol.master.cluster_map_offset + u64(rc) / fs.CLUSTER_MAP_ENTRIES_PER_SECTOR)
	buf: [fs.SECTOR_SIZE]u8
	if serr := fs.sector_read(&vol, sec, buf[:]); serr != .None {
		testing.expect_value(t, serr, fs.FS_Error.None)
		return
	}
	entries := (^ [fs.CLUSTER_MAP_ENTRIES_PER_SECTOR]fs.Cluster_Map_Entry)(raw_data(buf[:]))
	entries[u64(rc) % fs.CLUSTER_MAP_ENTRIES_PER_SECTOR].flags += {.Allocated}
	if werr := fs.sector_write(&vol, sec, buf[:]); werr != .None {
		testing.expect_value(t, werr, fs.FS_Error.None)
		return
	}

	r := fs.check_image(&vol)
	defer fs.check_report_destroy(&r)
	testing.expect(t, check_has_code(&r, "FlagCombo"), "flag combo flagged")
	testing.expect_value(t, r.errors, 1)
}

// test_check_journal_bounds — a journal region outside the image is corrupt.
@(test)
test_check_journal_bounds :: proc(t: ^testing.T) {
	vol, ok := check_open_scratch(t)
	if !ok { return }
	defer { close_test_volume(&vol); os.remove(JTXN_SCRATCH) }

	fs.journal_set_region_size(&vol.master, u64(1) << 62)
	testing.expect_value(t, fs.write_master_record(&vol), fs.FS_Error.None)

	r := fs.check_image(&vol)
	defer fs.check_report_destroy(&r)
	testing.expect(t, check_has_code(&r, "JournalBounds"), "journal bounds flagged")
	testing.expect_value(t, r.errors, 1)
}
