// alloc_cache.odin — In-memory bitmap cache for the sector allocator.
#+build linux
package fs

import "core:container/bit_array"
import "core:container/lru"
import "core:log"

@(private = "file")
// Alloc_Cache_Entry struct holding a cached bitmap and its used count
Alloc_Cache_Entry :: struct {
	bitmap: bit_array.Bit_Array,
	used:   u16,
}

// Cache_Config sizes the three in-memory caches. Non-positive entries mean
// "use the default", so a zero Cache_Config is valid and selects defaults.
Cache_Config :: struct {
	path_cap:  int, // path LRU entries (mounter)
	lfn_cap:   int, // LFN LRU entries (mounter)
	alloc_cap: int, // cluster-bitmap LRU entries (fs)
}

// DEFAULT_CACHE_CONFIG is the stock cache sizing (matches historic constants).
DEFAULT_CACHE_CONFIG :: Cache_Config {
	path_cap  = 128,
	lfn_cap   = 256,
	alloc_cap = 1024,
}

// Cluster_Bitmap_Cache LRU cache for cluster bitmaps
Cluster_Bitmap_Cache :: struct {
	lru:        lru.Cache(u64, Alloc_Cache_Entry),
	hint:       u64,
	cache_size: int,
}

@(private = "file")
_alloc_cache_on_remove :: proc(key: u64, val: Alloc_Cache_Entry, user_data: rawptr) {
	b := val.bitmap
	bit_array.destroy(&b)
}

// alloc_cache_init initializes the bitmap cache
alloc_cache_init :: proc(
	cache: ^Cluster_Bitmap_Cache,
	master: ^Master_Record,
	capacity := DEFAULT_CACHE_CONFIG.alloc_cap,
) {
	cache.cache_size = int(master.cluster_size)
	cache.hint = 0
	lru.init(&cache.lru, capacity, context.allocator, context.allocator)
	cache.lru.on_remove = _alloc_cache_on_remove
}

// alloc_cache_destroy destroys the bitmap cache and frees entries
alloc_cache_destroy :: proc(cache: ^Cluster_Bitmap_Cache) {
	lru.destroy(&cache.lru, true)
	cache^ = {}
}

// alloc_cache_invalidate removes a cluster's bitmap from cache
alloc_cache_invalidate :: proc(cache: ^Cluster_Bitmap_Cache, cluster: u64) {
	lru.remove(&cache.lru, cluster)
}

@(private = "file")
_cache_bitmap :: #force_inline proc(cache: ^Cluster_Bitmap_Cache) -> bit_array.Bit_Array {
	ba: bit_array.Bit_Array
	bit_array.init(&ba, cache.cache_size, 0)
	return ba
}

// alloc_cache_ensure returns the bitmap for a cluster (from cache or builds it).
// Out-of-range clusters report .Cluster_Not_Found; build I/O failures
// propagate instead of caching an empty (all-free) bitmap, which would
// double-allocate live sectors. Callers treat any error as "skip cluster".
alloc_cache_ensure :: proc(
	cache: ^Cluster_Bitmap_Cache,
	vol: ^Volume,
	cluster: u64,
) -> (
	bitmap: bit_array.Bit_Array,
	used: u16,
	err: FS_Error,
) {
	if u64(cluster) >= vol.master.cluster_map_size {
		return {}, 0, .Cluster_Not_Found
	}
	if entry, hit := lru.get(&cache.lru, cluster); hit {
		return entry.bitmap, entry.used, .None
	}

	if berr := _alloc_cache_build(cache, vol, Cluster(cluster)); berr != .None {
		return {}, 0, berr
	}
	entry, hit := lru.get(&cache.lru, cluster)
	if !hit {
		// Unreachable: a successful build always inserts. Defensive.
		return {}, 0, .No_Space
	}
	return entry.bitmap, entry.used, .None
}

@(private = "file")
// _alloc_cache_build builds a bitmap by scanning the CE table on disk
_alloc_cache_build :: proc(
	cache: ^Cluster_Bitmap_Cache,
	vol: ^Volume,
	cluster: Cluster,
) -> FS_Error {
	bitmap := _cache_bitmap(cache)
	cme, cme_err := read_cluster_map_entry(vol, cluster)
	if cme_err != .None {
		bit_array.destroy(&bitmap)
		return cme_err
	}

	// Indices come from disk: guard the range explicitly and keep unsafe_set
	// (checked set would grow the bitmap via resize_if_needed instead of
	// failing). Out-of-range bits can only hide free space, never expose
	// allocated sectors, so skipping is fail-closed. The table's own sector
	// is overhead and counts as used, as before. A cluster without an
	// allocated table holds no other allocations, so the empty bitmap is
	// accurate (preserves historical ensure semantics for fresh and
	// reserved clusters). A present-but-unreadable table is a genuine I/O
	// failure and propagates — it must never masquerade as all-free, which
	// would double-allocate live sectors.
	skipped := 0
	if int(cme.sector_index) < cache.cache_size {
		bit_array.unsafe_set(&bitmap, int(cme.sector_index))
	} else {
		skipped += 1
	}

	used: u16 = 0
	if .Allocated in cme.flags {
		table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
		if terr := read_cluster_entry_table(vol, cluster, &table); terr != .None {
			bit_array.destroy(&bitmap)
			return terr
		}
		for &e in table {
			if .Allocated in e.state {
				for off in 0 ..< e.allocation_size {
					s := int(e.sector_start) + int(off)
					if s < cache.cache_size {
						bit_array.unsafe_set(&bitmap, s)
						used += 1
					} else {
						skipped += 1
					}
				}
			}
		}
	}
	if skipped > 0 {
		log.warnf(
			"alloc_cache: cluster %d has %d out-of-range bits — image may be corrupt",
			u64(cluster),
			skipped,
		)
	}
	// Node allocation failure surfaces as .No_Space (memory); the bitmap is
	// destroyed so no half-inserted entry lingers.
	if err := lru.set(&cache.lru, u64(cluster), Alloc_Cache_Entry{bitmap, used}); err != nil {
		bit_array.destroy(&bitmap)
		return .No_Space
	}
	return .None
}

// alloc_cache_count_free counts free sectors across all clusters
alloc_cache_count_free :: proc(vol: ^Volume) -> u64 {
	free: u64 = 0
	for ci in 0 ..< int(vol.master.cluster_map_size) {
		bm, _, berr := alloc_cache_ensure(&vol.cache, vol, u64(ci))
		if berr != .None { continue }
		it := bit_array.make_iterator(&bm)
		for set, _ in bit_array.iterate_by_all(&it) {
			if !set {
				free += 1
			}
		}
	}
	return free
}
