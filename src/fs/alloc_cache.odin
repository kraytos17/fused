// alloc_cache.odin — In-memory bitmap cache for the sector allocator.
//
// Caches per-cluster free-sector bitmaps so allocate_sectors avoids
// re-reading cluster entry tables from disk on every scan.
// Built lazily on first access, invalidated on every table write.
//
// Not thread-safe. Single-threaded use only.
#+build linux
package fs

import "core:mem"
import "core:os"

Cluster_Bitmap_Cache :: struct {
	data:       []u8,    // flat: cluster_map_size * bitmap_len bytes
	valid:      []bool,  // per-cluster validity flag
	used:       []u16,   // per-cluster used-sector count
	hint:       u64,
	bitmap_len: int,
}

// alloc_cache_init allocates cache structures for all clusters.
// No disk I/O — bitmaps are built lazily on first access.
alloc_cache_init :: proc(cache: ^Cluster_Bitmap_Cache, master: ^Master_Record) {
	cache.bitmap_len = int((master.cluster_size + 7) / 8)
	cache.hint = 0
	n := int(master.cluster_map_size)
	cache.data = make([]u8, n * cache.bitmap_len)
	cache.valid = make([]bool, n)
	cache.used = make([]u16, n)
}

// alloc_cache_destroy frees all bitmap memory.
alloc_cache_destroy :: proc(cache: ^Cluster_Bitmap_Cache) {
	delete(cache.data)
	delete(cache.valid)
	delete(cache.used)
	cache^ = {}
}

// alloc_cache_invalidate marks a cluster's bitmap as stale.
// Called after any write to that cluster's entry table.
alloc_cache_invalidate :: proc(cache: ^Cluster_Bitmap_Cache, cluster: u64) {
	if int(cluster) < len(cache.valid) {
		cache.valid[cluster] = false
	}
}

@private
cache_bitmap :: #force_inline proc(cache: ^Cluster_Bitmap_Cache, cluster: u64) -> []u8 {
	off := int(cluster) * cache.bitmap_len
	return cache.data[off:off + cache.bitmap_len]
}

// alloc_cache_ensure returns up-to-date bitmap and used count for a cluster.
// Builds from disk if the cache is stale or uninitialized.
alloc_cache_ensure :: proc(cache: ^Cluster_Bitmap_Cache, master: ^Master_Record, disk: ^os.File, cluster: u64) -> (bitmap: []u8, used: u16, ok: bool) {
	if int(cluster) >= len(cache.valid) {
		return {}, 0, false
	}
	if !cache.valid[cluster] {
		_alloc_cache_build(cache, master, disk, Cluster(cluster))
	}
	return cache_bitmap(cache, cluster), cache.used[cluster], true
}

@private
_alloc_cache_build :: proc(cache: ^Cluster_Bitmap_Cache, master: ^Master_Record, disk: ^os.File, cluster: Cluster) {
	bitmap := cache_bitmap(cache, u64(cluster))
	mem.zero_slice(bitmap)
	cme, cme_ok := read_cluster_map_entry(disk, master, cluster)
	if !cme_ok {
		cache.valid[int(cluster)] = true
		cache.used[int(cluster)] = 0
		return
	}

	bit_mark(bitmap, cme.sector_index)
	used: u16 = 0
	table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
	if !read_cluster_entry_table(disk, master, cluster, &table) {
		cache.valid[int(cluster)] = true
		cache.used[int(cluster)] = 0
		return
	}
	for &e in table {
		if .Allocated in e.state {
			for off in 0 ..< e.allocation_size {
				bit_mark(bitmap, e.sector_start + off)
			}
			used += e.allocation_size
		}
	}
	cache.used[int(cluster)] = used
	cache.valid[int(cluster)] = true
}

// alloc_cache_count_free returns the total number of free sectors across all clusters.
alloc_cache_count_free :: proc(cache: ^Cluster_Bitmap_Cache, master: ^Master_Record, disk: ^os.File) -> u64 {
	free: u64 = 0
	for i in 0 ..< int(master.cluster_map_size) {
		bitmap, _, ok := alloc_cache_ensure(cache, master, disk, u64(i))
		if !ok {
			continue
		}
		for b in 0 ..< u16(master.cluster_size) {
			if !bit_isset(bitmap, u16(b)) {
				free += 1
			}
		}
	}
	return free
}
