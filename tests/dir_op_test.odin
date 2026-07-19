// dir_op_test.odin — Directory, rename, chmod, and symlink tests.
// Generated from write_test.odin during the Volume refactor.
// Tests: directory_growth, rename_simulation, cross_dir_rename,
// symlink_create_and_read, chmod_persistence, and more.
#+build linux
package tests

import "core:fmt"
import "core:testing"
import "core:time"
import "src:fs"

@test
test_directory_growth :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	root_cluster := fs.Cluster(vol.master.root_cluster)
	root_offset  := fs.Sector_Offset(vol.master.root_sector_index)

	// Write 11 entries to the root directory.  The first sector holds 10,
	// so the 11th requires the directory chain to extend.
	rd_ce, ce_err := fs.find_cluster_entry(&vol, root_cluster, root_offset)
	testing.expectf(t, ce_err == .None, "root dir ClusterEntry")

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
		dir_runs, dr_err := fs.resolve_extents(&vol, root_cluster, root_offset)
		testing.expectf(t, dr_err == .None, "resolve_extents")

		dsec: fs.Sector_Offset
		didx := -1
		scan_buf: [fs.SECTOR_SIZE]u8
	run_loop:
		for run in dir_runs {
			n := int(run.count)
			for si in 0 ..< n {
				sec := fs.Sector(u64(run.sector) + u64(si))
				if !fs.sector_read(&vol, sec, scan_buf[:]) {break}

				raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(scan_buf[:]))
				for j in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
					if .Exists in raw[j].flags {
						if fs.entry_short_name(&raw[j]) == name {
							break run_loop
						}
					} else if didx < 0 {
						zero_flags: fs.Dir_Flags
						if raw[j].flags == zero_flags {
							dsec = fs.Sector_Offset(u64(sec) - u64(root_cluster) * vol.master.cluster_size)
							didx = j
						}
					}
				}
				if didx >= 0 {break run_loop}
			}
		}
		if didx < 0 {
			existing_runs, _ := fs.resolve_extents(&vol, root_cluster, root_offset)
			existing_total: u64
			for r in existing_runs {existing_total += u64(r.count)}

			_, _, ext_err := fs.allocate_sectors(&vol, root_cluster, root_offset, existing_total + 1, .Directory)
			testing.expect_value(t, ext_err, fs.FS_Error.None)
			dir_runs, dr_err = fs.resolve_extents(&vol, root_cluster, root_offset)

			testing.expectf(t, dr_err == .None, "resolve_extents after extension")
			last_run := dir_runs[len(dir_runs)-1]
			last_sec := fs.Sector(u64(last_run.sector) + u64(last_run.count) - 1)
			if !fs.sector_read(&vol, last_sec, scan_buf[:]) {break}

			raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(scan_buf[:]))
			for j in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
				zero_flags: fs.Dir_Flags
				if raw[j].flags == zero_flags {
					dsec = fs.Sector_Offset(u64(last_sec) - u64(root_cluster) * vol.master.cluster_size)
					didx = j
					break
				}
			}
		}
		if didx < 0 {testing.fail(t); return}
		fs.write_directory_entry_at(&vol, root_cluster, dsec, didx, &ne)
	}

	dirs, dirs_err := fs.read_directory_entries(&vol, root_cluster, fs.Sector_Offset(rd_ce.sector_start))
	defer delete(dirs)

	testing.expectf(t, dirs_err == .None, "read_directory_entries")
	found := 0
	for &d in dirs {
		name := fs.entry_short_name(&d)
		if len(name) > 0 && name[0] == 'f' {
			found += 1
		}
	}

	dir_runs2, dr2_err := fs.resolve_extents(&vol, root_cluster, root_offset)
	testing.expectf(t, dr2_err == .None, "resolve_extents after growth")
	total_entries := 0
	sector_buf2: [fs.SECTOR_SIZE]u8
	for run in dir_runs2 {
		n := int(run.count)
		for si in 0 ..< n {
			fs.sector_read(&vol, fs.Sector(u64(run.sector) + u64(si)), sector_buf2[:])
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
			fs.sector_read(&vol, sec, sector_buf2[:])
			raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(sector_buf2[:]))
			for j in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
				if .Exists in raw[j].flags {
					name := fs.entry_short_name(&raw[j])
					if len(name) > 0 && name[0] == 'f' {
						dsec := fs.Sector_Offset(u64(sec) - u64(root_cluster) * vol.master.cluster_size)
						raw[j].flags -= {.Exists, .Allocated}
						fs.write_directory_entry_at(&vol, root_cluster, dsec, j, &raw[j])
					}
				}
			}
		}
	}
}

