// fs_test.odin — Unit tests for the fused filesystem core.
#+build linux
package tests

import "core:os"
import "core:strings"
import "core:testing"
import "src:fs"

EXPECTED_DEMO := [?]u8{
	0x82, 0x00, 0x0d, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x81,
	0x00, 0x06, 0x4b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x82, 0x03,
	0x06, 0x06, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x81, 0x00,
	0x05, 0x4b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x82, 0x03, 0x05,
	0x06, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc8, 0x00, 0x5b,
}

@test
test_fs_core :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	testing.expect_value(t, vol.master.sig, fs.FUSED_SIG)
	testing.expect_value(t, vol.master.rev_max, u8(7))

	root_cluster := fs.Cluster(vol.master.root_cluster)
	root_offset  := fs.Sector_Offset(vol.master.root_sector_index)

	cme, ok_cme := fs.read_cluster_map_entry(&vol, root_cluster)
	testing.expect(t, ok_cme, "cluster map entry")
	testing.expect(t, .Allocated in cme.flags, "root cluster allocated")

	rd_ce, ok_rd := fs.find_cluster_entry(&vol, root_cluster, root_offset)
	testing.expect(t, ok_rd, "root dir ClusterEntry")
	testing.expect(t, .Directory in rd_ce.state, "root dir is directory")

	dirs, ok_dir := fs.read_directory_entries(&vol, root_cluster, fs.Sector_Offset(rd_ce.sector_start))
	defer delete(dirs)

	testing.expect(t, ok_dir, "read_directory_entries")
	testing.expect(t, len(dirs) >= 1, "at least one entry")

	kernel: fs.Directory_Entry
	found := false
	for &d in dirs {
		if fs.entry_short_name(&d) == "Kernel" {
			kernel = d
			found = true
			break
		}
	}

	testing.expect(t, found, "Kernel entry")
	kernel_cluster := fs.Cluster(kernel.stored_cluster)
	kernel_offset  := fs.Sector_Offset(kernel.sector_index)
	runs, ok_runs := fs.resolve_extents(&vol, kernel_cluster, kernel_offset)

	testing.expect(t, ok_runs, "resolve_extents")
	testing.expect(t, len(runs) > 0, "extents not empty")

	total := u64(kernel.file_size)
	data := make([]u8, int(total))
	defer delete(data)

	cursor := 0
	sector_buf := make([]u8, fs.SECTOR_SIZE)
	defer delete(sector_buf)
	for run in runs {
		n := min(int(run.count) * fs.SECTOR_SIZE, int(total) - cursor)
		if n <= 0 {break}

		testing.expect(t, fs.sector_read(&vol, run.sector, sector_buf[:n]), "sector_read")
		copy(data[cursor:], sector_buf[:n])
		cursor += n
	}

	testing.expect_value(t, cursor, len(EXPECTED_DEMO))
	if cursor == len(EXPECTED_DEMO) {
		for i in 0 ..< len(EXPECTED_DEMO) {
			if data[i] != EXPECTED_DEMO[i] {
				testing.expect(t, false, "content mismatch")
				break
			}
		}
	}
}

@test
test_validate_master_error_paths :: proc(t: ^testing.T) {
	m := fs.Master_Record {
		sig                = fs.FUSED_SIG,
		rev_min            = 7,
		rev_max            = 7,
		features           = fs.Features{.Uid_Gid, .Journal_V2},
		cluster_map_offset = 1,
		cluster_map_size   = 128,
		cluster_size       = 16,
		root_sector_index  = 1,
		root_cluster       = 1,
		reserved3          = 0,
		reserved4          = 0,
		resv               = {},
		end_sig            = 0x0BB0,
	}

	img_size: fs.Byte_Offset = 1 * 1024 * 1024
	m2 := m; m2.sig = [7]u8{'X', 'X', 'X', 'X', 'X', 0, 0}
	testing.expect_value(t, fs.validate_master(&m2, img_size), fs.FS_Error.Invalid_Signature)

	m2 = m; m2.rev_max = 3
	testing.expect_value(t, fs.validate_master(&m2, img_size), fs.FS_Error.Version_Too_Old)

	m2 = m; m2.rev_min = 8
	testing.expect_value(t, fs.validate_master(&m2, img_size), fs.FS_Error.Version_Too_New)

	m2 = m; m2.end_sig = 0x0000
	testing.expect_value(t, fs.validate_master(&m2, img_size), fs.FS_Error.Invalid_Signature)

	m2 = m; m2.cluster_size = 0
	testing.expect_value(t, fs.validate_master(&m2, img_size), fs.FS_Error.Corrupt_Master_Record)

	m2 = m; m2.cluster_map_offset = 0
	testing.expect_value(t, fs.validate_master(&m2, img_size), fs.FS_Error.Corrupt_Master_Record)

	m2 = m; m2.cluster_map_size = 9999
	testing.expect_value(t, fs.validate_master(&m2, img_size), fs.FS_Error.Corrupt_Master_Record)
}

