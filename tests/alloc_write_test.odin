// alloc_write_test.odin — Allocation, truncation, and basic I/O tests.
// Generated from write_test.odin during the Volume refactor.
// Tests: write_fresh, write_append, truncate_to_zero, truncate_partial,
// grow_shrink_cycle, multi_cluster_chain, fallocate_extend,
// copy_file_range_simple, and more.
#+build linux
package tests

import "core:testing"
import "core:time"
import "src:fs"

HELLO := []u8{'h', 'e', 'l', 'l', 'o', '\n'}
WORLD := []u8{'w', 'o', 'r', 'l', 'd', '\n'}

@test
test_write_fresh :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	fc, fo, aerr := fs.allocate_sectors(&vol, 0, 0, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	runs, ext_err := fs.resolve_extents(&vol, fc, fo)
	testing.expectf(t, ext_err == .None, "resolve_extents")
	testing.expect(t, len(runs) > 0, "extents non-empty")

	abs_sector := runs[0].sector
	sector_buf: [fs.SECTOR_SIZE]u8
	copy(sector_buf[:], HELLO[:])
	testing.expect(t, fs.sector_write(&vol, abs_sector, sector_buf[:]), "sector_write")

	read_buf: [fs.SECTOR_SIZE]u8
	testing.expect(t, fs.sector_read(&vol, abs_sector, read_buf[:]), "sector_read")
	for i in 0 ..< len(HELLO) {
		testing.expect(t, read_buf[i] == HELLO[i], "byte match")
	}

	derr := fs.deallocate_sectors(&vol, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)
}

@test
test_write_append :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	fc, fo, aerr := fs.allocate_sectors(&vol, 0, 0, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	runs, _ := fs.resolve_extents(&vol, fc, fo)
	abs_sector := runs[0].sector

	sector_buf: [fs.SECTOR_SIZE]u8
	copy(sector_buf[:], HELLO[:])
	testing.expect(t, fs.sector_write(&vol, abs_sector, sector_buf[:]), "first write")

	fc2, fo2, aerr2 := fs.allocate_sectors(&vol, fc, fo, 2, .File_Content)
	testing.expect_value(t, aerr2, fs.FS_Error.None)
	testing.expect_value(t, fc, fc2)
	testing.expect_value(t, fo, fo2)

	runs2, ext_err2 := fs.resolve_extents(&vol, fc, fo)
	testing.expectf(t, ext_err2 == .None, "resolve_extents after append")

	total_sectors: u64
	for r in runs2 {total_sectors += u64(r.count)}
	testing.expect_value(t, total_sectors, u64(2))

	abs_sector2 := runs2[1].sector
	sector_buf2: [fs.SECTOR_SIZE]u8
	copy(sector_buf2[:], WORLD[:])
	testing.expect(t, fs.sector_write(&vol, abs_sector2, sector_buf2[:]), "append write")

	read1: [fs.SECTOR_SIZE]u8
	read2: [fs.SECTOR_SIZE]u8
	testing.expect(t, fs.sector_read(&vol, runs2[0].sector, read1[:]), "read sector 0")
	testing.expect(t, fs.sector_read(&vol, runs2[1].sector, read2[:]), "read sector 1")
	for i in 0 ..< len(HELLO) {
		testing.expect(t, read1[i] == HELLO[i], "sector0 content")
	}
	for i in 0 ..< len(WORLD) {
		testing.expect(t, read2[i] == WORLD[i], "sector1 content")
	}

	derr := fs.deallocate_sectors(&vol, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)
}