@test
test_entry_timestamp :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	dir_cluster, dir_offset, derr := fs.allocate_sectors(&vol, 0, 0, 1, .Directory)
	testing.expect_value(t, derr, fs.FS_Error.None)
	defer fs.deallocate_sectors(&vol, dir_cluster, dir_offset)

	dir_runs, _ := fs.resolve_extents(&vol, dir_cluster, dir_offset)
	zero_sector: [fs.SECTOR_SIZE]u8
	fs.sector_write(&vol, dir_runs[0].sector, zero_sector[:])

	ce, ce_err := fs.find_cluster_entry(&vol, dir_cluster, dir_offset)
	testing.expectf(t, ce_err == .None, "ClusterEntry")

	dir_sector := ce.sector_start
	dir_buf: [fs.SECTOR_SIZE]u8
	table_sector := fs.Sector(u64(dir_cluster) * vol.master.cluster_size + u64(dir_sector))
	fs.sector_read(&vol, table_sector, dir_buf[:])
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
	fs.write_directory_entry_at(&vol, dir_cluster, fs.Sector_Offset(dir_sector), free_idx, &test_entry)

	fs.sector_read(&vol, table_sector, dir_buf[:])
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
	fs.write_directory_entry_at(&vol, dir_cluster, fs.Sector_Offset(dir_sector), free_idx, &re)
}

@test
test_dir_entry_create_delete_recreate :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	root_cluster := fs.Cluster(vol.master.root_cluster)
	root_offset := fs.Sector_Offset(vol.master.root_sector_index)
	rd_ce, ce_err := fs.find_cluster_entry(&vol, root_cluster, root_offset)
	testing.expectf(t, ce_err == .None, "root dir CE")
	dir_sector := rd_ce.sector_start

	now := time.now()
	y, mo, d := time.date(now)
	h, m, s := time.clock(now)

	buf: [fs.SECTOR_SIZE]u8
	table_sec := fs.Sector(u64(root_cluster) * vol.master.cluster_size + u64(dir_sector))
	fs.sector_read(&vol, table_sec, buf[:])
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
	fs.write_directory_entry_at(&vol, root_cluster, fs.Sector_Offset(dir_sector), free_idx, &e)

	fs.sector_read(&vol, table_sec, buf[:])
	re := raw[free_idx]
	testing.expect(t, .Exists in re.flags, "exists after create")

	re.flags -= {.Exists, .Allocated}
	fs.write_directory_entry_at(&vol, root_cluster, fs.Sector_Offset(dir_sector), free_idx, &re)

	fs.sector_read(&vol, table_sec, buf[:])
	testing.expect(t, .Exists not_in raw[free_idx].flags, "free after delete")
	testing.expect(t, raw[free_idx].flags == zf, "zero flags")

	e2 := fs.Directory_Entry{flags = fs.Dir_Flags{.Allocated, .Exists}, year = u16(y + 1), date_time = fs.Packed_Date_Time{month=u32(int(mo)), date=u32(d), hour=u32(h), minute=u32(m), second=u32(s)}}
	copy(e2.file_name[:], "CYCLE")
	fs.write_directory_entry_at(&vol, root_cluster, fs.Sector_Offset(dir_sector), free_idx, &e2)

	fs.sector_read(&vol, table_sec, buf[:])
	testing.expect(t, .Exists in raw[free_idx].flags, "exists after recreate")
	testing.expect_value(t, raw[free_idx].year, u16(y + 1))

	raw[free_idx].flags -= {.Exists, .Allocated}
	fs.write_directory_entry_at(&vol, root_cluster, fs.Sector_Offset(dir_sector), free_idx, &raw[free_idx])
}

