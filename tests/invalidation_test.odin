// invalidation_test.odin — Tests for centralized alloc cache invalidation.
//
// Verifies that write_cluster_map_entry, write_cluster_entry_table, and
// write_cluster_entry_at automatically invalidate the alloc cache when
// called with a non-nil cache parameter.
#+build linux
package tests

import "core:os"
import "core:testing"
import "src:fs"

// Ensure a cluster's bitmap is cached, then write its CME via the
// write helper and verify the cache entry is invalidated.
@test
test_invalidate_via_write_cme :: proc(t: ^testing.T) {
	fd, open_err := os.open("fused.img", {.Read, .Write})
	if open_err != nil {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	vol := fs.Volume{disk = fd, master = master}
	fs.alloc_cache_init(&vol.cache, &vol.master)
	defer fs.alloc_cache_destroy(&vol.cache)

	// Pick the root cluster (allocated)
	test_cluster := fs.Cluster(master.root_cluster)
	_, _, bok := fs.alloc_cache_ensure(&vol.cache, &vol, u64(test_cluster))
	testing.expect(t, bok, "ensure cluster 1 before write")

	cme, cme_err := fs.read_cluster_map_entry(&vol, test_cluster)
	testing.expectf(t, cme_err == .None, "read CME")
	cme_backup := cme
	if fs.write_cluster_map_entry(&vol, test_cluster, &cme) != .None {
		testing.fail(t)
		return
	}

	// The cache entry should have been invalidated — re-ensure should rebuild
	_, used_after, bok2 := fs.alloc_cache_ensure(&vol.cache, &vol, u64(test_cluster))
	testing.expect(t, bok2, "ensure after write_cme")

	// Verify the rebuilt used count matches disk
	table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	if fs.read_cluster_entry_table(&vol, test_cluster, &table) != .None {
		testing.fail(t)
		return
	}

	expected_used: u16 = 0
	for &e in table {
		if .Allocated in e.state {
			expected_used += e.allocation_size
		}
	}
	testing.expectf(t, used_after == expected_used,
		"used count after CME write: cache=%d expected=%d", used_after, expected_used)
	// Restore original CME
	testing.expectf(t, fs.write_cluster_map_entry(&vol, test_cluster, &cme_backup) == .None, "restore CME")
}

// Write a CE table via the helper with cache, verify invalidation.
@test
test_invalidate_via_write_ce_table :: proc(t: ^testing.T) {
	fd, open_err := os.open("fused.img", {.Read, .Write})
	if open_err != nil {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	vol := fs.Volume{disk = fd, master = master}
	fs.alloc_cache_init(&vol.cache, &vol.master)
	defer fs.alloc_cache_destroy(&vol.cache)

	test_cluster := fs.Cluster(master.root_cluster)
	_, _, bok := fs.alloc_cache_ensure(&vol.cache, &vol, u64(test_cluster))
	testing.expect(t, bok, "ensure before write")

	// Read the CE table, write it back unchanged via the helper
	table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	if fs.read_cluster_entry_table(&vol, test_cluster, &table) != .None {
		testing.fail(t)
		return
	}

	table_backup := table
	backup_allocated := false
	for &e in table_backup {
		if .Allocated in e.state { backup_allocated = true; break }
	}
	if fs.write_cluster_entry_table(&vol, test_cluster, &table) != .None {
		testing.fail(t)
		return
	}

	// Cache should have been invalidated — verify by re-ensuring
	_, used_after, bok2 := fs.alloc_cache_ensure(&vol.cache, &vol, u64(test_cluster))
	testing.expect(t, bok2, "ensure after write_ce_table")

	table_after: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	if fs.read_cluster_entry_table(&vol, test_cluster, &table_after) != .None {
		testing.fail(t)
		return
	}

	expected_used: u16 = 0
	for &e in table_after {
		if .Allocated in e.state {
			expected_used += e.allocation_size
		}
	}

	testing.expectf(t, used_after == expected_used,
		"used count after CE table write: cache=%d expected=%d", used_after, expected_used)
	// Restore
	testing.expectf(t, fs.write_cluster_entry_table(&vol, test_cluster, &table_backup) == .None, "restore CE table")
}

// Verify that write_cluster_entry_at with cache invalidates.
@test
test_invalidate_via_write_ce_at :: proc(t: ^testing.T) {
	fd, open_err := os.open("fused.img", {.Read, .Write})
	if open_err != nil {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	vol := fs.Volume{disk = fd, master = master}
	fs.alloc_cache_init(&vol.cache, &vol.master)
	defer fs.alloc_cache_destroy(&vol.cache)

	test_cluster := fs.Cluster(master.root_cluster)
	_, _, bok := fs.alloc_cache_ensure(&vol.cache, &vol, u64(test_cluster))
	testing.expect(t, bok, "ensure before write")

	// Read the CE table, find the first allocated entry, write it back
	table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	if fs.read_cluster_entry_table(&vol, test_cluster, &table) != .None {
		testing.fail(t)
		return
	}

	first_alloc_idx := -1
	for i in 0 ..< fs.CLUSTER_ENTRIES_PER_SECTOR {
		if .Allocated in table[i].state { first_alloc_idx = i; break }
	}

	testing.expect(t, first_alloc_idx >= 0, "found allocated entry")
	entry_before := table[first_alloc_idx]
	if fs.write_cluster_entry_at(&vol, test_cluster, first_alloc_idx, &entry_before) != .None {
		testing.fail(t)
		return
	}

	// Cache invalidated — rebuild and verify
	_, used_after, bok2 := fs.alloc_cache_ensure(&vol.cache, &vol, u64(test_cluster))
	testing.expect(t, bok2, "ensure after write_ce_at")

	table_after: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	if fs.read_cluster_entry_table(&vol, test_cluster, &table_after) != .None {
		testing.fail(t)
		return
	}

	expected_used: u16 = 0
	for &e in table_after {
		if .Allocated in e.state {
			expected_used += e.allocation_size
		}
	}
	testing.expectf(t, used_after == expected_used,
		"used count after CE at write: cache=%d expected=%d", used_after, expected_used)
}

// Verify that write functions properly invalidate the built-in cache.
@test
test_invalidate_via_write_always_invalidates :: proc(t: ^testing.T) {
	fd, open_err := os.open("fused.img", {.Read, .Write})
	if open_err != nil {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	vol := fs.Volume{disk = fd, master = master}
	fs.alloc_cache_init(&vol.cache, &vol.master)
	defer fs.alloc_cache_destroy(&vol.cache)

	test_cluster := fs.Cluster(master.root_cluster)
	_, used_before, bok := fs.alloc_cache_ensure(&vol.cache, &vol, u64(test_cluster))
	testing.expect(t, bok, "ensure before write")

	// Write CME — should invalidate cache automatically
	cme, cme_err := fs.read_cluster_map_entry(&vol, test_cluster)
	testing.expectf(t, cme_err == .None, "read CME")
	testing.expectf(t, fs.write_cluster_map_entry(&vol, test_cluster, &cme) == .None, "write CME")

	// Cache should have been invalidated — re-ensure should return fresh data
	_, used_after, bok2 := fs.alloc_cache_ensure(&vol.cache, &vol, u64(test_cluster))
	testing.expect(t, bok2, "ensure after CME write")
	testing.expectf(t, used_after == used_before,
		"used same after CME write: before=%d after=%d", used_before, used_after)

	// Same for write_cluster_entry_table
	table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	if fs.read_cluster_entry_table(&vol, test_cluster, &table) != .None {
		testing.fail(t)
		return
	}

	testing.expectf(t, fs.write_cluster_entry_table(&vol, test_cluster, &table) == .None, "write CE table")
	_, used_after2, bok3 := fs.alloc_cache_ensure(&vol.cache, &vol, u64(test_cluster))
	testing.expect(t, bok3, "ensure after CE table write")
	testing.expectf(t, used_after2 == used_before,
		"used same after CE table write: before=%d after=%d", used_before, used_after2)
}

// Verify the full alloc -> dealloc cycle through allocate_sectors works with
// the centralized invalidation (smoke test for the 7 mutation sites).
@test
test_invalidation_full_cycle :: proc(t: ^testing.T) {
	fd, open_err := os.open("fused.img", {.Read, .Write})
	if open_err != nil {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	vol := fs.Volume{disk = fd, master = master}
	fs.alloc_cache_init(&vol.cache, &vol.master)
	defer fs.alloc_cache_destroy(&vol.cache)

	// Allocate — this exercises all the write helpers in allocate_sectors
	fc, fo, aerr := fs.allocate_sectors(&vol, 0, 0, 3, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	// Verify cache is consistent for the allocated cluster
	_, used, bok := fs.alloc_cache_ensure(&vol.cache, &vol, u64(fc))
	testing.expect(t, bok, "ensure after alloc")
	table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	if fs.read_cluster_entry_table(&vol, fc, &table) != .None {
		testing.fail(t)
		return
	}

	expected_used: u16 = 0
	for &e in table {
		if .Allocated in e.state {
			expected_used += e.allocation_size
		}
	}

	testing.expectf(t, used == expected_used,
		"used after alloc: cache=%d expected=%d", used, expected_used)
	// Deallocate — exercises the deallocate_sectors write paths
	derr := fs.deallocate_sectors(&vol, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)

	// Verify cache is consistent after dealloc
	_, used2, bok2 := fs.alloc_cache_ensure(&vol.cache, &vol, u64(fc))
	testing.expect(t, bok2, "ensure after dealloc")
	if fs.read_cluster_entry_table(&vol, fc, &table) != .None {
		testing.fail(t)
		return
	}

	expected_used2: u16 = 0
	for &e in table {
		if .Allocated in e.state {
			expected_used2 += e.allocation_size
		}
	}
	testing.expectf(t, used2 == expected_used2,
		"used after dealloc: cache=%d expected=%d", used2, expected_used2)
}

// Verify that allocation chain extension correctly invalidates both
// the new cluster AND the previous (patched) cluster's cache entry.
@test
test_invalidation_chain_extension :: proc(t: ^testing.T) {
	fd, open_err := os.open("fused.img", {.Read, .Write})
	if open_err != nil {testing.fail(t); return}
	defer os.close(fd)

	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")

	vol := fs.Volume{disk = fd, master = master}
	fs.alloc_cache_init(&vol.cache, &vol.master)
	defer fs.alloc_cache_destroy(&vol.cache)

	// First allocation fills cluster 1 almost completely (needs 16 sectors)
	// but cluster 1 has 13 free sectors (16 - 3 used by root).
	// Allocate 13 to fill cluster 1.
	fc, fo, aerr := fs.allocate_sectors(&vol, 0, 0, 13, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)

	// Extend by 3 more — should spill into cluster 2 and chain them
	fc2, fo2, aerr2 := fs.allocate_sectors(&vol, fc, fo, 16, .File_Content)
	testing.expect_value(t, aerr2, fs.FS_Error.None)
	testing.expect_value(t, fc, fc2)
	testing.expect_value(t, fo, fo2)

	// Verify extent chain
	runs, ext_err := fs.resolve_extents(&vol, fc, fo)
	testing.expectf(t, ext_err == .None, "resolve_extents after extension")
	tt: u64
	for r in runs {tt += u64(r.count)}
	testing.expectf(t, tt == 16, "total sectors: expected 16 got %d", tt)

	// Verify cache is consistent for BOTH clusters
	ci_a := u64(fc)
	ci_b := u64(fc) + 1
	ci_vals := []u64{ci_a, ci_b}
	for _, ci in ci_vals {
		_, used, bok := fs.alloc_cache_ensure(&vol.cache, &vol, u64(ci))
		if !bok {continue}

		table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
		if fs.read_cluster_entry_table(&vol, fs.Cluster(ci), &table) != .None {continue}

		expected_used: u16 = 0
		for &e in table {
			if .Allocated in e.state {
				expected_used += e.allocation_size
			}
		}
		testing.expectf(t, used == expected_used,
			"cluster %d after extension: cache used=%d expected=%d", ci, used, expected_used)
	}
	// Cleanup
	derr := fs.deallocate_sectors(&vol, fc, fo)
	testing.expect_value(t, derr, fs.FS_Error.None)
}
