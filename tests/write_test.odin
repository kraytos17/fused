// write_test.odin — Non-FUSE integration tests for the write path.
//
// Tests the complete write path (allocate → write → read → verify)
// without requiring a FUSE mount.  Uses shared open_test_image.
#+build linux
package tests

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import "src:fs"

HELLO := []u8{'h', 'e', 'l', 'l', 'o', '\n'}
WORLD := []u8{'w', 'o', 'r', 'l', 'd', '\n'}

@test
test_write_fresh :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	fc, fo, aerr := fs.allocate_sectors(&master, fd, 0, 0, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	runs, runs_ok := fs.resolve_extents(fd, &master, fc, fo)
	testing.expect(t, runs_ok, "resolve_extents")
	testing.expect(t, len(runs) > 0, "extents non-empty")

	abs_sector := runs[0].sector
	sector_buf: [fs.SECTOR_SIZE]u8
	copy(sector_buf[:], HELLO[:])
	testing.expect(t, fs.sector_write(fd, abs_sector, sector_buf[:]), "sector_write")

	read_buf: [fs.SECTOR_SIZE]u8
	testing.expect(t, fs.sector_read(fd, abs_sector, read_buf[:]), "sector_read")
	for i in 0 ..< len(HELLO) {
		testing.expect(t, read_buf[i] == HELLO[i], "byte match")
	}

	derr := fs.deallocate_sectors(&master, fd, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)
}

@test
test_write_append :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	fc, fo, aerr := fs.allocate_sectors(&master, fd, 0, 0, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	runs, _ := fs.resolve_extents(fd, &master, fc, fo)
	abs_sector := runs[0].sector

	sector_buf: [fs.SECTOR_SIZE]u8
	copy(sector_buf[:], HELLO[:])
	testing.expect(t, fs.sector_write(fd, abs_sector, sector_buf[:]), "first write")

	fc2, fo2, aerr2 := fs.allocate_sectors(&master, fd, fc, fo, 2, .File_Content)
	testing.expect_value(t, aerr2, fs.FS_Error.None)
	testing.expect_value(t, fc, fc2)
	testing.expect_value(t, fo, fo2)

	runs2, runs_ok2 := fs.resolve_extents(fd, &master, fc, fo)
	testing.expect(t, runs_ok2, "resolve_extents after append")

	total_sectors: u64
	for r in runs2 {total_sectors += u64(r.count)}
	testing.expect_value(t, total_sectors, u64(2))

	abs_sector2 := runs2[1].sector
	sector_buf2: [fs.SECTOR_SIZE]u8
	copy(sector_buf2[:], WORLD[:])
	testing.expect(t, fs.sector_write(fd, abs_sector2, sector_buf2[:]), "append write")

	read1: [fs.SECTOR_SIZE]u8
	read2: [fs.SECTOR_SIZE]u8
	testing.expect(t, fs.sector_read(fd, runs2[0].sector, read1[:]), "read sector 0")
	testing.expect(t, fs.sector_read(fd, runs2[1].sector, read2[:]), "read sector 1")
	for i in 0 ..< len(HELLO) {
		testing.expect(t, read1[i] == HELLO[i], "sector0 content")
	}
	for i in 0 ..< len(WORLD) {
		testing.expect(t, read2[i] == WORLD[i], "sector1 content")
	}

	derr := fs.deallocate_sectors(&master, fd, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)
}

@test
test_directory_entry_persistence :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	root_cluster := fs.Cluster(master.root_cluster)
	root_offset  := fs.Sector_Offset(master.root_sector_index)

	fc, fo, aerr := fs.allocate_sectors(&master, fd, 0, 0, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	rd_ce, ok_ce := fs.find_cluster_entry(fd, &master, root_cluster, root_offset)
	testing.expect(t, ok_ce, "root dir ClusterEntry")
	dir_sector := rd_ce.sector_start

	dir_buf: [fs.SECTOR_SIZE]u8
	table_sector := fs.Sector(u64(root_cluster) * master.cluster_size + u64(dir_sector))
	testing.expect(t, fs.sector_read(fd, table_sector, dir_buf[:]), "read dir sector")
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

	fs.write_directory_entry_at(fd, &master, root_cluster, fs.Sector_Offset(dir_sector), free_idx, &new_entry)
	entries[free_idx] = new_entry

	read_buf2: [fs.SECTOR_SIZE]u8
	fs.sector_read(fd, table_sector, read_buf2[:])
	entries2 := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(read_buf2[:]))
	re := entries2[free_idx]

	testing.expect(t, .Exists in re.flags, "entry has Exists flag")
	testing.expect_value(t, re.stored_cluster, u64(fc))
	testing.expect_value(t, u64(re.sector_index), u64(fo))
	testing.expect_value(t, re.file_size, u64(len(HELLO)))
	name := fs.entry_short_name(&re)
	testing.expect(t, name == "HELLO", "entry name matches")

	re.flags -= {.Exists, .Allocated}
	fs.write_directory_entry_at(fd, &master, root_cluster, fs.Sector_Offset(dir_sector), free_idx, &re)
	derr := fs.deallocate_sectors(&master, fd, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)
}

