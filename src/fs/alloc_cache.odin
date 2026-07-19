// alloc_cache.odin — In-memory bitmap cache for the sector allocator.
#+build linux
package fs

import "core:container/bit_array"
import "core:container/lru"

@private
Alloc_Cache_Entry :: struct {
	bitmap: bit_array.Bit_Array,
	used:   u16,
}

Cluster_Bitmap_Cache :: struct {
	lru:        lru.Cache(u64, Alloc_Cache_Entry),
	hint:       u64,
	cache_size: int,
}

@private
alloc_cache_on_remove :: proc(key: u64, val: Alloc_Cache_Entry, user_data: rawptr) {
	b := val.bitmap
	bit_array.destroy(&b)
}

ALLOC_CACHE_CAPACITY :: 1024

alloc_cache_init :: proc(cache: ^Cluster_Bitmap_Cache, master: ^Master_Record) {
	cache.cache_size = int(master.cluster_size)
	cache.hint = 0
	lru.init(&cache.lru, ALLOC_CACHE_CAPACITY, context.allocator, context.allocator)
	cache.lru.on_remove = alloc_cache_on_remove
}

alloc_cache_destroy :: proc(cache: ^Cluster_Bitmap_Cache) {
	lru.destroy(&cache.lru, true)
	cache^ = {}
}

alloc_cache_invalidate :: proc(cache: ^Cluster_Bitmap_Cache, cluster: u64) {
	lru.remove(&cache.lru, cluster)
}

@private
cache_bitmap :: #force_inline proc(cache: ^Cluster_Bitmap_Cache) -> bit_array.Bit_Array {
	ba: bit_array.Bit_Array
	bit_array.init(&ba, cache.cache_size, 0)
	return ba
}

alloc_cache_ensure :: proc(cache: ^Cluster_Bitmap_Cache, vol: ^Volume, cluster: u64) -> (bitmap: bit_array.Bit_Array, used: u16, ok: bool) {
	if u64(cluster) >= vol.master.cluster_map_size {
		return {}, 0, false
	}
	if entry, hit := lru.get(&cache.lru, cluster); hit {
		return entry.bitmap, entry.used, true
	}

	_alloc_cache_build(cache, vol, Cluster(cluster))
	entry, hit := lru.get(&cache.lru, cluster)
	if !hit {
		return {}, 0, false
	}
	return entry.bitmap, entry.used, true
}

@private
_alloc_cache_build :: proc(cache: ^Cluster_Bitmap_Cache, vol: ^Volume, cluster: Cluster) {
	bitmap := cache_bitmap(cache)
	cme, cme_ok := read_cluster_map_entry(vol, cluster)
	if !cme_ok {
		if err := lru.set(&cache.lru, u64(cluster), Alloc_Cache_Entry{bitmap, 0}); err != nil {
			bit_array.destroy(&bitmap)
		}
		return
	}

	bit_array.unsafe_set(&bitmap, int(cme.sector_index))
	used: u16 = 0
	table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
	if !read_cluster_entry_table(vol, cluster, &table) {
		if err := lru.set(&cache.lru, u64(cluster), Alloc_Cache_Entry{bitmap, used}); err != nil {
			bit_array.destroy(&bitmap)
		}
		return
	}
	for &e in table {
		if .Allocated in e.state {
			for off in 0 ..< e.allocation_size {
				bit_array.unsafe_set(&bitmap, int(e.sector_start + off))
			}
			used += e.allocation_size
		}
	}
	if err := lru.set(&cache.lru, u64(cluster), Alloc_Cache_Entry{bitmap, used}); err != nil {
		bit_array.destroy(&bitmap)
	}
}

alloc_cache_count_free :: proc(vol: ^Volume) -> u64 {
	free: u64 = 0
	for ci in 0 ..< int(vol.master.cluster_map_size) {
		bm, _, bok := alloc_cache_ensure(&vol.cache, vol, u64(ci))
		if !bok { continue }
		for b in 0 ..< u16(vol.master.cluster_size) {
			if !bit_array.unsafe_get(&bm, int(b)) {
				free += 1
			}
		}
	}
	return free
}
