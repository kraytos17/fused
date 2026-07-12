// alloc_cache.odin — In-memory bitmap cache for the sector allocator.
//
// Uses a fixed-capacity LRU cache (1024 entries) instead of cluster_map_size-
// scaled arrays, so memory consumption is bounded regardless of filesystem size.
// Bitmaps are built lazily on first access, evicted LRU-first when at capacity.
#+build linux
package fs

import "core:container/lru"
import "core:os"

Alloc_Cache_Entry :: struct {
	bitmap: []u8,
	used:   u16,
}

Cluster_Bitmap_Cache :: struct {
	lru:        lru.Cache(u64, Alloc_Cache_Entry),
	hint:       u64,
	bitmap_len: int,
}

@private
alloc_cache_on_remove :: proc(key: u64, val: Alloc_Cache_Entry, user_data: rawptr) {
	delete(val.bitmap)
}

ALLOC_CACHE_CAPACITY :: 1024

// alloc_cache_init initializes the LRU cache. No disk I/O or large array allocs.
alloc_cache_init :: proc(cache: ^Cluster_Bitmap_Cache, master: ^Master_Record) {
	cache.bitmap_len = int((master.cluster_size + 7) / 8)
	cache.hint = 0
	lru.init(&cache.lru, ALLOC_CACHE_CAPACITY, context.allocator, context.allocator)
	cache.lru.on_remove = alloc_cache_on_remove
}

// alloc_cache_destroy frees all cached bitmaps.
alloc_cache_destroy :: proc(cache: ^Cluster_Bitmap_Cache) {
	lru.destroy(&cache.lru, true)
	cache^ = {}
}

// alloc_cache_invalidate removes a cluster's bitmap from the cache.
alloc_cache_invalidate :: proc(cache: ^Cluster_Bitmap_Cache, cluster: u64) {
	lru.remove(&cache.lru, cluster)
}

@private
cache_bitmap :: #force_inline proc(cache: ^Cluster_Bitmap_Cache, cluster: u64) -> []u8 {
	return make([]u8, cache.bitmap_len)
}

// alloc_cache_ensure returns up-to-date bitmap and used count for a cluster.
// Builds from disk on cache miss; returns ok=false if cluster index is invalid.
alloc_cache_ensure :: proc(cache: ^Cluster_Bitmap_Cache, master: ^Master_Record, disk: ^os.File, cluster: u64) -> (bitmap: []u8, used: u16, ok: bool) {
	if u64(cluster) >= master.cluster_map_size {
		return {}, 0, false
	}
	if entry, hit := lru.get(&cache.lru, cluster); hit {
		return entry.bitmap, entry.used, true
	}

	_alloc_cache_build(cache, master, disk, Cluster(cluster))
	entry, hit := lru.get(&cache.lru, cluster)
	if !hit {
		return {}, 0, false
	}
	return entry.bitmap, entry.used, true
}

@private
_alloc_cache_build :: proc(cache: ^Cluster_Bitmap_Cache, master: ^Master_Record, disk: ^os.File, cluster: Cluster) {
	bitmap := cache_bitmap(cache, u64(cluster))
	cme, cme_ok := read_cluster_map_entry(disk, master, cluster)
	if !cme_ok {
		if err := lru.set(&cache.lru, u64(cluster), Alloc_Cache_Entry{bitmap, 0}); err != nil {
			delete(bitmap)
		}
		return
	}

	bit_mark(bitmap, cme.sector_index)
	used: u16 = 0
	table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
	if !read_cluster_entry_table(disk, master, cluster, &table) {
		if err := lru.set(&cache.lru, u64(cluster), Alloc_Cache_Entry{bitmap, used}); err != nil {
			delete(bitmap)
		}
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
	if err := lru.set(&cache.lru, u64(cluster), Alloc_Cache_Entry{bitmap, used}); err != nil {
		delete(bitmap)
	}
}

// alloc_cache_count_free returns the total number of free sectors.
// Uses a stack-local fallback (no LRU pollution) to avoid rebuild churn.
alloc_cache_count_free :: proc(cache: ^Cluster_Bitmap_Cache, master: ^Master_Record, disk: ^os.File) -> u64 {
	free: u64 = 0
	for ci in 0 ..< int(master.cluster_map_size) {
		local_bitmap: [DEFAULT_CLUSTER_SIZE]u8
		bitmap_len := max(1, int((master.cluster_size + 7) / 8))
		bitmap := local_bitmap[:bitmap_len]
		cme := read_cluster_map_entry(disk, master, Cluster(ci)) or_continue
		get_bitmap_fallback(bitmap, master, disk, Cluster(ci), &cme)
		for b in 0 ..< u16(master.cluster_size) {
			if !bit_isset(bitmap, u16(b)) {
				free += 1
			}
		}
	}
	return free
}