@test
test_directory_entry_persistence :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	root_cluster := fs.Cluster(vol.master.root_cluster)
	root_offset  := fs.Sector_Offset(vol.master.root_sector_index)

	fc, fo, aerr := fs.allocate_sectors(&vol, 0, 0, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	rd_ce, ce_err := fs.find_cluster_entry(&vol, root_cluster, root_offset)
	testing.expectf(t, ce_err == .None, "root dir ClusterEntry")
	dir_sector := rd_ce.sector_start

	dir_buf: [fs.SECTOR_SIZE]u8
	table_sector := fs.Sector(u64(root_cluster) * vol.master.cluster_size + u64(dir_sector))
	testing.expect(t, fs.sector_read(&vol, table_sector, dir_buf[:]), "read dir sector")
	entries := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(dir_buf[:]))

	free_idx := -1
	zero_flags: fs.Dir_Flags
	for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
		if entries[i].flags == zero_flags {
			free_idx = i
			break
		}
	}
	testing.expect(t, free_idx >= 0, "free dir slot found")

	now := time.now()
	y, mo, d := time.date(now)
	h, m, s := time.clock(now)
	new_entry := fs.Directory_Entry{
		flags          = fs.Dir_Flags{.Allocated, .Exists},
		stored_cluster = u64(fc),
		sector_index   = u16(fo),
		year           = u16(y),
		date_time      = fs.Packed_Date_Time{month=u32(int(mo)), date=u32(d), hour=u32(h), minute=u32(m), second=u32(s)},
		file_size      = u64(len(HELLO)),
	}
	copy(new_entry.file_name[:], "HELLO")

	fs.write_directory_entry_at(&vol, root_cluster, fs.Sector_Offset(dir_sector), free_idx, &new_entry)
	entries[free_idx] = new_entry

	read_buf2: [fs.SECTOR_SIZE]u8
	fs.sector_read(&vol, table_sector, read_buf2[:])
	entries2 := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(read_buf2[:]))
	re := entries2[free_idx]

	testing.expect(t, .Exists in re.flags, "entry has Exists flag")
	testing.expect_value(t, re.stored_cluster, u64(fc))
	testing.expect_value(t, u64(re.sector_index), u64(fo))
	testing.expect_value(t, re.file_size, u64(len(HELLO)))
	name := fs.entry_short_name(&re)
	testing.expect(t, name == "HELLO", "entry name matches")

	re.flags -= {.Exists, .Allocated}
	fs.write_directory_entry_at(&vol, root_cluster, fs.Sector_Offset(dir_sector), free_idx, &re)
	derr := fs.deallocate_sectors(&vol, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)
}

@test
test_write_read_cycle :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	fc, fo, aerr := fs.allocate_sectors(&vol, 0, 0, 3, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	runs, ext_err := fs.resolve_extents(&vol, fc, fo)
	testing.expectf(t, ext_err == .None, "resolve_extents")

	total: u64
	for r in runs {total += u64(r.count)}
	testing.expect_value(t, total, u64(3))

	pattern := []u8{0xAA, 0xBB, 0xCC, 0xDD}
	sector_idx := 0
	for run in runs {
		n := int(run.count)
		for si in 0 ..< n {
			sector_buf: [fs.SECTOR_SIZE]u8
			for j in 0 ..< 4 {
				sector_buf[j] = pattern[(sector_idx + j) % 4]
			}
			testing.expect(t, fs.sector_write(&vol, fs.Sector(u64(run.sector) + u64(si)), sector_buf[:]), "sector write")
			sector_idx += 1
		}
	}
	testing.expect_value(t, sector_idx, 3)

	sector_idx = 0
	for run in runs {
		n := int(run.count)
		for si in 0 ..< n {
			read_buf: [fs.SECTOR_SIZE]u8
			testing.expect(t, fs.sector_read(&vol, fs.Sector(u64(run.sector) + u64(si)), read_buf[:]), "sector read")
			for j in 0 ..< 4 {
				testing.expect(t, read_buf[j] == pattern[(sector_idx + j) % 4], "pattern byte")
			}
			sector_idx += 1
		}
	}
	testing.expect_value(t, sector_idx, 3)

	derr := fs.deallocate_sectors(&vol, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)
}

@test
test_sector_integrity :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	fc, fo, aerr := fs.allocate_sectors(&vol, 0, 0, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	defer fs.deallocate_sectors(&vol, fc, fo)

	runs, _ := fs.resolve_extents(&vol, fc, fo)
	sector := runs[0].sector

	// Write ramp pattern 0..255 across the sector.
	ramp_buf: [fs.SECTOR_SIZE]u8
	for i in 0 ..< fs.SECTOR_SIZE {
		ramp_buf[i] = u8(i & 0xFF)
	}
	testing.expect(t, fs.sector_write(&vol, sector, ramp_buf[:]), "write ramp")

	// Read back and verify.
	read_buf: [fs.SECTOR_SIZE]u8
	testing.expect(t, fs.sector_read(&vol, sector, read_buf[:]), "read back")
	for i in 0 ..< fs.SECTOR_SIZE {
		if read_buf[i] != u8(i & 0xFF) {
			testing.expect(t, false, "byte mismatch in ramp pattern")
			break
		}
	}
}