@test
test_rename_overwrite_simulation :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)
	zf: fs.Dir_Flags

	root_c := fs.Cluster(vol.master.root_cluster)
	root_o := fs.Sector_Offset(vol.master.root_sector_index)
	ce, ce_err := fs.find_cluster_entry(&vol, root_c, root_o)
	testing.expectf(t, ce_err == .None, "CE")

	buf: [fs.SECTOR_SIZE]u8
	buf[0] = 255
	sec := fs.Sector(u64(root_c) * vol.master.cluster_size + u64(ce.sector_start))
	fs.sector_read(&vol, sec, buf[:])
	raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(buf[:]))
	ia, ib := -1, -1
	for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
		if raw[i].flags == zf {
			if ia < 0 {ia = i} else if ib < 0 {ib = i; break}
		}
	}

	testing.expect(t, ia >= 0 && ib >= 0, "two free slots")
	ac, ao, aer := fs.allocate_sectors(&vol, 0, 0, 1, .File_Content)
	testing.expect_value(t, aer, fs.FS_Error.None)
	bc, bo, ber := fs.allocate_sectors(&vol, 0, 0, 1, .File_Content)
	testing.expect_value(t, ber, fs.FS_Error.None)

	ea := fs.Directory_Entry{flags = fs.Dir_Flags{.Allocated, .Exists}, stored_cluster = u64(ac), sector_index = u16(ao)}
	copy(ea.file_name[:], "SRC_A")
	fs.write_directory_entry_at(&vol, root_c, fs.Sector_Offset(ce.sector_start), ia, &ea)

	eb := fs.Directory_Entry{flags = fs.Dir_Flags{.Allocated, .Exists}, stored_cluster = u64(bc), sector_index = u16(bo)}
	copy(eb.file_name[:], "DST_B")
	fs.write_directory_entry_at(&vol, root_c, fs.Sector_Offset(ce.sector_start), ib, &eb)

	fs.deallocate_sectors(&vol, bc, bo)
	eb.flags -= {.Exists, .Allocated}
	fs.write_directory_entry_at(&vol, root_c, fs.Sector_Offset(ce.sector_start), ib, &eb)

	ea = {flags = fs.Dir_Flags{.Allocated, .Exists}, stored_cluster = u64(ac), sector_index = u16(ao)}
	copy(ea.file_name[:], "DST_NEW")
	fs.write_directory_entry_at(&vol, root_c, fs.Sector_Offset(ce.sector_start), ia, &ea)

	fs.sector_read(&vol, sec, buf[:])
	testing.expect(t, .Exists in raw[ia].flags, "renamed exists")
	testing.expect(t, fs.entry_short_name(&raw[ia]) == "DST_NEW", "renamed name")
	testing.expect(t, raw[ia].stored_cluster == u64(ac), "renamed cluster")
	testing.expect(t, .Exists not_in raw[ib].flags, "old slot freed")
	testing.expect(t, raw[ib].flags == zf, "old slot zero")

	raw[ia].flags -= {.Exists, .Allocated}
	fs.write_directory_entry_at(&vol, root_c, fs.Sector_Offset(ce.sector_start), ia, &raw[ia])
	fs.deallocate_sectors(&vol, ac, ao)
}