@test
test_write_read_cycle :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	fc, fo, aerr := fs.allocate_sectors(&master, fd, 0, 0, 3, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	runs, runs_ok := fs.resolve_extents(fd, &master, fc, fo)
	testing.expect(t, runs_ok, "resolve_extents")

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
			testing.expect(t, fs.sector_write(fd, fs.Sector(u64(run.sector) + u64(si)), sector_buf[:]), "sector write")
			sector_idx += 1
		}
	}
	testing.expect_value(t, sector_idx, 3)

	sector_idx = 0
	for run in runs {
		n := int(run.count)
		for si in 0 ..< n {
			read_buf: [fs.SECTOR_SIZE]u8
			testing.expect(t, fs.sector_read(fd, fs.Sector(u64(run.sector) + u64(si)), read_buf[:]), "sector read")
			for j in 0 ..< 4 {
				testing.expect(t, read_buf[j] == pattern[(sector_idx + j) % 4], "pattern byte")
			}
			sector_idx += 1
		}
	}
	testing.expect_value(t, sector_idx, 3)

	derr := fs.deallocate_sectors(&master, fd, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)
}

@test
test_sector_integrity :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	fc, fo, aerr := fs.allocate_sectors(&master, fd, 0, 0, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	defer fs.deallocate_sectors(&master, fd, fc, fo)

	runs, _ := fs.resolve_extents(fd, &master, fc, fo)
	sector := runs[0].sector

	// Write ramp pattern 0..255 across the sector.
	ramp_buf: [fs.SECTOR_SIZE]u8
	for i in 0 ..< fs.SECTOR_SIZE {
		ramp_buf[i] = u8(i & 0xFF)
	}
	testing.expect(t, fs.sector_write(fd, sector, ramp_buf[:]), "write ramp")

	// Read back and verify.
	read_buf: [fs.SECTOR_SIZE]u8
	testing.expect(t, fs.sector_read(fd, sector, read_buf[:]), "read back")
	for i in 0 ..< fs.SECTOR_SIZE {
		if read_buf[i] != u8(i & 0xFF) {
			testing.expect(t, false, "byte mismatch in ramp pattern")
			break
		}
	}
}

@test
test_write_zero_bytes :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	fc, fo, aerr := fs.allocate_sectors(&master, fd, 0, 0, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	defer fs.deallocate_sectors(&master, fd, fc, fo)

	runs, _ := fs.resolve_extents(fd, &master, fc, fo)
	sector := runs[0].sector

	// Write a known pattern first.
	pat_buf: [fs.SECTOR_SIZE]u8
	for i in 0 ..< fs.SECTOR_SIZE {pat_buf[i] = 0xAA}
	testing.expect(t, fs.sector_write(fd, sector, pat_buf[:]), "write pattern")

	// Write 0 bytes — should not change sector content.
	testing.expect(t, fs.sector_write(fd, sector, pat_buf[:0]), "zero-byte write")

	read_buf: [fs.SECTOR_SIZE]u8
	fs.sector_read(fd, sector, read_buf[:])
	for b in read_buf {
		testing.expect(t, b == 0xAA, "zero-byte write preserves sector")
		if b != 0xAA {break}
	}
}

@test
test_write_overwrite :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	fc, fo, aerr := fs.allocate_sectors(&master, fd, 0, 0, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	runs, _ := fs.resolve_extents(fd, &master, fc, fo)
	sector := runs[0].sector

	// Write 0xAA... to sector.
	sector_buf: [fs.SECTOR_SIZE]u8
	for i in 0 ..< fs.SECTOR_SIZE {sector_buf[i] = 0xAA}
	testing.expect(t, fs.sector_write(fd, sector, sector_buf[:]), "write 0xAA")

	// Overwrite first 10 bytes with 0xBB.
	sector_buf2: [fs.SECTOR_SIZE]u8
	for i in 0 ..< 10 {sector_buf2[i] = 0xBB}
	copy(sector_buf2[10:], sector_buf[10:])
	testing.expect(t, fs.sector_write(fd, sector, sector_buf2[:]), "overwrite first 10")

	// Read back and verify first 10 = 0xBB, rest = 0xAA.
	read_buf: [fs.SECTOR_SIZE]u8
	fs.sector_read(fd, sector, read_buf[:])
	for i in 0 ..< 10 {testing.expect(t, read_buf[i] == 0xBB, "overwritten byte")}
	for i in 10 ..< fs.SECTOR_SIZE {testing.expect(t, read_buf[i] == 0xAA, "preserved byte")}
	fs.deallocate_sectors(&master, fd, fc, fo)
}