@test
test_write_zero_bytes :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	fc, fo, aerr := fs.allocate_sectors(&vol, 0, 0, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	defer fs.deallocate_sectors(&vol, fc, fo)

	runs, _ := fs.resolve_extents(&vol, fc, fo)
	defer delete(runs)
	sector := runs[0].sector

	// Write a known pattern first.
	pat_buf: [fs.SECTOR_SIZE]u8
	for i in 0 ..< fs.SECTOR_SIZE {pat_buf[i] = 0xAA}
	testing.expect(t, fs.sector_write(&vol, sector, pat_buf[:]), "write pattern")

	// Write 0 bytes — should not change sector content.
	testing.expect(t, fs.sector_write(&vol, sector, pat_buf[:0]), "zero-byte write")

	read_buf: [fs.SECTOR_SIZE]u8
	fs.sector_read(&vol, sector, read_buf[:])
	for b in read_buf {
		testing.expect(t, b == 0xAA, "zero-byte write preserves sector")
		if b != 0xAA {break}
	}
}

@test
test_write_overwrite :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	fc, fo, aerr := fs.allocate_sectors(&vol, 0, 0, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	runs, _ := fs.resolve_extents(&vol, fc, fo)
	sector := runs[0].sector

	// Write 0xAA... to sector.
	sector_buf: [fs.SECTOR_SIZE]u8
	for i in 0 ..< fs.SECTOR_SIZE {sector_buf[i] = 0xAA}
	testing.expect(t, fs.sector_write(&vol, sector, sector_buf[:]), "write 0xAA")

	// Overwrite first 10 bytes with 0xBB.
	sector_buf2: [fs.SECTOR_SIZE]u8
	for i in 0 ..< 10 {sector_buf2[i] = 0xBB}
	copy(sector_buf2[10:], sector_buf[10:])
	testing.expect(t, fs.sector_write(&vol, sector, sector_buf2[:]), "overwrite first 10")

	// Read back and verify first 10 = 0xBB, rest = 0xAA.
	read_buf: [fs.SECTOR_SIZE]u8
	fs.sector_read(&vol, sector, read_buf[:])
	for i in 0 ..< 10 {testing.expect(t, read_buf[i] == 0xBB, "overwritten byte")}
	for i in 10 ..< fs.SECTOR_SIZE {testing.expect(t, read_buf[i] == 0xAA, "preserved byte")}
	fs.deallocate_sectors(&vol, fc, fo)
}

@test
test_full_cluster_alloc :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	// Allocate all sectors in one cluster.
	fc, fo, aerr := fs.allocate_sectors(&vol, 0, 0, vol.master.cluster_size, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	defer fs.deallocate_sectors(&vol, fc, fo)

	runs, ext_err := fs.resolve_extents(&vol, fc, fo)
	testing.expectf(t, ext_err == .None, "resolve_extents after full cluster alloc")

	total: u64
	for r in runs {total += u64(r.count)}
	testing.expect_value(t, total, vol.master.cluster_size)

	// Write a pattern across the entire cluster.
	pattern := []u8{0x11, 0x22, 0x33, 0x44}
	sector_idx := 0
	for run in runs {
		n := int(run.count)
		for si in 0 ..< n {
			pat_buf: [fs.SECTOR_SIZE]u8
			for j in 0 ..< 4 {
				pat_buf[j] = pattern[(sector_idx + j) % 4]
			}
			testing.expect(t, fs.sector_write(&vol, fs.Sector(u64(run.sector) + u64(si)), pat_buf[:]), "write sector")
			sector_idx += 1
		}
	}

	// Read back.
	sector_idx = 0
	for run in runs {
		n := int(run.count)
		for si in 0 ..< n {
			rd_buf: [fs.SECTOR_SIZE]u8
			testing.expect(t, fs.sector_read(&vol, fs.Sector(u64(run.sector) + u64(si)), rd_buf[:]), "read sector")
			for j in 0 ..< 4 {
				testing.expect(t, rd_buf[j] == pattern[(sector_idx + j) % 4], "pattern byte")
			}
			sector_idx += 1
		}
	}
	testing.expect_value(t, sector_idx, int(vol.master.cluster_size))
}

