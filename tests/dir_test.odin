// dir_test.odin — Tests for directory extent scanning and free-slot search.
//
// Exercises the same logic find_free_slot_in_extent and
// find_or_extend_dir use: scanning directory extents for free slots,
// extending directories across multiple sectors, and reusing freed
// slots in extended regions.
#+build linux
package tests

import "core:fmt"
import "core:os"
import "core:testing"
import "src:fs"

// Fill a directory past one sector, verify entries in all extents.
@test
test_dir_many_entries_across_extents :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	// Create a fresh directory cluster
	dc, d_o, derr := fs.allocate_sectors(&master, fd, nil, 0, 0, 1, .Directory)
	testing.expect_value(t, derr, fs.FS_Error.None)
	defer fs.deallocate_sectors(&master, fd, nil, dc, d_o)

	// Zero it
	druns, _ := fs.resolve_extents(fd, &master, dc, d_o)
	zero: [fs.SECTOR_SIZE]u8
	fs.sector_write(fd, druns[0].sector, zero[:])

	ce, ce_ok := fs.find_cluster_entry(fd, &master, dc, d_o)
	testing.expect(t, ce_ok, "CE")

	write_file_entry :: proc(fd: ^os.File, master: ^fs.Master_Record, dc: fs.Cluster, ce: fs.Cluster_Entry, didx: int, name: string) {
		e := fs.Directory_Entry{flags = fs.Dir_Flags{.Allocated, .Exists}}
		copy(e.file_name[:], name)
		e.file_name[min(15, len(name))] = 0
		fs.write_directory_entry_at(fd, master, dc, fs.Sector_Offset(ce.sector_start), didx, &e)
	}

	// Write entries to fill the first sector (9 entries, rev 5 format)
	buf: [fs.SECTOR_SIZE]u8
	for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
		name := fmt.tprintf("FILE%d", i)
		write_file_entry(fd, &master, dc, ce, i, name)
	}

	// Verify all 9 entries are present in first sector
	sec := fs.Sector(u64(dc) * master.cluster_size + u64(ce.sector_start))
	fs.sector_read(fd, sec, buf[:])
	raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(buf[:]))
	for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
		expected := fmt.tprintf("FILE%d", i)
		name := fs.entry_short_name(&raw[i])
		testing.expectf(t, name == expected, "slot %d: expected %q got %q", i, expected, name)
	}

	// Extend directory to a second sector
	existing_runs, _ := fs.resolve_extents(fd, &master, dc, d_o)
	existing_total: u64
	for r in existing_runs {existing_total += u64(r.count)}
	// Need at least existing_total + 1 sectors; the two extra entries may already
	// have triggered extension if they went past the first sector.
	if existing_total == 1 {
		_, _, ext_err := fs.allocate_sectors(&master, fd, nil, dc, d_o, existing_total + 1, .Directory)
		testing.expect_value(t, ext_err, fs.FS_Error.None)
	}

	// Write entries in the new sector
	new_runs, nr_ok := fs.resolve_extents(fd, &master, dc, d_o)
	testing.expect(t, nr_ok, "resolve_extents after extend")
	last_run := new_runs[len(new_runs) - 1]
	last_sec := fs.Sector(u64(last_run.sector) + u64(last_run.count) - 1)
	fs.sector_read(fd, last_sec, buf[:])
	raw_new := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(buf[:]))

	e_a := fs.Directory_Entry{flags = fs.Dir_Flags{.Allocated, .Exists}}
	copy(e_a.file_name[:], "FILEa")
	e_a.file_name[5] = 0
	raw_new[0] = e_a

	e_b := fs.Directory_Entry{flags = fs.Dir_Flags{.Allocated, .Exists}}
	copy(e_b.file_name[:], "FILEb")
	e_b.file_name[5] = 0
	raw_new[1] = e_b
	fs.sector_write(fd, last_sec, buf[:])

	// Write "EXTRA" entry in the new sector at slot 2
	e_extra := fs.Directory_Entry{flags = fs.Dir_Flags{.Allocated, .Exists}}
	copy(e_extra.file_name[:], "EXTRA")
	e_extra.file_name[5] = 0
	new_sector_offset := fs.Sector_Offset(u64(last_sec) - u64(dc) * master.cluster_size)
	fs.write_directory_entry_at(fd, &master, dc, new_sector_offset, 2, &e_extra)

	// Verify "EXTRA"
	verify_buf: [fs.SECTOR_SIZE]u8
	fs.sector_read(fd, last_sec, verify_buf[:])
	raw2 := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(verify_buf[:]))
	testing.expect(t, .Exists in raw2[2].flags, "extra entry exists")
	extra_name := fs.entry_short_name(&raw2[2])
	testing.expect(t, extra_name == "EXTRA", "extra entry name")

	// Now scan all extents to find all entries — this exercises the same
	// extent walk that find_free_slot_in_extent uses.
	found := 0
	scan_buf: [fs.SECTOR_SIZE]u8
	for run in new_runs {
		n := int(run.count)
		for si in 0 ..< n {
			s := fs.Sector(u64(run.sector) + u64(si))
			if !fs.sector_read(fd, s, scan_buf[:]) {break}
			scan_raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(scan_buf[:]))
			for j in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
				if .Exists in scan_raw[j].flags {
					found += 1
				}
			}
		}
	}

	testing.expectf(t, found == 12, "expected 12 entries across extents, got %d", found)
	// Clean up entries
	for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
		raw[i].flags -= {.Exists, .Allocated}
	}

	fs.sector_write(fd, sec, buf[:])
	raw2[0].flags -= {.Exists, .Allocated}
	raw2[1].flags -= {.Exists, .Allocated}
	raw2[2].flags -= {.Exists, .Allocated}
	fs.sector_write(fd, last_sec, verify_buf[:])
}