@test
test_full_cluster_alloc :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	// Allocate all sectors in one cluster.
	fc, fo, aerr := fs.allocate_sectors(&master, fd, 0, 0, master.cluster_size, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	defer fs.deallocate_sectors(&master, fd, fc, fo)

	runs, runs_ok := fs.resolve_extents(fd, &master, fc, fo)
	testing.expect(t, runs_ok, "resolve_extents after full cluster alloc")

	total: u64
	for r in runs {total += u64(r.count)}
	testing.expect_value(t, total, master.cluster_size)

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
			testing.expect(t, fs.sector_write(fd, fs.Sector(u64(run.sector) + u64(si)), pat_buf[:]), "write sector")
			sector_idx += 1
		}
	}

	// Read back.
	sector_idx = 0
	for run in runs {
		n := int(run.count)
		for si in 0 ..< n {
			rd_buf: [fs.SECTOR_SIZE]u8
			testing.expect(t, fs.sector_read(fd, fs.Sector(u64(run.sector) + u64(si)), rd_buf[:]), "read sector")
			for j in 0 ..< 4 {
				testing.expect(t, rd_buf[j] == pattern[(sector_idx + j) % 4], "pattern byte")
			}
			sector_idx += 1
		}
	}
	testing.expect_value(t, sector_idx, int(master.cluster_size))
}

@test
test_directory_growth :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	root_cluster := fs.Cluster(master.root_cluster)
	root_offset  := fs.Sector_Offset(master.root_sector_index)

	// Write 11 entries to the root directory.  The first sector holds 10,
	// so the 11th requires the directory chain to extend.
	rd_ce, ok_ce := fs.find_cluster_entry(fd, &master, root_cluster, root_offset)
	testing.expect(t, ok_ce, "root dir ClusterEntry")

	now := time.now()
	y, mo, d := time.date(now)
	h, m, s := time.clock(now)
	for i := 0; i < 11; i += 1 {
		ne := fs.Directory_Entry{
			flags = fs.Dir_Flags{.Allocated, .Exists},
			year  = u16(y),
			date_time = fs.Packed_Date_Time{month=u32(int(mo)), date=u32(d), hour=u32(h), minute=u32(m), second=u32(s)},
			file_size = 1,
		}

		name := fmt.tprintf("f%d", i)
		copy(ne.file_name[:], name)

		// Find free slot — scan the directory chain
		dir_runs, dr_ok := fs.resolve_extents(fd, &master, root_cluster, root_offset)
		testing.expect(t, dr_ok, "resolve_extents")

		dsec: fs.Sector_Offset
		didx := -1
		scan_buf: [fs.SECTOR_SIZE]u8
	run_loop:
		for run in dir_runs {
			n := int(run.count)
			for si in 0 ..< n {
				sec := fs.Sector(u64(run.sector) + u64(si))
				if !fs.sector_read(fd, sec, scan_buf[:]) {break}

				raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(scan_buf[:]))
				for j in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
					if .Exists in raw[j].flags {
						if fs.entry_short_name(&raw[j]) == name {
							break run_loop
						}
					} else if didx < 0 {
						zero_flags: fs.Dir_Flags
						if raw[j].flags == zero_flags {
							dsec = fs.Sector_Offset(u64(sec) - u64(root_cluster) * master.cluster_size)
							didx = j
						}
					}
				}
				if didx >= 0 {break run_loop}
			}
		}
		if didx < 0 {
			existing_runs, _ := fs.resolve_extents(fd, &master, root_cluster, root_offset)
			existing_total: u64
			for r in existing_runs {existing_total += u64(r.count)}

			_, _, ext_err := fs.allocate_sectors(&master, fd, root_cluster, root_offset, existing_total + 1, .Directory)
			testing.expect_value(t, ext_err, fs.FS_Error.None)
			dir_runs, dr_ok = fs.resolve_extents(fd, &master, root_cluster, root_offset)

			testing.expect(t, dr_ok, "resolve_extents after extension")
			last_run := dir_runs[len(dir_runs)-1]
			last_sec := fs.Sector(u64(last_run.sector) + u64(last_run.count) - 1)
			if !fs.sector_read(fd, last_sec, scan_buf[:]) {break}

			raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(scan_buf[:]))
			for j in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
				zero_flags: fs.Dir_Flags
				if raw[j].flags == zero_flags {
					dsec = fs.Sector_Offset(u64(last_sec) - u64(root_cluster) * master.cluster_size)
					didx = j
					break
				}
			}
		}
		if didx < 0 {testing.fail(t); return}
		fs.write_directory_entry_at(fd, &master, root_cluster, dsec, didx, &ne)
	}

	dirs, dirs_ok := fs.read_directory_entries(fd, &master, root_cluster, fs.Sector_Offset(rd_ce.sector_start))
	testing.expect(t, dirs_ok, "read_directory_entries")

	found := 0
	for &d in dirs {
		name := fs.entry_short_name(&d)
		if len(name) > 0 && name[0] == 'f' {
			found += 1
		}
	}

	dir_runs2, dr2_ok := fs.resolve_extents(fd, &master, root_cluster, root_offset)
	testing.expect(t, dr2_ok, "resolve_extents after growth")
	total_entries := 0
	sector_buf2: [fs.SECTOR_SIZE]u8
	for run in dir_runs2 {
		n := int(run.count)
		for si in 0 ..< n {
			fs.sector_read(fd, fs.Sector(u64(run.sector) + u64(si)), sector_buf2[:])
			raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(sector_buf2[:]))
			for j in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
				if .Exists in raw[j].flags {
					total_entries += 1
				}
			}
		}
	}

	testing.expect(t, total_entries >= 10, "directory grew beyond one sector")
	for run in dir_runs2 {
		n := int(run.count)
		for si in 0 ..< n {
			sec := fs.Sector(u64(run.sector) + u64(si))
			fs.sector_read(fd, sec, sector_buf2[:])
			raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(sector_buf2[:]))
			for j in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
				if .Exists in raw[j].flags {
					name := fs.entry_short_name(&raw[j])
					if len(name) > 0 && name[0] == 'f' {
						dsec := fs.Sector_Offset(u64(sec) - u64(root_cluster) * master.cluster_size)
						raw[j].flags -= {.Exists, .Allocated}
						fs.write_directory_entry_at(fd, &master, root_cluster, dsec, j, &raw[j])
					}
				}
			}
		}
	}
}

