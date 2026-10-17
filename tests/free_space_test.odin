// free_space_test.odin — free-space accounting regression tests.
//
// alloc_cache_count_free once counted unset bitmap bits in every cluster,
// including Reserved clusters (fully unavailable) and Full clusters (the
// allocator skips them), inflating statfs. The independent oracle below
// aggregates per-CME state instead of bitmaps; both must agree exactly,
// on a fresh image and across allocate/deallocate churn.
//
// Accounting rule (shared by implementation and oracle): a cluster's free
// sectors are those in neither the table sector nor any live entry range
// (set semantics — a Cluster_Map pseudo-entry may share the table sector,
// so ranges are unioned, never summed).
#+build linux
package tests

import "core:os"
import "core:testing"
import "src:fs"

FREE_SCRATCH := "/dev/shm/fused_free_test.img"

// cluster_free_counts the free sectors of one cluster with set semantics.
cluster_free_count :: proc(
	cluster_size: u64,
	sector_index: u16,
	table: ^[fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry,
) -> u64 {
	free: u64 = 0
	for sec in 0 ..< int(cluster_size) {
		in_use := sec == int(sector_index)
		if !in_use {
			for e in table {
				if .Allocated in e.state &&
				   sec >= int(e.sector_start) &&
				   sec < int(e.sector_start) + int(e.allocation_size) {
					in_use = true
					break
				}
			}
		}
		if !in_use { free += 1 }
	}
	return free
}

// slow_free_scan is the independent oracle: per-CME state machine over
// cluster-map entries and live allocation sizes, not bitmaps. Reserved
// and Full clusters contribute zero. Mirrors count_free's fail-closed
// skips (unreadable metadata contributes zero).
slow_free_scan :: proc(t: ^testing.T, vol: ^fs.Volume) -> u64 {
	total: u64 = 0
	n := int(vol.master.cluster_map_size)
	for ci in 0 ..< n {
		cme, cerr := fs.read_cluster_map_entry(vol, fs.Cluster(ci))
		if cerr != .None { continue }
		if .Reserved in cme.flags || .Full in cme.flags { continue }
		// An unallocated cluster has no live table content, but its table
		// sector is still reserved for first use.
		table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
		if .Allocated in cme.flags {
			if fs.read_cluster_entry_table(vol, fs.Cluster(ci), &table) != .None { continue }
		}
		total += cluster_free_count(u64(vol.master.cluster_size), cme.sector_index, &table)
	}
	return total
}

// test_free_count_matches_oracle_fresh — exact agreement on a fresh image
// (was: reserved clusters inflated the count).
@(test)
test_free_count_matches_oracle_fresh :: proc(t: ^testing.T) {
	vol, ok := scratch_volume(t, FREE_SCRATCH)
	if !ok { return }
	defer close_scratch_volume(&vol, FREE_SCRATCH)

	testing.expect_value(t, fs.alloc_cache_count_free(&vol), slow_free_scan(t, &vol))
}

// test_free_count_matches_oracle_churn — agreement plus exact deltas
// across allocate/deallocate churn.
@(test)
test_free_count_matches_oracle_churn :: proc(t: ^testing.T) {
	vol, ok := scratch_volume(t, FREE_SCRATCH)
	if !ok { return }
	defer close_scratch_volume(&vol, FREE_SCRATCH)

	f0 := fs.alloc_cache_count_free(&vol)
	testing.expect_value(t, f0, slow_free_scan(t, &vol))

	hc, ho, aerr := fs.allocate_sectors(&vol, {}, 100, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }
	testing.expect_value(t, fs.alloc_cache_count_free(&vol), f0 - 100)
	testing.expect_value(t, fs.alloc_cache_count_free(&vol), slow_free_scan(t, &vol))

	derr := fs.deallocate_sectors(&vol, fs.Chain_Location{hc, ho})
	testing.expect_value(t, derr, fs.FS_Error.None)
	testing.expect_value(t, fs.alloc_cache_count_free(&vol), f0)
	testing.expect_value(t, fs.alloc_cache_count_free(&vol), slow_free_scan(t, &vol))
}

// test_free_count_ignores_full_clusters — marking a cluster Full drops
// exactly its set-semantics contribution, and the oracle still agrees.
@(test)
test_free_count_ignores_full_clusters :: proc(t: ^testing.T) {
	vol, ok := scratch_volume(t, FREE_SCRATCH)
	if !ok { return }
	defer close_scratch_volume(&vol, FREE_SCRATCH)

	hc, _, aerr := fs.allocate_sectors(&vol, {}, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }
	f0 := fs.alloc_cache_count_free(&vol)
	testing.expect_value(t, f0, slow_free_scan(t, &vol))

	cme, cerr := fs.read_cluster_map_entry(&vol, hc)
	testing.expect_value(t, cerr, fs.FS_Error.None)
	if cerr != .None { return }
	ctable: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	testing.expect_value(t, fs.read_cluster_entry_table(&vol, hc, &ctable), fs.FS_Error.None)
	expected_drop := cluster_free_count(u64(vol.master.cluster_size), cme.sector_index, &ctable)
	cme.flags += {.Full}
	testing.expect_value(
		t,
		fs.write_cluster_map_entry(&vol, hc, &cme),
		fs.FS_Error.None,
	)

	f1 := fs.alloc_cache_count_free(&vol)
	testing.expect_value(t, f1, slow_free_scan(t, &vol))
	testing.expect_value(t, f0 - f1, expected_drop)
}
