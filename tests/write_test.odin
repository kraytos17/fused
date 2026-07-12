// write_test.odin — Non-FUSE integration tests for the write path.
//
// Tests the complete write path (allocate → write → read → verify)
// without requiring a FUSE mount.  Uses shared open_test_image.
#+build linux
package tests

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