@test
test_entry_timestamp :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	dir_cluster, dir_offset, derr := fs.allocate_sectors(&master, fd, 0, 0, 1, .Directory)
	testing.expect_value(t, derr, fs.FS_Error.None)
	defer fs.deallocate_sectors(&master, fd, dir_cluster, dir_offset)

	dir_runs, _ := fs.resolve_extents(fd, &master, dir_cluster, dir_offset)
	zero_sector: [fs.SECTOR_SIZE]u8
	fs.sector_write(fd, dir_runs[0].sector, zero_sector[:])

	ce, ce_ok := fs.find_cluster_entry(fd, &master, dir_cluster, dir_offset)
	testing.expect(t, ce_ok, "ClusterEntry")

	dir_sector := ce.sector_start
	dir_buf: [fs.SECTOR_SIZE]u8
	table_sector := fs.Sector(u64(dir_cluster) * master.cluster_size + u64(dir_sector))
	fs.sector_read(fd, table_sector, dir_buf[:])
	entries := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(dir_buf[:]))

	free_idx := -1
	zero_flags: fs.Dir_Flags
	for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
		if entries[i].flags == zero_flags {
			free_idx = i
			break
		}
	}

	testing.expect(t, free_idx >= 0, "free dir slot")
	test_entry := fs.Directory_Entry{
		flags          = fs.Dir_Flags{.Allocated, .Exists},
		year           = 2025,
		date_time      = fs.Packed_Date_Time{month=6, date=15, hour=10, minute=30, second=45},
	}

	copy(test_entry.file_name[:], "TEST")
	fs.write_directory_entry_at(fd, &master, dir_cluster, fs.Sector_Offset(dir_sector), free_idx, &test_entry)

	fs.sector_read(fd, table_sector, dir_buf[:])
	re := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(dir_buf[:]))[free_idx]

	testing.expect_value(t, re.year, u16(2025))
	testing.expect_value(t, re.date_time.month, u32(6))
	testing.expect_value(t, re.date_time.date, u32(15))
	testing.expect_value(t, re.date_time.hour, u32(10))
	testing.expect_value(t, re.date_time.minute, u32(30))
	testing.expect_value(t, re.date_time.second, u32(45))
	name := fs.entry_short_name(&re)
	testing.expect(t, name == "TEST", "timestamp entry name")

	re.flags -= {.Exists, .Allocated}
	fs.write_directory_entry_at(fd, &master, dir_cluster, fs.Sector_Offset(dir_sector), free_idx, &re)
}

@test
test_grow_shrink_cycle :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	fc, fo, aerr := fs.allocate_sectors(&master, fd, 0, 0, 10, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	runs, _ := fs.resolve_extents(fd, &master, fc, fo)
	pattern := byte(0xAB)
	si := 0
	for run in runs {
		for _ in 0 ..< int(run.count) {
			buf: [fs.SECTOR_SIZE]u8
			for j in 0 ..< fs.SECTOR_SIZE {buf[j] = pattern + byte(si)}

			testing.expect(t, fs.sector_write(fd, fs.Sector(u64(run.sector) + u64(si)), buf[:]), "write")
			si += 1
		}
	}

	testing.expect_value(t, si, 10)
	derr := fs.deallocate_sectors(&master, fd, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)

	fc2, fo2, aerr2 := fs.allocate_sectors(&master, fd, 0, 0, 10, .File_Content)
	testing.expect_value(t, aerr2, fs.FS_Error.None)

	runs2, _ := fs.resolve_extents(fd, &master, fc2, fo2)
	si2 := 0
	for run in runs2 {
		for _ in 0 ..< int(run.count) {
			buf: [fs.SECTOR_SIZE]u8
			testing.expect(t, fs.sector_read(fd, fs.Sector(u64(run.sector) + u64(si2)), buf[:]), "read")
			si2 += 1
		}
	}
	testing.expect_value(t, si2, 10)
	fs.deallocate_sectors(&master, fd, fc2, fo2)
}