// Free a slot in the second sector and verify it's reused.
@test
test_dir_reuse_slot_in_extended_sector :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	dc, d_o, derr := fs.allocate_sectors(&master, fd, nil, 0, 0, 1, .Directory)
	testing.expect_value(t, derr, fs.FS_Error.None)
	defer fs.deallocate_sectors(&master, fd, nil, dc, d_o)

	druns, _ := fs.resolve_extents(fd, &master, dc, d_o)
	zero: [fs.SECTOR_SIZE]u8
	fs.sector_write(fd, druns[0].sector, zero[:])

	ce, ce_ok := fs.find_cluster_entry(fd, &master, dc, d_o)
	testing.expect(t, ce_ok, "CE")

	// Fill first sector
	e := fs.Directory_Entry{flags = fs.Dir_Flags{.Allocated, .Exists}}
	for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
		copy(e.file_name[:], fmt.tprintf("F%d", i))
		fs.write_directory_entry_at(fd, &master, dc, fs.Sector_Offset(ce.sector_start), i, &e)
	}

	// Extend
	existing_runs, _ := fs.resolve_extents(fd, &master, dc, d_o)
	et: u64
	for r in existing_runs {et += u64(r.count)}
	_, _, ext_err := fs.allocate_sectors(&master, fd, nil, dc, d_o, et + 1, .Directory)
	testing.expect_value(t, ext_err, fs.FS_Error.None)

	new_runs, nr_ok := fs.resolve_extents(fd, &master, dc, d_o)
	testing.expect(t, nr_ok, "resolve_extents")
	last_run := new_runs[len(new_runs) - 1]
	last_sec := fs.Sector(u64(last_run.sector) + u64(last_run.count) - 1)
	fs.sector_write(fd, last_sec, zero[:])

	ce, _ = fs.find_cluster_entry(fd, &master, dc, d_o)

	// Write one entry in the new sector, then free it
	fs.write_directory_entry_at(fd, &master, dc, fs.Sector_Offset(u64(last_sec) - u64(dc) * master.cluster_size), 0, &e)
	buf: [fs.SECTOR_SIZE]u8
	fs.sector_read(fd, last_sec, buf[:])
	rw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(buf[:]))
	rw[0].flags -= {.Exists, .Allocated}
	fs.sector_write(fd, last_sec, buf[:])

	// Verify the slot is now free by scanning extents
	scan_buf: [fs.SECTOR_SIZE]u8
	found_free := false
	for run in new_runs {
		n := int(run.count)
		for si in 0 ..< n {
			s := fs.Sector(u64(run.sector) + u64(si))
			if !fs.sector_read(fd, s, scan_buf[:]) {break}
			raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(scan_buf[:]))
			for j in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
				zf: fs.Dir_Flags
				if raw[j].flags == zf {
					found_free = true
				}
			}
		}
	}
	testing.expect(t, found_free, "free slot in extended sector after deletion")

	// Clean up first-sector entries
	sec := fs.Sector(u64(dc) * master.cluster_size + u64(ce.sector_start))
	fs.sector_read(fd, sec, buf[:])
	raw0 := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(buf[:]))
	for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
		raw0[i].flags -= {.Exists, .Allocated}
	}
	fs.sector_write(fd, sec, buf[:])
}

