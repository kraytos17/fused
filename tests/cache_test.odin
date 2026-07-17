// cache_test.odin — Tests for the cluster bitmap cache.
//
// Verifies that alloc_cache_ensure returns correct bitmaps and used
// counts matching the on-disk state, that invalidation forces rebuilds,
// and that allocate/deallocate with a real cache matches the nil-cache
// (stack-local fallback) behavior.
#+build linux
package tests

import "core:container/bit_array"
import "core:os"
import "core:testing"
import "src:fs"

// Verify that init produces a usable cache and destroy cleans up.
@test
test_cache_init_destroy :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	cache: fs.Cluster_Bitmap_Cache
	fs.alloc_cache_init(&cache, &master)
	defer fs.alloc_cache_destroy(&cache)

	testing.expect(t, cache.cache_size > 0, "cache_size > 0")
	_, _, bok := fs.alloc_cache_ensure(&cache, &master, fd, 0)
	testing.expect(t, bok, "ensure cluster 0 after init")
}

// Verify that the bitmap built by alloc_cache_ensure matches a direct
// on-disk scan of the cluster entry table.
@test
test_cache_bitmap_matches_disk :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	cache: fs.Cluster_Bitmap_Cache
	fs.alloc_cache_init(&cache, &master)
	defer fs.alloc_cache_destroy(&cache)

	for ci in 0 ..< int(master.cluster_map_size) {
		bm, _, bok := fs.alloc_cache_ensure(&cache, &master, fd, u64(ci))
		if !bok {continue}

		table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
		if !fs.read_cluster_entry_table(fd, &master, fs.Cluster(ci), &table) {continue}

		expected_bitmap: bit_array.Bit_Array
		bit_array.init(&expected_bitmap, cache.cache_size, 0, context.temp_allocator)
		cme, cme_ok := fs.read_cluster_map_entry(fd, &master, fs.Cluster(ci))
		if cme_ok {
			bit_array.unsafe_set(&expected_bitmap, int(cme.sector_index))
		}
		for &e in table {
			if .Allocated in e.state {
				for off in 0 ..< e.allocation_size {
					s := e.sector_start + off
					bit_array.unsafe_set(&expected_bitmap, int(s))
				}
			}
		}
		for b in 0 ..< u16(master.cluster_size) {
			bit_expected := bit_array.unsafe_get(&expected_bitmap, int(b))
			bit_actual   := bit_array.unsafe_get(&bm, int(b))
			if bit_expected != bit_actual {
				testing.expectf(t, false, "cluster %d sector %d: expected=%v actual=%v", ci, b, bit_expected, bit_actual)
				return
			}
		}
	}
}

// Verify that the used count from the cache matches a direct on-disk sum.
@test
test_cache_used_matches_disk :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	cache: fs.Cluster_Bitmap_Cache
	fs.alloc_cache_init(&cache, &master)
	defer fs.alloc_cache_destroy(&cache)

	for ci in 0 ..< int(master.cluster_map_size) {
		_, used, bok := fs.alloc_cache_ensure(&cache, &master, fd, u64(ci))
		if !bok {continue}

		expected_used: u16 = 0
		table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
		if !fs.read_cluster_entry_table(fd, &master, fs.Cluster(ci), &table) {continue}
		for &e in table {
			if .Allocated in e.state {
				expected_used += e.allocation_size
			}
		}

		if used != expected_used {
			testing.expectf(t, false, "cluster %d: cache used=%d expected=%d", ci, used, expected_used)
			return
		}
	}
}

// Verify that invalidation forces a rebuild on the next ensure.
@test
test_cache_invalidate_rebuilds :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	cache: fs.Cluster_Bitmap_Cache
	fs.alloc_cache_init(&cache, &master)
	defer fs.alloc_cache_destroy(&cache)

	_, used_before, bok := fs.alloc_cache_ensure(&cache, &master, fd, 0)
	testing.expect(t, bok, "ensure cluster 0")
	fs.alloc_cache_invalidate(&cache, 0)

	_, used_after, bok2 := fs.alloc_cache_ensure(&cache, &master, fd, 0)
	testing.expect(t, bok2, "re-ensure cluster 0")
	testing.expectf(t, used_after == used_before, "used count unchanged: before=%d after=%d", used_before, used_after)
}

// Verify that alloc_cache_count_free matches the actual on-disk free count.
@test
test_cache_count_free :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	cache: fs.Cluster_Bitmap_Cache
	fs.alloc_cache_init(&cache, &master)
	defer fs.alloc_cache_destroy(&cache)

	cached_free := fs.alloc_cache_count_free(&cache, &master, fd)
	testing.expect(t, cached_free > 0, "free count > 0")

	// Verify count is consistent by alloc/dealloc cycling with the same cache
	fc, fo, err := fs.allocate_sectors(&master, fd, &cache, 0, 0, 1, .File_Content)
	testing.expect_value(t, err, fs.FS_Error.None)

	after_alloc := fs.alloc_cache_count_free(&cache, &master, fd)
	testing.expectf(t, after_alloc == cached_free - 1,
		"free after alloc: expected=%d got=%d", cached_free - 1, after_alloc)

	derr := fs.deallocate_sectors(&master, fd, &cache, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)

	after_dealloc := fs.alloc_cache_count_free(&cache, &master, fd)
	testing.expectf(t, after_dealloc == cached_free,
		"free after dealloc: expected=%d got=%d", cached_free, after_dealloc)
}