@test
test_multi_cluster_chain :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	needed := master.cluster_size + 4
	fc, fo, aerr := fs.allocate_sectors(&master, fd, 0, 0, needed, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	runs, runs_ok := fs.resolve_extents(fd, &master, fc, fo)
	testing.expect(t, runs_ok, "resolve_extents")
	total: u64
	for r in runs {total += u64(r.count)}

	testing.expect_value(t, total, needed)
	si := 0
	for run in runs {
		for _ in 0 ..< int(run.count) {
			buf: [fs.SECTOR_SIZE]u8
			for j in 0 ..< fs.SECTOR_SIZE {buf[j] = byte(si)}

			testing.expect(t, fs.sector_write(fd, fs.Sector(u64(run.sector) + u64(si)), buf[:]), "write")
			si += 1
		}
	}

	testing.expect_value(t, si, int(needed))
	si = 0
	for run in runs {
		for _ in 0 ..< int(run.count) {
			buf: [fs.SECTOR_SIZE]u8
			testing.expect(t, fs.sector_read(fd, fs.Sector(u64(run.sector) + u64(si)), buf[:]), "read")
			for j in 0 ..< fs.SECTOR_SIZE {
				testing.expect(t, buf[j] == byte(si), "verify")
			}
			si += 1
		}
	}
	fs.deallocate_sectors(&master, fd, fc, fo)
}

@test
test_chain_extension_from_nonzero :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	fc, fo, aerr := fs.allocate_sectors(&master, fd, 0, 0, 5, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	fc2, fo2, aerr2 := fs.allocate_sectors(&master, fd, fc, fo, 10, .File_Content)
	testing.expect_value(t, aerr2, fs.FS_Error.None)
	testing.expect_value(t, fc, fc2)
	testing.expect_value(t, fo, fo2)

	runs, _ := fs.resolve_extents(fd, &master, fc, fo)
	total: u64
	for r in runs {total += u64(r.count)}

	testing.expect_value(t, total, u64(10))
	fc3, fo3, aerr3 := fs.allocate_sectors(&master, fd, fc, fo, master.cluster_size, .File_Content)

	testing.expect_value(t, aerr3, fs.FS_Error.None)
	testing.expect_value(t, fc, fc3)
	testing.expect_value(t, fo, fo3)

	runs2, _ := fs.resolve_extents(fd, &master, fc, fo)
	total2: u64
	for r in runs2 {total2 += u64(r.count)}
	testing.expect_value(t, total2, master.cluster_size)
	fs.deallocate_sectors(&master, fd, fc, fo)
}

@test
test_chain_extension_multi_cluster :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	fc, fo, aerr := fs.allocate_sectors(&master, fd, 0, 0, 5, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	fc2, fo2, aerr2 := fs.allocate_sectors(&master, fd, fc, fo, 30, .File_Content)
	testing.expect_value(t, aerr2, fs.FS_Error.None)
	testing.expect_value(t, fc, fc2)
	testing.expect_value(t, fo, fo2)

	runs, runs_ok := fs.resolve_extents(fd, &master, fc, fo)
	testing.expect(t, runs_ok, "resolve_extents")
	total: u64
	for r in runs {total += u64(r.count)}
	testing.expect_value(t, total, u64(30))

	si := 0
	for run in runs {
		for _ in 0 ..< int(run.count) {
			buf: [fs.SECTOR_SIZE]u8
			for j in 0 ..< fs.SECTOR_SIZE {buf[j] = byte(si)}
			testing.expect(t, fs.sector_write(fd, fs.Sector(u64(run.sector) + u64(si)), buf[:]), "write")
			si += 1
		}
	}

	testing.expect_value(t, si, 30)
	si = 0
	for run in runs {
		for _ in 0 ..< int(run.count) {
			buf: [fs.SECTOR_SIZE]u8
			testing.expect(t, fs.sector_read(fd, fs.Sector(u64(run.sector) + u64(si)), buf[:]), "read")
			for j in 0 ..< fs.SECTOR_SIZE {testing.expect(t, buf[j] == byte(si), "verify")}
			si += 1
		}
	}

	fs.deallocate_sectors(&master, fd, fc, fo)
}

