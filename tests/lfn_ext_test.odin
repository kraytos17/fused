// lfn_ext_test.odin — Long filename and path resolution tests.
// Generated from write_test.odin during the Volume refactor.
// Tests: lfn_create_and_read, resolve_path_extended_dir,
// lseek_hole_data, resolve_lfn_actual_resolution.
#+build linux
package tests

import "core:fmt"
import "core:testing"
import "src:fs"

@test
test_lfn_create_and_read :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	rce, rce_err := fs.find_cluster_entry(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(vol.master.root_sector_index))
	testing.expectf(t, rce_err == .None, "root cluster entry")

	long_name := "this_is_a_very_long_filename_exceeding_16_bytes"
	entry := fs.Directory_Entry{
		flags = fs.Dir_Flags{.Allocated, .Exists},
		stored_cluster = vol.master.root_cluster,
		sector_index = rce.sector_start,
	}

	copy(entry.file_name[:], long_name)
	entry.file_name[15] = 0

	testing.expect(t, fs.write_directory_entry_at(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(rce.sector_start), 0, &entry), "write LFN entry")

	dirs, dirs_err := fs.read_directory_entries(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(vol.master.root_sector_index))
	defer delete(dirs)

	testing.expectf(t, dirs_err == .None, "read dir entries")
	testing.expect(t, len(dirs) > 0, "found entries")
}

@test
test_resolve_path_extended_dir :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	rce, rce_err := fs.find_cluster_entry(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(vol.master.root_sector_index))
	testing.expectf(t, rce_err == .None, "root cluster entry")

	for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
		entry := fs.Directory_Entry{
			flags = fs.Dir_Flags{.Allocated, .Exists},
			stored_cluster = vol.master.root_cluster,
		}
		name := fmt.tprintf("file_%02d", i)
		copy(entry.file_name[:], name)
		testing.expect(t, fs.write_directory_entry_at(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(rce.sector_start), i, &entry), fmt.tprintf("write entry %d", i))
	}

	dirs, dirs_err := fs.read_directory_entries(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(vol.master.root_sector_index))
	defer delete(dirs)
	testing.expectf(t, dirs_err == .None, "read dir entries")
	testing.expect(t, len(dirs) == fs.DIR_ENTRIES_PER_SECTOR, "all entries readable")
}

@test
test_lseek_hole_data :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	fc, fo, aerr := fs.allocate_sectors(&vol, 0, 0, 4, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	runs, ext_err := fs.resolve_extents(&vol, fc, fo)
	testing.expectf(t, ext_err == .None, "resolve_extents")
	testing.expect(t, len(runs) >= 1, "at least one extent")

	total_sectors: u64
	for r in runs {total_sectors += u64(r.count)}
	testing.expect(t, total_sectors == 4, "4 sectors total")

	// Write data to sector 0
	buf0: [fs.SECTOR_SIZE]u8
	for j in 0 ..< 4 {buf0[j] = 0xAA}
	testing.expect(t, fs.sector_write(&vol, runs[0].sector, buf0[:]), "write sector 0")

	// Write data to sector 3
	last_run := runs[len(runs)-1]
	last_sec := fs.Sector(u64(last_run.sector) + u64(last_run.count) - 1)
	buf3: [fs.SECTOR_SIZE]u8
	for j in 0 ..< 4 {buf3[j] = 0xBB}
	testing.expect(t, fs.sector_write(&vol, last_sec, buf3[:]), "write last sector")

	// Verify extents are correct
	_, ext_err2 := fs.resolve_extents(&vol, fc, fo)
	testing.expectf(t, ext_err2 == .None, "resolve_extents after writes")
}

@test
test_resolve_lfn_actual_resolution :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	// Allocate one sector for LFN data
	lfn_c, lfn_o, aerr := fs.allocate_sectors(&vol, 0, 0, 1, .LFN)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	defer fs.deallocate_sectors(&vol, lfn_c, lfn_o)

	// Resolve the allocated sector
	lfn_runs, ext_err := fs.resolve_extents(&vol, lfn_c, lfn_o)
	testing.expectf(t, ext_err == .None, "resolve LFN extents")
	testing.expect(t, len(lfn_runs) > 0, "LFN extents not empty")

	// Write the long name to the LFN data sector
	long_name := "this_is_a_very_long_filename_exceeding_16_bytes_abcdefghij"
	sector_buf: [fs.SECTOR_SIZE]u8
	copy(sector_buf[:], long_name)
	testing.expect(t, fs.sector_write(&vol, lfn_runs[0].sector, sector_buf[:]), "write LFN data")

	// Find the ClusterEntry that was allocated for the LFN data
	lfn_entry, find_err := fs.find_cluster_entry(&vol, lfn_c, lfn_o)
	testing.expectf(t, find_err == .None, "find LFN cluster entry")
	testing.expect(t, .Allocated in lfn_entry.state, "LFN entry allocated")

	ptr := fs.LFN_Pointer{
		cluster = u64(lfn_c),
		size    = u32(len(long_name)),
		sector  = lfn_entry.sector_start,
		_pad    = 0,
	}
	entry := fs.Directory_Entry{
		flags          = {.Allocated, .Exists, .LFN},
		sector_index   = lfn_entry.sector_start,
		stored_cluster = u64(lfn_c),
		file_size      = u64(len(long_name)),
	}

	(^fs.LFN_Pointer)(&entry.file_name[0])^ = ptr
	// Write the entry to the root directory at index 1 (index 0 is Kernel)
	rce, rce_err := fs.find_cluster_entry(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(vol.master.root_sector_index))
	testing.expectf(t, rce_err == .None, "root cluster entry")
	testing.expect(t, fs.write_directory_entry_at(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(rce.sector_start), 1, &entry), "write LFN dir entry")

	// Read directory entries back
	dirs, dirs_err := fs.read_directory_entries(&vol, fs.Cluster(vol.master.root_cluster), fs.Sector_Offset(vol.master.root_sector_index))
	defer delete(dirs)

	testing.expectf(t, dirs_err == .None, "read dir entries after LFN write")
	testing.expect(t, len(dirs) >= 2, "at least 2 entries")
	// Find our LFN entry and resolve its name
	resolved := false
	for &d in dirs {
		if .LFN in d.flags {
			name, name_ok := fs.resolve_lfn(&vol, &d)
			testing.expect(t, name_ok, "resolve_lfn ok")
			if name_ok {
				testing.expect(t, name == long_name,
					fmt.tprintf("resolved name %q != expected %q", name, long_name))
				resolved = true
			}
		}
	}
	testing.expect(t, resolved, "LFN entry found and resolved")
}
