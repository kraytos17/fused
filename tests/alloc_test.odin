// alloc_test.odin — Property tests for the sector allocator.
//
// Each test opens a shared /dev/shm copy of fused.img via open_test_image.
#+build linux
package tests

import "core:os"
import "core:testing"
import "src:fs"

@test
test_alloc_fresh :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	fc, fo, err := fs.allocate_sectors(&vol, 0, 0, 10, .File_Content)
	testing.expect_value(t, err, fs.FS_Error.None)

	runs, runs_ok := fs.resolve_extents(&vol, fc, fo)
	testing.expect(t, runs_ok, "resolve_extents")

	total: u64
	for r in runs {total += u64(r.count)}

	testing.expect_value(t, total, u64(10))
	derr := fs.deallocate_sectors(&vol, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)
}

@test
test_alloc_no_overlap :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	Alloc_Run :: struct {c: fs.Cluster, o: fs.Sector_Offset}
	runs: [10]Alloc_Run
	for i in 0 ..< 10 {
		fc, fo, err := fs.allocate_sectors(&vol, 0, 0, 5, .File_Content)
		testing.expect_value(t, err, fs.FS_Error.None)
		runs[i] = {fc, fo}
	}

	bitmap := make([]u8, 2048)
	defer delete(bitmap)
	for c in 0 ..< vol.master.cluster_map_size {
		table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
		if !fs.read_cluster_entry_table(&vol, fs.Cluster(c), &table) {continue}
		for &e in table {
			if .Allocated not_in e.state {continue}
			run_sector := u64(c) * vol.master.cluster_size + u64(e.sector_start)
			for off in 0 ..< e.allocation_size {
				idx := run_sector + u64(off)
				testing.expect(t, bitmap[idx / 8] & (1 << (idx % 8)) == 0, "overlap")
				bitmap[idx / 8] |= 1 << (idx % 8)
			}
		}
	}
	for r in runs {
		derr := fs.deallocate_sectors(&vol, r.c, r.o)
		testing.expect_value(t, derr, fs.FS_Error.None)
	}
}

@test
test_alloc_free_reuse :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	fc, fo, err := fs.allocate_sectors(&vol, 0, 0, 8, .File_Content)
	testing.expect_value(t, err, fs.FS_Error.None)

	derr := fs.deallocate_sectors(&vol, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)
	vol.cache.hint = 0 // reset hint so alloc reuses the same cluster
	fc2, fo2, err2 := fs.allocate_sectors(&vol, 0, 0, 8, .File_Content)
	testing.expect_value(t, err2, fs.FS_Error.None)

	runs_after, _ := fs.resolve_extents(&vol, fc2, fo2)
	tt: u64
	for r in runs_after {tt += u64(r.count)}
	testing.expect_value(t, tt, u64(8))
	derr2 := fs.deallocate_sectors(&vol, fc2, fo2)
	testing.expect_value(t, derr2, fs.FS_Error.None)
}

@test
test_alloc_free_loop :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	for _ in 0 ..< 50 {
		fc, fo, err := fs.allocate_sectors(&vol, 0, 0, 1, .File_Content)
		testing.expect_value(t, err, fs.FS_Error.None)
		runs, _ := fs.resolve_extents(&vol, fc, fo)
		tt: u64; for r in runs {tt += u64(r.count)}
		testing.expect_value(t, tt, u64(1))
		derr := fs.deallocate_sectors(&vol, fc, fo)
		testing.expect_value(t, derr, fs.FS_Error.None)
	}
}

@test
test_full_flag :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	fc, fo, err := fs.allocate_sectors(&vol, 0, 0, vol.master.cluster_size, .File_Content)
	testing.expect_value(t, err, fs.FS_Error.None)

	cme, _ := fs.read_cluster_map_entry(&vol, fc)
	testing.expect(t, .Full in cme.flags, "FULL flag set")

	derr := fs.deallocate_sectors(&vol, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)
	cme2, _ := fs.read_cluster_map_entry(&vol, fc)
	testing.expect(t, .Full not_in cme2.flags, "FULL flag cleared")
}

@test
test_chain_consistency :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	fc, fo, err := fs.allocate_sectors(&vol, 0, 0, vol.master.cluster_size + 4, .File_Content)
	testing.expect_value(t, err, fs.FS_Error.None)

	_, runs_ok := fs.resolve_extents(&vol, fc, fo)
	testing.expect(t, runs_ok, "resolve_extents")

	tt: u64
	current_c := fc
	current_o := fo
	for {
		entry, entry_ok := fs.find_cluster_entry(&vol, current_c, current_o)
		testing.expect(t, entry_ok, "chain link dead")
		tt += u64(entry.allocation_size)
		if entry.next_cluster == 0 {break}

		current_c = fs.Cluster(entry.next_cluster)
		current_o = fs.Sector_Offset(entry.next_sector_index)
	}

	testing.expect_value(t, tt, vol.master.cluster_size + 4)
	derr := fs.deallocate_sectors(&vol, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)
}

@test
test_extension :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	fc, fo, err := fs.allocate_sectors(&vol, 0, 0, 5, .File_Content)
	testing.expect_value(t, err, fs.FS_Error.None)
	fc2, fo2, ext_err := fs.allocate_sectors(&vol, fc, fo, 10, .File_Content)
	testing.expect_value(t, ext_err, fs.FS_Error.None)
	testing.expect_value(t, fc, fc2)
	testing.expect_value(t, fo, fo2)

	runs, _ := fs.resolve_extents(&vol, fc, fo)
	tt: u64
	for r in runs {tt += u64(r.count)}

	testing.expect_value(t, tt, u64(10))
	derr := fs.deallocate_sectors(&vol, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)
}

@test
test_alloc_cache_stress :: proc(t: ^testing.T) {
	fd, open_err := os.open("fused.img", {.Read, .Write})
	if open_err != nil {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	vol := fs.Volume{disk = fd, master = master}
	fs.alloc_cache_init(&vol.cache, &vol.master)
	defer fs.alloc_cache_destroy(&vol.cache)

	baseline_used: u16 = 0
	{
		_, used, ok := fs.alloc_cache_ensure(&vol.cache, &vol, 1)
		if ok {baseline_used = used}
	}

	ITERATIONS :: 100
	for i in 0 ..< ITERATIONS {
		fc, fo, aerr := fs.allocate_sectors(&vol, 0, 0, 1, .File_Content)
		testing.expectf(t, aerr == .None, "alloc iteration %d: %v", i, aerr)
		if aerr != .None {return}

		runs, rok := fs.resolve_extents(&vol, fc, fo)
		testing.expectf(t, rok, "resolve extents iteration %d", i)
		if !rok {return}
		tt: u64; for r in runs {tt += u64(r.count)}
		testing.expectf(t, tt == 1, "iteration %d: expected 1 sector, got %d", i, tt)

		derr := fs.deallocate_sectors(&vol, fc, fo)
		testing.expectf(t, derr == .None, "dealloc iteration %d: %v", i, derr)
		if derr != .None {return}

		_, rok2 := fs.resolve_extents(&vol, fc, fo)
		testing.expectf(t, !rok2, "iteration %d: extents should be empty after dealloc", i)
	}
}