@test
test_dir_entry_create_delete_recreate :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	root_cluster := fs.Cluster(master.root_cluster)
	root_offset := fs.Sector_Offset(master.root_sector_index)
	rd_ce, ce_ok := fs.find_cluster_entry(fd, &master, root_cluster, root_offset)
	testing.expect(t, ce_ok, "root dir CE")
	dir_sector := rd_ce.sector_start

	now := time.now()
	y, mo, d := time.date(now)
	h, m, s := time.clock(now)

	buf: [fs.SECTOR_SIZE]u8
	table_sec := fs.Sector(u64(root_cluster) * master.cluster_size + u64(dir_sector))
	fs.sector_read(fd, table_sec, buf[:])
	raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(buf[:]))
	zf: fs.Dir_Flags
	free_idx := -1
	for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
		if raw[i].flags == zf {
			free_idx = i; break
		}
	}

	testing.expect(t, free_idx >= 0, "free slot")
	e := fs.Directory_Entry{flags = fs.Dir_Flags{.Allocated, .Exists}, year = u16(y), date_time = fs.Packed_Date_Time{month=u32(int(mo)), date=u32(d), hour=u32(h), minute=u32(m), second=u32(s)}}
	copy(e.file_name[:], "CYCLE")
	fs.write_directory_entry_at(fd, &master, root_cluster, fs.Sector_Offset(dir_sector), free_idx, &e)

	fs.sector_read(fd, table_sec, buf[:])
	re := raw[free_idx]
	testing.expect(t, .Exists in re.flags, "exists after create")

	re.flags -= {.Exists, .Allocated}
	fs.write_directory_entry_at(fd, &master, root_cluster, fs.Sector_Offset(dir_sector), free_idx, &re)

	fs.sector_read(fd, table_sec, buf[:])
	testing.expect(t, .Exists not_in raw[free_idx].flags, "free after delete")
	testing.expect(t, raw[free_idx].flags == zf, "zero flags")

	e2 := fs.Directory_Entry{flags = fs.Dir_Flags{.Allocated, .Exists}, year = u16(y + 1), date_time = fs.Packed_Date_Time{month=u32(int(mo)), date=u32(d), hour=u32(h), minute=u32(m), second=u32(s)}}
	copy(e2.file_name[:], "CYCLE")
	fs.write_directory_entry_at(fd, &master, root_cluster, fs.Sector_Offset(dir_sector), free_idx, &e2)

	fs.sector_read(fd, table_sec, buf[:])
	testing.expect(t, .Exists in raw[free_idx].flags, "exists after recreate")
	testing.expect_value(t, raw[free_idx].year, u16(y + 1))

	raw[free_idx].flags -= {.Exists, .Allocated}
	fs.write_directory_entry_at(fd, &master, root_cluster, fs.Sector_Offset(dir_sector), free_idx, &raw[free_idx])
}

@test
test_write_read_persistence :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	fc, fo, aerr := fs.allocate_sectors(&master, fd, 0, 0, 2, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	runs, _ := fs.resolve_extents(fd, &master, fc, fo)
	s0 := runs[0].sector
	s1 := fs.Sector(u64(runs[0].sector) + u64(runs[0].count) - 1)
	if len(runs) > 1 {s1 = runs[1].sector}

	hbuf: [fs.SECTOR_SIZE]u8
	copy(hbuf[:], "HELLO")
	testing.expect(t, fs.sector_write(fd, s0, hbuf[:]), "write HELLO")

	wbuf: [fs.SECTOR_SIZE]u8
	copy(wbuf[:], "WORLD")
	testing.expect(t, fs.sector_write(fd, s1, wbuf[:]), "write WORLD")

	rbuf: [fs.SECTOR_SIZE]u8
	testing.expect(t, fs.sector_read(fd, s0, rbuf[:]), "read 0")
	testing.expect(t, string(rbuf[:5]) == "HELLO", "verify HELLO")
	testing.expect(t, fs.sector_read(fd, s1, rbuf[:]), "read 1")
	testing.expect(t, string(rbuf[:5]) == "WORLD", "verify WORLD")
	fs.deallocate_sectors(&master, fd, fc, fo)
}

@test
test_rename_overwrite_simulation :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")
	zf: fs.Dir_Flags

	root_c := fs.Cluster(master.root_cluster)
	root_o := fs.Sector_Offset(master.root_sector_index)
	ce, ce_ok := fs.find_cluster_entry(fd, &master, root_c, root_o)
	testing.expect(t, ce_ok, "CE")

	buf: [fs.SECTOR_SIZE]u8
	buf[0] = 255
	sec := fs.Sector(u64(root_c) * master.cluster_size + u64(ce.sector_start))
	fs.sector_read(fd, sec, buf[:])
	raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(buf[:]))
	ia, ib := -1, -1
	for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
		if raw[i].flags == zf {
			if ia < 0 {ia = i} else if ib < 0 {ib = i; break}
		}
	}

	testing.expect(t, ia >= 0 && ib >= 0, "two free slots")
	ac, ao, aer := fs.allocate_sectors(&master, fd, 0, 0, 1, .File_Content)
	testing.expect_value(t, aer, fs.FS_Error.None)
	bc, bo, ber := fs.allocate_sectors(&master, fd, 0, 0, 1, .File_Content)
	testing.expect_value(t, ber, fs.FS_Error.None)

	ea := fs.Directory_Entry{flags = fs.Dir_Flags{.Allocated, .Exists}, stored_cluster = u64(ac), sector_index = u16(ao)}
	copy(ea.file_name[:], "SRC_A")
	fs.write_directory_entry_at(fd, &master, root_c, fs.Sector_Offset(ce.sector_start), ia, &ea)

	eb := fs.Directory_Entry{flags = fs.Dir_Flags{.Allocated, .Exists}, stored_cluster = u64(bc), sector_index = u16(bo)}
	copy(eb.file_name[:], "DST_B")
	fs.write_directory_entry_at(fd, &master, root_c, fs.Sector_Offset(ce.sector_start), ib, &eb)

	fs.deallocate_sectors(&master, fd, bc, bo)
	eb.flags -= {.Exists, .Allocated}
	fs.write_directory_entry_at(fd, &master, root_c, fs.Sector_Offset(ce.sector_start), ib, &eb)

	ea = {flags = fs.Dir_Flags{.Allocated, .Exists}, stored_cluster = u64(ac), sector_index = u16(ao)}
	copy(ea.file_name[:], "DST_NEW")
	fs.write_directory_entry_at(fd, &master, root_c, fs.Sector_Offset(ce.sector_start), ia, &ea)

	fs.sector_read(fd, sec, buf[:])
	testing.expect(t, .Exists in raw[ia].flags, "renamed exists")
	testing.expect(t, fs.entry_short_name(&raw[ia]) == "DST_NEW", "renamed name")
	testing.expect(t, raw[ia].stored_cluster == u64(ac), "renamed cluster")
	testing.expect(t, .Exists not_in raw[ib].flags, "old slot freed")
	testing.expect(t, raw[ib].flags == zf, "old slot zero")

	raw[ia].flags -= {.Exists, .Allocated}
	fs.write_directory_entry_at(fd, &master, root_c, fs.Sector_Offset(ce.sector_start), ia, &raw[ia])
	fs.deallocate_sectors(&master, fd, ac, ao)
}