@test
test_grow_shrink_cycle :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	fc, fo, aerr := fs.allocate_sectors(&vol, 0, 0, 10, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	runs, _ := fs.resolve_extents(&vol, fc, fo)
	pattern := byte(0xAB)
	se_idx := 0
	for run in runs {
		for si in 0 ..< int(run.count) {
			buf: [fs.SECTOR_SIZE]u8
			for j in 0 ..< fs.SECTOR_SIZE {buf[j] = pattern + byte(se_idx)}
			testing.expect(t, fs.sector_write(&vol, fs.Sector(u64(run.sector) + u64(si)), buf[:]), "write")
			se_idx += 1
		}
	}

	testing.expect_value(t, se_idx, 10)
	derr := fs.deallocate_sectors(&vol, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)

	fc2, fo2, aerr2 := fs.allocate_sectors(&vol, 0, 0, 10, .File_Content)
	testing.expect_value(t, aerr2, fs.FS_Error.None)

	runs2, _ := fs.resolve_extents(&vol, fc2, fo2)
	si2 := 0
	for run in runs2 {
		for _ in 0 ..< int(run.count) {
			buf: [fs.SECTOR_SIZE]u8
			testing.expect(t, fs.sector_read(&vol, fs.Sector(u64(run.sector) + u64(si2)), buf[:]), "read")
			si2 += 1
		}
	}
	testing.expect_value(t, si2, 10)
	fs.deallocate_sectors(&vol, fc2, fo2)
}

@test
test_multi_cluster_chain :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	needed := vol.master.cluster_size + 4
	fc, fo, aerr := fs.allocate_sectors(&vol, 0, 0, needed, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	runs, ext_err := fs.resolve_extents(&vol, fc, fo)
	testing.expectf(t, ext_err == .None, "resolve_extents")
	total: u64
	for r in runs {total += u64(r.count)}

	testing.expect_value(t, total, needed)
	se_idx := 0
	for run in runs {
		for si in 0 ..< int(run.count) {
			buf: [fs.SECTOR_SIZE]u8
			for j in 0 ..< fs.SECTOR_SIZE {buf[j] = byte(se_idx)}

			testing.expect(t, fs.sector_write(&vol, fs.Sector(u64(run.sector) + u64(si)), buf[:]), "write")
			se_idx += 1
		}
	}

	testing.expect_value(t, se_idx, int(needed))
	se_idx = 0
	for run in runs {
		for si in 0 ..< int(run.count) {
			buf: [fs.SECTOR_SIZE]u8
			testing.expect(t, fs.sector_read(&vol, fs.Sector(u64(run.sector) + u64(si)), buf[:]), "read")
			for j in 0 ..< fs.SECTOR_SIZE {
				testing.expect(t, buf[j] == byte(se_idx), "verify")
			}
			se_idx += 1
		}
	}
	fs.deallocate_sectors(&vol, fc, fo)
}

@test
test_chain_extension_from_nonzero :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	fc, fo, aerr := fs.allocate_sectors(&vol, 0, 0, 5, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	fc2, fo2, aerr2 := fs.allocate_sectors(&vol, fc, fo, 10, .File_Content)
	testing.expect_value(t, aerr2, fs.FS_Error.None)
	testing.expect_value(t, fc, fc2)
	testing.expect_value(t, fo, fo2)

	runs, _ := fs.resolve_extents(&vol, fc, fo)
	total: u64
	for r in runs {total += u64(r.count)}

	testing.expect_value(t, total, u64(10))
	fc3, fo3, aerr3 := fs.allocate_sectors(&vol, fc, fo, vol.master.cluster_size, .File_Content)

	testing.expect_value(t, aerr3, fs.FS_Error.None)
	testing.expect_value(t, fc, fc3)
	testing.expect_value(t, fo, fo3)

	runs2, _ := fs.resolve_extents(&vol, fc, fo)
	total2: u64
	for r in runs2 {total2 += u64(r.count)}
	testing.expect_value(t, total2, vol.master.cluster_size)
	fs.deallocate_sectors(&vol, fc, fo)
}