@test
test_display_flag_str_functions :: proc(t: ^testing.T) {
	buf: [128]u8
	s1 := fs.cme_flags_str({.Allocated, .Reserved}, buf[:])
	testing.expect(t, strings.contains(s1, "ALLOCATED"), "cme ALLOCATED")
	testing.expect(t, strings.contains(s1, "RESERVED"), "cme RESERVED")

	s2 := fs.cme_flags_str({}, buf[:])
	testing.expect_value(t, s2, "0")

	s3 := fs.ce_state_str({.Allocated, .File_Content}, buf[:])
	testing.expect(t, strings.contains(s3, "ALLOCATED"), "ce ALLOCATED")
	testing.expect(t, strings.contains(s3, "FILE_CONTENT"), "ce FILE_CONTENT")

	s4 := fs.ce_state_str({}, buf[:])
	testing.expect_value(t, s4, "0")

	s5 := fs.dir_flags_str({.Allocated, .Directory, .Exists}, buf[:])
	testing.expect(t, strings.contains(s5, "ALLOCATED"), "dir ALLOCATED")
	testing.expect(t, strings.contains(s5, "DIRECTORY"), "dir DIRECTORY")
	testing.expect(t, strings.contains(s5, "EXISTS"), "dir EXISTS")

	s6 := fs.dir_flags_str({}, buf[:])
	testing.expect_value(t, s6, "0")
}

@test
test_sector_read_write_bulk :: proc(t: ^testing.T) {
	fd, open_err := os.open("fused.img", {.Read, .Write})
	if open_err != nil {testing.fail(t); return}
	defer os.close(fd)

	master, ok := fs.read_master_record(fd)
	testing.expect(t, ok, "read_master_record")

	vol := fs.Volume{disk = fd, master = master}
	fs.alloc_cache_init(&vol.cache, &vol.master)
	defer fs.alloc_cache_destroy(&vol.cache)

	kernel_ce, ce_ok := fs.find_cluster_entry(&vol, fs.Cluster(master.root_cluster), fs.Sector_Offset(2))
	testing.expect(t, ce_ok, "find_cluster_entry for Kernel")
	abs_sector := fs.Sector(u64(master.root_cluster) * master.cluster_size + u64(kernel_ce.sector_start))

	orig := make([]u8, fs.SECTOR_SIZE)
	defer delete(orig)
	n, read_ok := fs.sector_read_bulk(&vol, abs_sector, orig)
	testing.expect(t, read_ok, "sector_read_bulk")
	testing.expect_value(t, n, fs.SECTOR_SIZE)

	modified := make([]u8, fs.SECTOR_SIZE)
	defer delete(modified)
	for i in 0 ..< fs.SECTOR_SIZE {
		modified[i] = u8(i * 7)
	}

	write_ok := fs.sector_write_bulk(&vol, abs_sector, modified)
	testing.expect(t, write_ok, "sector_write_bulk")

	readback := make([]u8, fs.SECTOR_SIZE)
	defer delete(readback)

	n, read_ok = fs.sector_read_bulk(&vol, abs_sector, readback)
	testing.expect(t, read_ok, "sector_read_bulk verify")
	testing.expect_value(t, n, fs.SECTOR_SIZE)
	for i in 0 ..< fs.SECTOR_SIZE {
		if readback[i] != modified[i] {
			testing.expect(t, false, "bulk content mismatch")
			fs.sector_write_bulk(&vol, abs_sector, orig)
			return
		}
	}
	fs.sector_write_bulk(&vol, abs_sector, orig)
}

@test
test_deallocate_sectors_edge_cases :: proc(t: ^testing.T) {
	fd, open_err := os.open("fused.img", {.Read, .Write})
	if open_err != nil {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	vol := fs.Volume{disk = fd, master = master}
	fs.alloc_cache_init(&vol.cache, &vol.master)
	defer fs.alloc_cache_destroy(&vol.cache)

	err := fs.deallocate_sectors(&vol, 0, 0)
	testing.expect_value(t, err, fs.FS_Error.None)

	c, o, aerr := fs.allocate_sectors(&vol, 0, 0, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	err = fs.deallocate_sectors(&vol, c, o)
	testing.expect_value(t, err, fs.FS_Error.None)

	_, found := fs.find_cluster_entry(&vol, c, o)
	testing.expect(t, !found, "CE should be gone after dealloc")

	rce, rce_ok := fs.find_cluster_entry(&vol, fs.Cluster(master.root_cluster), fs.Sector_Offset(master.root_sector_index))
	testing.expect(t, rce_ok, "root cluster entry")
	testing.expect(t, fs.write_cluster_entry_at(&vol, fs.Cluster(master.root_cluster), 0, &rce), "write_cluster_entry_at")

	read_rce, read_ok := fs.find_cluster_entry(&vol, fs.Cluster(master.root_cluster), fs.Sector_Offset(master.root_sector_index))
	testing.expect(t, read_ok, "read back CE after write_cluster_entry_at")
	testing.expect_value(t, read_rce.sector_start, rce.sector_start)
	testing.expect_value(t, read_rce.allocation_size, rce.allocation_size)
}