@test
test_cross_dir_rename_simulation :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")
	zf: fs.Dir_Flags

	root_c := fs.Cluster(master.root_cluster)
	root_o := fs.Sector_Offset(master.root_sector_index)

	// Find two free slots in root
	rce, rce_ok := fs.find_cluster_entry(fd, &master, root_c, root_o)
	testing.expect(t, rce_ok, "root CE")
	rbuf: [fs.SECTOR_SIZE]u8
	rsec := fs.Sector(u64(root_c) * master.cluster_size + u64(rce.sector_start))
	fs.sector_read(fd, rsec, rbuf[:])
	rraw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(rbuf[:]))
	root_idx_a, root_idx_b := -1, -1
	for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
		if rraw[i].flags == zf {
			if root_idx_a < 0 {root_idx_a = i} else if root_idx_b < 0 {root_idx_b = i; break}
		}
	}
	testing.expect(t, root_idx_a >= 0 && root_idx_b >= 0, "root slots")

	// Create dirA
	ac, ao, derr_a := fs.allocate_sectors(&master, fd, 0, 0, 1, .Directory)
	testing.expect_value(t, derr_a, fs.FS_Error.None)
	druns_a, _ := fs.resolve_extents(fd, &master, ac, ao)
	zero_buf_a: [fs.SECTOR_SIZE]u8
	fs.sector_write(fd, druns_a[0].sector, zero_buf_a[:])
	ea := fs.Directory_Entry{flags = fs.Dir_Flags{.Allocated, .Directory, .Exists}, stored_cluster = u64(ac), sector_index = u16(ao)}
	copy(ea.file_name[:], "dirA")
	fs.write_directory_entry_at(fd, &master, root_c, fs.Sector_Offset(rce.sector_start), root_idx_a, &ea)

	// Create dirB
	bc, bo, derr_b := fs.allocate_sectors(&master, fd, 0, 0, 1, .Directory)
	testing.expect_value(t, derr_b, fs.FS_Error.None)
	druns_b, _ := fs.resolve_extents(fd, &master, bc, bo)
	zero_buf_b: [fs.SECTOR_SIZE]u8
	fs.sector_write(fd, druns_b[0].sector, zero_buf_b[:])
	eb := fs.Directory_Entry{flags = fs.Dir_Flags{.Allocated, .Directory, .Exists}, stored_cluster = u64(bc), sector_index = u16(bo)}
	copy(eb.file_name[:], "dirB")
	fs.write_directory_entry_at(fd, &master, root_c, fs.Sector_Offset(rce.sector_start), root_idx_b, &eb)

	// Create a file in dirA
	ace, ace_ok := fs.find_cluster_entry(fd, &master, ac, ao)
	testing.expect(t, ace_ok, "dirA CE")
	abuf: [fs.SECTOR_SIZE]u8
	asec := fs.Sector(u64(ac) * master.cluster_size + u64(ace.sector_start))
	fs.sector_read(fd, asec, abuf[:])
	araw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(abuf[:]))
	aidx := -1
	for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
		if araw[i].flags == zf {aidx = i; break}
	}
	testing.expect(t, aidx >= 0, "slot in dirA")

	fc, fo, ferr := fs.allocate_sectors(&master, fd, 0, 0, 1, .File_Content)
	testing.expect_value(t, ferr, fs.FS_Error.None)

	fe := fs.Directory_Entry{flags = fs.Dir_Flags{.Allocated, .Exists}, stored_cluster = u64(fc), sector_index = u16(fo)}
	copy(fe.file_name[:], "FILE")
	fs.write_directory_entry_at(fd, &master, ac, fs.Sector_Offset(ace.sector_start), aidx, &fe)

	// Find free slot in dirB
	bce, bce_ok := fs.find_cluster_entry(fd, &master, bc, bo)
	testing.expect(t, bce_ok, "dirB CE")
	bbuf: [fs.SECTOR_SIZE]u8
	bsec := fs.Sector(u64(bc) * master.cluster_size + u64(bce.sector_start))
	fs.sector_read(fd, bsec, bbuf[:])
	braw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(bbuf[:]))
	bidx := -1
	for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
		if braw[i].flags == zf {bidx = i; break}
	}
	testing.expect(t, bidx >= 0, "slot in dirB")

	// Copy entry to dirB, clear from dirA
	fs.write_directory_entry_at(fd, &master, bc, fs.Sector_Offset(bce.sector_start), bidx, &fe)
	araw[aidx].flags -= {.Exists, .Allocated}
	fs.write_directory_entry_at(fd, &master, ac, fs.Sector_Offset(ace.sector_start), aidx, &araw[aidx])

	// Verify FILE exists in dirB and not in dirA
	fs.sector_read(fd, bsec, bbuf[:])
	testing.expect(t, .Exists in braw[bidx].flags, "FILE in dirB")
	testing.expect(t, fs.entry_short_name(&braw[bidx]) == "FILE", "name in dirB")

	fs.sector_read(fd, asec, abuf[:])
	testing.expect(t, .Exists not_in araw[aidx].flags, "FILE not in dirA")

	// Cleanup
	braw[bidx].flags -= {.Exists, .Allocated}
	fs.write_directory_entry_at(fd, &master, bc, fs.Sector_Offset(bce.sector_start), bidx, &braw[bidx])
	fs.deallocate_sectors(&master, fd, fc, fo)
	rraw[root_idx_a].flags -= {.Exists, .Allocated}
	fs.write_directory_entry_at(fd, &master, root_c, fs.Sector_Offset(rce.sector_start), root_idx_a, &rraw[root_idx_a])
	rraw[root_idx_b].flags -= {.Exists, .Allocated}
	fs.write_directory_entry_at(fd, &master, root_c, fs.Sector_Offset(rce.sector_start), root_idx_b, &rraw[root_idx_b])
	fs.deallocate_sectors(&master, fd, ac, ao)
	fs.deallocate_sectors(&master, fd, bc, bo)
}