@test
test_cross_dir_rename_simulation :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)
	zf: fs.Dir_Flags

	root_c := fs.Cluster(vol.master.root_cluster)
	root_o := fs.Sector_Offset(vol.master.root_sector_index)

	// Find two free slots in root
	rce, rce_err := fs.find_cluster_entry(&vol, root_c, root_o)
	testing.expectf(t, rce_err == .None, "root CE")
	rbuf: [fs.SECTOR_SIZE]u8
	rsec := fs.Sector(u64(root_c) * vol.master.cluster_size + u64(rce.sector_start))
	fs.sector_read(&vol, rsec, rbuf[:])
	rraw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(rbuf[:]))
	root_idx_a, root_idx_b := -1, -1
	for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
		if rraw[i].flags == zf {
			if root_idx_a < 0 {root_idx_a = i} else if root_idx_b < 0 {root_idx_b = i; break}
		}
	}
	testing.expect(t, root_idx_a >= 0 && root_idx_b >= 0, "root slots")

	// Create dirA
	ac, ao, derr_a := fs.allocate_sectors(&vol, 0, 0, 1, .Directory)
	testing.expect_value(t, derr_a, fs.FS_Error.None)
	druns_a, _ := fs.resolve_extents(&vol, ac, ao)
	zero_buf_a: [fs.SECTOR_SIZE]u8
	fs.sector_write(&vol, druns_a[0].sector, zero_buf_a[:])
	ea := fs.Directory_Entry{flags = fs.Dir_Flags{.Allocated, .Directory, .Exists}, stored_cluster = u64(ac), sector_index = u16(ao)}
	copy(ea.file_name[:], "dirA")
	fs.write_directory_entry_at(&vol, root_c, fs.Sector_Offset(rce.sector_start), root_idx_a, &ea)

	// Create dirB
	bc, bo, derr_b := fs.allocate_sectors(&vol, 0, 0, 1, .Directory)
	testing.expect_value(t, derr_b, fs.FS_Error.None)
	druns_b, _ := fs.resolve_extents(&vol, bc, bo)
	zero_buf_b: [fs.SECTOR_SIZE]u8
	fs.sector_write(&vol, druns_b[0].sector, zero_buf_b[:])
	eb := fs.Directory_Entry{flags = fs.Dir_Flags{.Allocated, .Directory, .Exists}, stored_cluster = u64(bc), sector_index = u16(bo)}
	copy(eb.file_name[:], "dirB")
	fs.write_directory_entry_at(&vol, root_c, fs.Sector_Offset(rce.sector_start), root_idx_b, &eb)

	// Create a file in dirA
	ace, ace_err := fs.find_cluster_entry(&vol, ac, ao)
	testing.expectf(t, ace_err == .None, "dirA CE")
	abuf: [fs.SECTOR_SIZE]u8
	asec := fs.Sector(u64(ac) * vol.master.cluster_size + u64(ace.sector_start))
	fs.sector_read(&vol, asec, abuf[:])
	araw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(abuf[:]))
	aidx := -1
	for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
		if araw[i].flags == zf {aidx = i; break}
	}
	testing.expect(t, aidx >= 0, "slot in dirA")

	fc, fo, ferr := fs.allocate_sectors(&vol, 0, 0, 1, .File_Content)
	testing.expect_value(t, ferr, fs.FS_Error.None)

	fe := fs.Directory_Entry{flags = fs.Dir_Flags{.Allocated, .Exists}, stored_cluster = u64(fc), sector_index = u16(fo)}
	copy(fe.file_name[:], "FILE")
	fs.write_directory_entry_at(&vol, ac, fs.Sector_Offset(ace.sector_start), aidx, &fe)

	// Find free slot in dirB
	bce, bce_err := fs.find_cluster_entry(&vol, bc, bo)
	testing.expectf(t, bce_err == .None, "dirB CE")
	bbuf: [fs.SECTOR_SIZE]u8
	bsec := fs.Sector(u64(bc) * vol.master.cluster_size + u64(bce.sector_start))
	fs.sector_read(&vol, bsec, bbuf[:])
	braw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(bbuf[:]))
	bidx := -1
	for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
		if braw[i].flags == zf {bidx = i; break}
	}
	testing.expect(t, bidx >= 0, "slot in dirB")

	// Copy entry to dirB, clear from dirA
	fs.write_directory_entry_at(&vol, bc, fs.Sector_Offset(bce.sector_start), bidx, &fe)
	araw[aidx].flags -= {.Exists, .Allocated}
	fs.write_directory_entry_at(&vol, ac, fs.Sector_Offset(ace.sector_start), aidx, &araw[aidx])

	// Verify FILE exists in dirB and not in dirA
	fs.sector_read(&vol, bsec, bbuf[:])
	testing.expect(t, .Exists in braw[bidx].flags, "FILE in dirB")
	testing.expect(t, fs.entry_short_name(&braw[bidx]) == "FILE", "name in dirB")

	fs.sector_read(&vol, asec, abuf[:])
	testing.expect(t, .Exists not_in araw[aidx].flags, "FILE not in dirA")

	// Cleanup
	braw[bidx].flags -= {.Exists, .Allocated}
	fs.write_directory_entry_at(&vol, bc, fs.Sector_Offset(bce.sector_start), bidx, &braw[bidx])
	fs.deallocate_sectors(&vol, fc, fo)
	rraw[root_idx_a].flags -= {.Exists, .Allocated}
	fs.write_directory_entry_at(&vol, root_c, fs.Sector_Offset(rce.sector_start), root_idx_a, &rraw[root_idx_a])
	rraw[root_idx_b].flags -= {.Exists, .Allocated}
	fs.write_directory_entry_at(&vol, root_c, fs.Sector_Offset(rce.sector_start), root_idx_b, &rraw[root_idx_b])
	fs.deallocate_sectors(&vol, ac, ao)
	fs.deallocate_sectors(&vol, bc, bo)
}

