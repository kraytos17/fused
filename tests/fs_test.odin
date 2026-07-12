// fs_test.odin — Unit tests for the fused filesystem core.
//
// Opens a fused.img produced by the disker, validates the master record,
// navigates to the root directory, finds the demo "Kernel" file, reads
// its data, and asserts it matches the expected content byte-for-byte.
#+build linux
package tests

import "core:os"
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
	fd, open_err := os.open("fused.img", {.Read})
	if open_err != nil {
		testing.fail(t)
		return
	}
	defer os.close(fd)

	master, ok := fs.read_master_record(fd)
	testing.expect(t, ok, "read_master_record")

	fi, fi_err := os.stat("fused.img", context.temp_allocator)
	img_size: u64 = 0
	if fi_err == nil { img_size = u64(fi.size) }

	err := fs.validate_master(&master, img_size)
	testing.expect_value(t, err, fs.FS_Error.None)
	testing.expect_value(t, master.sig, fs.FUSED_SIG)
	testing.expect_value(t, master.rev, u8(4))

	root_cluster := fs.Cluster(master.root_cluster)
	root_offset  := fs.Sector_Offset(master.root_sector_index)

	cme, ok_cme := fs.read_cluster_map_entry(fd, &master, root_cluster)
	testing.expect(t, ok_cme, "cluster map entry")
	testing.expect(t, .Allocated in cme.flags, "root cluster allocated")

	rd_ce, ok_rd := fs.find_cluster_entry(fd, &master, root_cluster, root_offset)
	testing.expect(t, ok_rd, "root dir ClusterEntry")
	testing.expect(t, .Directory in rd_ce.state, "root dir is directory")

	dirs, ok_dir := fs.read_directory_entries(fd, &master, root_cluster, fs.Sector_Offset(rd_ce.sector_start))
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
	runs, ok_runs := fs.resolve_extents(fd, &master, kernel_cluster, kernel_offset)

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

		testing.expect(t, fs.sector_read(fd, run.sector, sector_buf[:n]), "sector_read")
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