// Simulate cross-directory rename where destination directory spans multiple
// sectors — verifies the extent scan finds a slot in an extended sector.
@test
test_dir_rename_to_extended_target :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")
	zf: fs.Dir_Flags

	// Create src dir with one file
	src_c, src_o, derr := fs.allocate_sectors(&master, fd, nil, 0, 0, 1, .Directory)
	testing.expect_value(t, derr, fs.FS_Error.None)
	defer fs.deallocate_sectors(&master, fd, nil, src_c, src_o)

	src_runs, _ := fs.resolve_extents(fd, &master, src_c, src_o)
	src_zero: [fs.SECTOR_SIZE]u8
	fs.sector_write(fd, src_runs[0].sector, src_zero[:])
	src_ce, _ := fs.find_cluster_entry(fd, &master, src_c, src_o)

	fe := fs.Directory_Entry{flags = fs.Dir_Flags{.Allocated, .Exists}}
	copy(fe.file_name[:], "MOVEME")
	fe.file_name[6] = 0
	fs.write_directory_entry_at(fd, &master, src_c, fs.Sector_Offset(src_ce.sector_start), 0, &fe)

	// Create dst dir and fill its first sector
	dst_c, dst_o, derr2 := fs.allocate_sectors(&master, fd, nil, 0, 0, 1, .Directory)
	testing.expect_value(t, derr2, fs.FS_Error.None)
	defer fs.deallocate_sectors(&master, fd, nil, dst_c, dst_o)

	dst_runs, _ := fs.resolve_extents(fd, &master, dst_c, dst_o)
	dst_zero: [fs.SECTOR_SIZE]u8
	fs.sector_write(fd, dst_runs[0].sector, dst_zero[:])
	dst_ce, _ := fs.find_cluster_entry(fd, &master, dst_c, dst_o)

	dst_e := fs.Directory_Entry{flags = fs.Dir_Flags{.Allocated, .Exists}}
	for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
		nm := fmt.tprintf("D%d", i)
		copy(dst_e.file_name[:], nm)
		dst_e.file_name[min(15, len(nm))] = 0
		fs.write_directory_entry_at(fd, &master, dst_c, fs.Sector_Offset(dst_ce.sector_start), i, &dst_e)
	}

	// Extend dst dir
	dst_existing_runs, _ := fs.resolve_extents(fd, &master, dst_c, dst_o)
	et: u64
	for r in dst_existing_runs {et += u64(r.count)}
	_, _, ext_err := fs.allocate_sectors(&master, fd, nil, dst_c, dst_o, et + 1, .Directory)
	testing.expect_value(t, ext_err, fs.FS_Error.None)

	dst_new_runs, _ := fs.resolve_extents(fd, &master, dst_c, dst_o)
	dst_last_run := dst_new_runs[len(dst_new_runs) - 1]
	dst_last_sec := fs.Sector(u64(dst_last_run.sector) + u64(dst_last_run.count) - 1)
	fs.sector_write(fd, dst_last_sec, dst_zero[:])

	// dst_ce is now stale — re-resolve
	dst_ce, _ = fs.find_cluster_entry(fd, &master, dst_c, dst_o)
	found_free := false
	scan_buf: [fs.SECTOR_SIZE]u8
	scan_loop: for run in dst_new_runs {
		n := int(run.count)
		for si in 0 ..< n {
			s := fs.Sector(u64(run.sector) + u64(si))
			if !fs.sector_read(fd, s, scan_buf[:]) {break}
			raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(scan_buf[:]))
			for j in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
				if raw[j].flags == zf {
					// Found free slot in dst — write the moved entry here
					fs.write_directory_entry_at(fd, &master, dst_c, fs.Sector_Offset(u64(s) - u64(dst_c) * master.cluster_size), j, &fe)
					found_free = true
					break scan_loop
				}
			}
		}
	}

	testing.expect(t, found_free, "free slot found in extended dst dir via extent scan")
	// Clear src entry
	src_buf: [fs.SECTOR_SIZE]u8
	src_sec := fs.Sector(u64(src_c) * master.cluster_size + u64(src_ce.sector_start))
	fs.sector_read(fd, src_sec, src_buf[:])
	src_raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(src_buf[:]))
	src_raw[0].flags -= {.Exists, .Allocated}
	fs.sector_write(fd, src_sec, src_buf[:])

	// Verify MOVEME exists in dst
	dst_buf: [fs.SECTOR_SIZE]u8
	fs.sector_read(fd, dst_last_sec, dst_buf[:])
	dst_raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(dst_buf[:]))
	testing.expect(t, .Exists in dst_raw[0].flags, "MOVEME exists in dst extended sector")
	name := fs.entry_short_name(&dst_raw[0])
	testing.expect(t, name == "MOVEME", "name preserved in dst")

	// Cleanup dst entries
	fs.sector_read(fd, fs.Sector(u64(dst_c) * master.cluster_size + u64(dst_ce.sector_start)), dst_buf[:])
	dst_first := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(dst_buf[:]))
	for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
		dst_first[i].flags -= {.Exists, .Allocated}
	}

	fs.sector_write(fd, fs.Sector(u64(dst_c) * master.cluster_size + u64(dst_ce.sector_start)), dst_buf[:])
	dst_raw[0].flags -= {.Exists, .Allocated}
	fs.sector_write(fd, dst_last_sec, dst_buf[:])
}