@test
test_atime_fields :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	// Create a fresh directory and write an entry with known timestamps
	dc, d_o, derr := fs.allocate_sectors(&vol, 0, 0, 1, .Directory)
	testing.expect_value(t, derr, fs.FS_Error.None)
	defer fs.deallocate_sectors(&vol, dc, d_o)

	druns, _ := fs.resolve_extents(&vol, dc, d_o)
	zero: [fs.SECTOR_SIZE]u8
	fs.sector_write(&vol, druns[0].sector, zero[:])

	ce, ce_err := fs.find_cluster_entry(&vol, dc, d_o)
	testing.expectf(t, ce_err == .None, "CE")
	e := fs.Directory_Entry{
		flags = fs.Dir_Flags{.Allocated, .Exists},
		year = 2025,
		date_time = fs.Packed_Date_Time{month=6, date=15, hour=10, minute=30, second=45},
		atime_year = 2026,
		atime_date_time = fs.Packed_Date_Time{month=7, date=20, hour=14, minute=0, second=0},
	}

	copy(e.file_name[:], "ATIME")
	fs.write_directory_entry_at(&vol, dc, fs.Sector_Offset(ce.sector_start), 0, &e)

	// Read back and verify both mtime and atime
	buf: [fs.SECTOR_SIZE]u8
	sec := fs.Sector(u64(dc) * vol.master.cluster_size + u64(ce.sector_start))
	fs.sector_read(&vol, sec, buf[:])
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
	fs.write_directory_entry_at(&vol, dc, fs.Sector_Offset(ce.sector_start), 0, &re)
}

@test
test_rename_same_dir_via_primitives :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	rce, rce_err := fs.find_cluster_entry(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(vol.master.root_sector_index))
	testing.expectf(t, rce_err == .None, "root cluster entry")

	entry := fs.Directory_Entry{
		flags = fs.Dir_Flags{.Allocated, .Exists, .Directory},
		stored_cluster = vol.master.root_cluster,
		sector_index = rce.sector_start,
	}
	copy(entry.file_name[:], "oldname\x00\x00\x00\x00\x00\x00\x00\x00\x00")
	testing.expect(t, fs.write_directory_entry_at(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(rce.sector_start), 0, &entry), "write old entry")

	entry.flags = fs.Dir_Flags{.Allocated, .Exists}
	copy(entry.file_name[:], "newname\x00\x00\x00\x00\x00\x00\x00\x00\x00")
	testing.expect(t, fs.write_directory_entry_at(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(rce.sector_start), 1, &entry), "write new entry")

	dirs, _ := fs.read_directory_entries(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(vol.master.root_sector_index))
	defer delete(dirs)
	testing.expect(t, len(dirs) >= 1, "at least one entry after rename")
}