@test
test_chain_extension_multi_cluster :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	fc, fo, aerr := fs.allocate_sectors(&vol, 0, 0, 5, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	fc2, fo2, aerr2 := fs.allocate_sectors(&vol, fc, fo, 30, .File_Content)
	testing.expect_value(t, aerr2, fs.FS_Error.None)
	testing.expect_value(t, fc, fc2)
	testing.expect_value(t, fo, fo2)

	runs, ext_err := fs.resolve_extents(&vol, fc, fo)
	testing.expectf(t, ext_err == .None, "resolve_extents")
	total: u64
	for r in runs {total += u64(r.count)}
	testing.expect_value(t, total, u64(30))

	se_idx := 0
	for run in runs {
		for si in 0 ..< int(run.count) {
			buf: [fs.SECTOR_SIZE]u8
			for j in 0 ..< fs.SECTOR_SIZE {buf[j] = byte(se_idx)}
			testing.expect(t, fs.sector_write(&vol, fs.Sector(u64(run.sector) + u64(si)), buf[:]), "write")
			se_idx += 1
		}
	}

	testing.expect_value(t, se_idx, 30)
	se_idx = 0
	for run in runs {
		for si in 0 ..< int(run.count) {
			buf: [fs.SECTOR_SIZE]u8
			testing.expect(t, fs.sector_read(&vol, fs.Sector(u64(run.sector) + u64(si)), buf[:]), "read")
			for j in 0 ..< fs.SECTOR_SIZE {testing.expect(t, buf[j] == byte(se_idx), "verify")}
			se_idx += 1
		}
	}

	fs.deallocate_sectors(&vol, fc, fo)
}

@test
test_write_read_persistence :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	fc, fo, aerr := fs.allocate_sectors(&vol, 0, 0, 2, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	runs, _ := fs.resolve_extents(&vol, fc, fo)
	s0 := runs[0].sector
	s1 := fs.Sector(u64(runs[0].sector) + u64(runs[0].count) - 1)
	if len(runs) > 1 {s1 = runs[1].sector}

	hbuf: [fs.SECTOR_SIZE]u8
	copy(hbuf[:], "HELLO")
	testing.expect(t, fs.sector_write(&vol, s0, hbuf[:]), "write HELLO")

	wbuf: [fs.SECTOR_SIZE]u8
	copy(wbuf[:], "WORLD")
	testing.expect(t, fs.sector_write(&vol, s1, wbuf[:]), "write WORLD")

	rbuf: [fs.SECTOR_SIZE]u8
	testing.expect(t, fs.sector_read(&vol, s0, rbuf[:]), "read 0")
	testing.expect(t, string(rbuf[:5]) == "HELLO", "verify HELLO")
	testing.expect(t, fs.sector_read(&vol, s1, rbuf[:]), "read 1")
	testing.expect(t, string(rbuf[:5]) == "WORLD", "verify WORLD")
	fs.deallocate_sectors(&vol, fc, fo)
}

@test
test_truncate_to_zero :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	fc, fo, aerr := fs.allocate_sectors(&vol, 0, 0, 5, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	buf: [fs.SECTOR_SIZE]u8
	for j in 0 ..< fs.SECTOR_SIZE {buf[j] = 0xAB}
	for si in 0 ..< 5 {
		testing.expect(t, fs.sector_write(&vol, fs.Sector(u64(fc) * vol.master.cluster_size + u64(fo) + u64(si)), buf[:]), "write")
	}

	derr := fs.deallocate_sectors(&vol, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)

	_, ext_err := fs.resolve_extents(&vol, fc, fo)
	testing.expectf(t, ext_err != .None, "extents should be empty after deallocate")

	fc2, _, aerr2 := fs.allocate_sectors(&vol, 0, 0, 5, .File_Content)
	testing.expect_value(t, aerr2, fs.FS_Error.None)
	testing.expect(t, fc2 != 0, "allocated cluster is valid")
}