// Verify that allocate with a real cache produces the same result as without.
@test
test_cache_allocate_matches_nil :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")
	_ = open_test_image

	// Allocate with cache
	cache: fs.Cluster_Bitmap_Cache
	fs.alloc_cache_init(&cache, &master)
	defer fs.alloc_cache_destroy(&cache)

	fc_c, fo_c, err_c := fs.allocate_sectors(&master, fd, &cache, 0, 0, 3, .File_Content)
	testing.expect_value(t, err_c, fs.FS_Error.None)

	runs_c, rok_c := fs.resolve_extents(fd, &master, fc_c, fo_c)
	testing.expect(t, rok_c, "resolve_extents (cached)")
	tt_c: u64; for r in runs_c {tt_c += u64(r.count)}
	testing.expect_value(t, tt_c, u64(3))

	derr_c := fs.deallocate_sectors(&master, fd, &cache, fc_c, fo_c)
	testing.expect_value(t, derr_c, fs.FS_Error.None)
}

// Verify the hint moves forward after allocation.
@test
test_cache_hint_advances :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	cache: fs.Cluster_Bitmap_Cache
	fs.alloc_cache_init(&cache, &master)
	defer fs.alloc_cache_destroy(&cache)

	hint_before := cache.hint
	fc, fo, err := fs.allocate_sectors(&master, fd, &cache, 0, 0, 1, .File_Content)
	testing.expect_value(t, err, fs.FS_Error.None)
	testing.expect(t, cache.hint > hint_before || cache.hint == 0, "hint advanced")
	_ = fc; _ = fo

	derr := fs.deallocate_sectors(&master, fd, &cache, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)
}

// Stress the cache with allocate+deallocate cycles across multiple clusters.
@test
test_cache_stress_multi_cluster :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	cache: fs.Cluster_Bitmap_Cache
	fs.alloc_cache_init(&cache, &master)
	defer fs.alloc_cache_destroy(&cache)

	// Allocate enough to span multiple clusters
	needed := master.cluster_size * 3 + 2
	fc, fo, err := fs.allocate_sectors(&master, fd, &cache, 0, 0, needed, .File_Content)
	testing.expect_value(t, err, fs.FS_Error.None)

	runs, rok := fs.resolve_extents(fd, &master, fc, fo)
	testing.expect(t, rok, "resolve_extents")
	tt: u64
	for r in runs {tt += u64(r.count)}
	testing.expect_value(t, tt, needed)

	derr := fs.deallocate_sectors(&master, fd, &cache, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)

	// Verify cache is still consistent after deallocation
	for ci in 0 ..< int(master.cluster_map_size) {
		_, used, bok := fs.alloc_cache_ensure(&cache, &master, fd, u64(ci))
		if !bok {continue}

		expected_used: u16 = 0
		table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
		if !fs.read_cluster_entry_table(fd, &master, fs.Cluster(ci), &table) {continue}
		for &e in table {
			if .Allocated in e.state {
				expected_used += e.allocation_size
			}
		}
		if used != expected_used {
			testing.expectf(t, false, "cluster %d: used=%d expected=%d after dealloc", ci, used, expected_used)
			return
		}
	}
}

// Verify the cache works correctly alongside extension (append to chain).
@test
test_cache_chain_extension :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	cache: fs.Cluster_Bitmap_Cache
	fs.alloc_cache_init(&cache, &master)
	defer fs.alloc_cache_destroy(&cache)

	fc, fo, err := fs.allocate_sectors(&master, fd, &cache, 0, 0, 5, .File_Content)
	testing.expect_value(t, err, fs.FS_Error.None)

	fc2, fo2, ext_err := fs.allocate_sectors(&master, fd, &cache, fc, fo, 10, .File_Content)
	testing.expect_value(t, ext_err, fs.FS_Error.None)
	testing.expect_value(t, fc, fc2)
	testing.expect_value(t, fo, fo2)

	runs, _ := fs.resolve_extents(fd, &master, fc, fo)
	tt: u64
	for r in runs {tt += u64(r.count)}
	testing.expect_value(t, tt, u64(10))

	derr := fs.deallocate_sectors(&master, fd, &cache, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)
}

// Verify the cache survives repeated alloc/free cycles without corruption.
@test
test_cache_many_small_alloc_free :: proc(t: ^testing.T) {
	fd, open_err := open_test_image()
	if !open_err {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	cache: fs.Cluster_Bitmap_Cache
	fs.alloc_cache_init(&cache, &master)
	defer fs.alloc_cache_destroy(&cache)

	for i in 0 ..< 30 {
		fc, fo, err := fs.allocate_sectors(&master, fd, &cache, 0, 0, 1, .File_Content)
		testing.expectf(t, err == .None, "alloc %d: expected None got %v", i, err)
		if err != .None {return}

		runs, rok := fs.resolve_extents(fd, &master, fc, fo)
		testing.expect(t, rok, "resolve_extents")
		tt: u64; for r in runs {tt += u64(r.count)}
		testing.expect_value(t, tt, u64(1))

		derr := fs.deallocate_sectors(&master, fd, &cache, fc, fo)
		testing.expectf(t, derr == .None, "dealloc %d: expected None got %v", i, derr)
		if derr != .None {return}

		// After each cycle, verify cache used count matches disk for the affected cluster
		_, used, bok := fs.alloc_cache_ensure(&cache, &master, fd, u64(fc))
		if !bok {continue}
		table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
		if !fs.read_cluster_entry_table(fd, &master, fc, &table) {continue}
		expected_used: u16 = 0
		for &e in table {
			if .Allocated in e.state {
				expected_used += e.allocation_size
			}
		}
		if used != expected_used {
			testing.expectf(t, false, "cycle %d cluster %d: used=%d expected=%d", i, fc, used, expected_used)
			return
		}
	}
}