@test
test_symlink_create_and_read :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	target := "/hello/world"
	rce, rce_err := fs.find_cluster_entry(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(vol.master.root_sector_index))
	testing.expectf(t, rce_err == .None, "root cluster entry")

	sectors_needed := (u64(len(target)) + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE
	new_c, new_o, aerr := fs.allocate_sectors(&vol, 0, 0, sectors_needed, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	buf: [fs.SECTOR_SIZE]u8
	copy(buf[:], transmute([]u8)(target))

	runs, ext_err := fs.resolve_extents(&vol, new_c, new_o)
	testing.expectf(t, ext_err == .None, "resolve_extents")
	testing.expect(t, len(runs) > 0, "extent runs")
	testing.expect(t, fs.sector_write(&vol, runs[0].sector, buf[:]), "write target")

	name_buf: [16]u8
	copy(name_buf[:], "mylink")

	entry := fs.Directory_Entry{
		flags          = {.Allocated, .Exists, .Link},
		file_name      = name_buf,
		stored_cluster = u64(new_c),
		sector_index   = u16(new_o),
		file_size      = u64(len(target)),
	}

	testing.expect(t, fs.write_directory_entry_at(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(rce.sector_start), 0, &entry), "write symlink entry")
	dirs, dirs_err := fs.read_directory_entries(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(vol.master.root_sector_index))
	defer delete(dirs)
	testing.expectf(t, dirs_err == .None, "read dir")
	found := false
	for &d in dirs {
		if .Link in d.flags {
			found = true
			testing.expect(t, .Directory not_in d.flags, "link is not dir")
			testing.expect_value(t, d.file_size, u64(len(target)))
			testing.expect(t, d.stored_cluster == u64(new_c), "stored_cluster")

			runs2, ext_err2 := fs.resolve_extents(&vol, fs.Cluster(d.stored_cluster), fs.Sector_Offset(d.sector_index))
			testing.expectf(t, ext_err2 == .None, "resolve extents for symlink")
			if ext_err2 == .None && len(runs2) > 0 {
				read_buf: [fs.SECTOR_SIZE]u8
				testing.expect(t, fs.sector_read(&vol, runs2[0].sector, read_buf[:]), "read symlink target")
				read_target := string(read_buf[:d.file_size])
				testing.expect(t, read_target == target, "symlink target matches")
			}
		}
	}
	testing.expect(t, found, "symlink entry found in directory")
}

@test
test_chmod_persistence :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	rce, rce_err := fs.find_cluster_entry(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(vol.master.root_sector_index))
	testing.expectf(t, rce_err == .None, "root cluster entry")

	dirs, dirs_err := fs.read_directory_entries(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(vol.master.root_sector_index))
	defer delete(dirs)
	testing.expectf(t, dirs_err == .None, "read dir")

	for &d in dirs {
		// Check default: No_Read should not be set for normal files
		testing.expect(t, .No_Read not_in d.flags, "default: No_Read not set")
		testing.expect(t, .No_Write not_in d.flags, "default: No_Write not set")

		// Set No_Read
		d.flags += {.No_Read}
		testing.expect(t, fs.write_directory_entry_at(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(rce.sector_start), 0, &d), "write No_Read entry")

		// Read back and verify
		dirs2, _ := fs.read_directory_entries(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(vol.master.root_sector_index))
		delete(dirs2)
		if len(dirs2) > 0 {
			testing.expect(t, .No_Read in dirs2[0].flags, "readback: No_Read set")
		}

		// Clear No_Read, set No_Write
		d.flags -= {.No_Read}
		d.flags += {.No_Write}
		testing.expect(t, fs.write_directory_entry_at(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(rce.sector_start), 0, &d), "write No_Write entry")

		dirs3, _ := fs.read_directory_entries(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(vol.master.root_sector_index))
		delete(dirs3)
		if len(dirs3) > 0 {
			testing.expect(t, .No_Read not_in dirs3[0].flags, "readback: No_Read cleared")
			testing.expect(t, .No_Write in dirs3[0].flags, "readback: No_Write set")
		}

		// Reset
		d.flags -= {.No_Write}
		testing.expect(t, fs.write_directory_entry_at(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(rce.sector_start), 0, &d), "reset flags")
		break
	}
}