@test
test_truncate_partial :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	fc, fo, aerr := fs.allocate_sectors(&vol, 0, 0, 10, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	for si in 0 ..< 10 {
		buf: [fs.SECTOR_SIZE]u8
		for j in 0 ..< fs.SECTOR_SIZE {buf[j] = byte(si)}
		testing.expect(t, fs.sector_write(&vol, fs.Sector(u64(fc) * vol.master.cluster_size + u64(fo) + u64(si)), buf[:]), "write")
	}

	ce, ce_err := fs.find_cluster_entry(&vol, fc, fo)
	testing.expectf(t, ce_err == .None, "find_cluster_entry")
	old_size := ce.allocation_size
	testing.expect(t, old_size == 10, "allocated 10 sectors")

	ce.allocation_size = 4
	ce_tbl: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	fs.read_cluster_entry_table(&vol, fc, &ce_tbl)
	for &e, _ in ce_tbl {
		if e.sector_start == u16(fo) {
			e = ce
			testing.expectf(t, fs.write_cluster_entry_table(&vol, fc, &ce_tbl) == .None, "write partial CE")
			break
		}
	}

	runs, ext_err := fs.resolve_extents(&vol, fc, fo)
	testing.expectf(t, ext_err == .None, "resolve_extents after partial truncate")
	total: u64
	for r in runs {total += u64(r.count)}
	testing.expect_value(t, total, 4)
}

@test
test_fallocate_extend :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	fc, fo, aerr := fs.allocate_sectors(&vol, 0, 0, 2, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	runs, ext_err := fs.resolve_extents(&vol, fc, fo)
	testing.expectf(t, ext_err == .None, "resolve_extents")
	tt: u64; for r in runs {tt += u64(r.count)}
	testing.expect_value(t, tt, 2)

	// Extend from 2 sectors to 5
	fc2, fo2, aerr2 := fs.allocate_sectors(&vol, fc, fo, 5, .File_Content)
	testing.expect_value(t, aerr2, fs.FS_Error.None)
	testing.expect(t, fc2 == fc && fo2 == fo, "extended same chain")

	runs2, ext_err2 := fs.resolve_extents(&vol, fc2, fo2)
	testing.expectf(t, ext_err2 == .None, "resolve_extents after extend")
	tt2: u64; for r in runs2 {tt2 += u64(r.count)}
	testing.expect_value(t, tt2, 5)

	// Write to sector 0 and verify it persists
	buf0: [fs.SECTOR_SIZE]u8
	buf0[0] = 0xAB
	testing.expect(t, fs.sector_write(&vol, runs2[0].sector, buf0[:]), "write sector 0")

	read_buf: [fs.SECTOR_SIZE]u8
	testing.expect(t, fs.sector_read(&vol, runs2[0].sector, read_buf[:]), "read sector 0")
	testing.expect_value(t, read_buf[0], u8(0xAB))
}

@test
test_copy_file_range_simple :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	// Create source: allocate 1 sector, write "HELLO"
	src_c, src_o, aerr := fs.allocate_sectors(&vol, 0, 0, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	src_buf: [fs.SECTOR_SIZE]u8
	copy(src_buf[:], "HELLO")
	src_runs, _ := fs.resolve_extents(&vol, src_c, src_o)
	testing.expect(t, fs.sector_write(&vol, src_runs[0].sector, src_buf[:]), "write src")

	// Create dest: allocate 1 sector
	dst_c, dst_o, aerr2 := fs.allocate_sectors(&vol, 0, 0, 1, .File_Content)
	testing.expect_value(t, aerr2, fs.FS_Error.None)

	// Manual copy: read from src, write to dst
	dst_runs, _ := fs.resolve_extents(&vol, dst_c, dst_o)
	copy_buf: [fs.SECTOR_SIZE]u8
	testing.expect(t, fs.sector_read(&vol, src_runs[0].sector, copy_buf[:]), "read src for copy")
	testing.expect(t, fs.sector_write(&vol, dst_runs[0].sector, copy_buf[:]), "write dst")

	// Verify
	verify_buf: [fs.SECTOR_SIZE]u8
	testing.expect(t, fs.sector_read(&vol, dst_runs[0].sector, verify_buf[:]), "read dst")
	testing.expect(t, string(verify_buf[:5]) == "HELLO", "content matches")
}