@test
test_atime_fields :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	// Create a fresh directory and write an entry with known timestamps
	dc, d_o, derr := fs.allocate_sectors(&master, fd, 0, 0, 1, .Directory)
	testing.expect_value(t, derr, fs.FS_Error.None)
	defer fs.deallocate_sectors(&master, fd, dc, d_o)

	druns, _ := fs.resolve_extents(fd, &master, dc, d_o)
	zero: [fs.SECTOR_SIZE]u8
	fs.sector_write(fd, druns[0].sector, zero[:])

	ce, ce_ok := fs.find_cluster_entry(fd, &master, dc, d_o)
	testing.expect(t, ce_ok, "CE")
	e := fs.Directory_Entry{
		flags = fs.Dir_Flags{.Allocated, .Exists},
		year = 2025,
		date_time = fs.Packed_Date_Time{month=6, date=15, hour=10, minute=30, second=45},
		atime_year = 2026,
		atime_date_time = fs.Packed_Date_Time{month=7, date=20, hour=14, minute=0, second=0},
	}

	copy(e.file_name[:], "ATIME")
	fs.write_directory_entry_at(fd, &master, dc, fs.Sector_Offset(ce.sector_start), 0, &e)

	// Read back and verify both mtime and atime
	buf: [fs.SECTOR_SIZE]u8
	sec := fs.Sector(u64(dc) * master.cluster_size + u64(ce.sector_start))
	fs.sector_read(fd, sec, buf[:])
	raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(buf[:]))
	re := raw[0]

	testing.expect(t, .Exists in re.flags, "exists")
	testing.expect_value(t, re.year, u16(2025))
	testing.expect_value(t, re.date_time.month, u32(6))
	testing.expect_value(t, re.date_time.date, u32(15))
	testing.expect_value(t, re.date_time.hour, u32(10))
	testing.expect_value(t, re.date_time.minute, u32(30))
	testing.expect_value(t, re.date_time.second, u32(45))

	testing.expect_value(t, re.atime_year, u16(2026))
	testing.expect_value(t, re.atime_date_time.month, u32(7))
	testing.expect_value(t, re.atime_date_time.date, u32(20))
	testing.expect_value(t, re.atime_date_time.hour, u32(14))
	testing.expect_value(t, re.atime_date_time.minute, u32(0))
	testing.expect_value(t, re.atime_date_time.second, u32(0))

	name := fs.entry_short_name(&re)
	testing.expect(t, name == "ATIME", "name")

	re.flags -= {.Exists, .Allocated}
	fs.write_directory_entry_at(fd, &master, dc, fs.Sector_Offset(ce.sector_start), 0, &re)
}
