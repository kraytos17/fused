// dir_cache.odin — In-memory cache of assembled directory listings.
//
// read_directory_entries assembles a directory's full entry array from its
// extent chain on every call, and resolve_path calls it once per path
// component. The cache memoizes the assembled array per directory chain
// start, so repeat resolutions pay a map lookup plus a clone instead of a
// chain walk plus sector I/O.
//
// Slot stability is what makes this sound: directory slots never shift
// (no compaction anywhere — entries are only ever written in place or
// cleared), so a cached array stays valid until its directory is written.
// Invalidation lives in the two fs entry-write procs themselves
// (write_directory_entry_at, write_entry_at_index), which every slot
// mutation funnels through — mounter writers, tests, and future fs
// writers alike. Entry-content writes (chmod and friends) drop too:
// harmless over-invalidation, always correctness-safe.
//
// Locking: entries are inserted and read under the mounter's FS.mu
// (exclusive on every path that reaches read_directory_entries today);
// arrays handed out are owned clones, so callers need no lock once they
// hold the clone. Lifecycle: volume_open/close (production, dump tools),
// open/close_test_volume plus the manual-init tests (tests/).
#+build linux
package fs

import "core:container/lru"

// Dir_Entry_Cache LRU cache of assembled directory listings keyed by the
// directory's chain start.
Dir_Entry_Cache :: struct {
	lru: lru.Cache(Chain_Location, [dynamic]Indexed_Entry),
}

@(private = "file")
_dir_cache_on_remove :: proc(key: Chain_Location, val: [dynamic]Indexed_Entry, user_data: rawptr) {
	delete(val)
}

// dir_cache_init initializes the directory listing cache.
dir_cache_init :: proc(cache: ^Dir_Entry_Cache, capacity := DEFAULT_CACHE_CONFIG.dir_cap) {
	lru.init(&cache.lru, capacity, context.allocator, context.allocator)
	cache.lru.on_remove = _dir_cache_on_remove
}

// dir_cache_destroy destroys the cache and frees entries.
dir_cache_destroy :: proc(cache: ^Dir_Entry_Cache) {
	lru.destroy(&cache.lru, true)
	cache^ = {}
}

// dir_cache_invalidate drops a directory's listing from the cache.
// Called from the fs entry-write procs on every slot write.
dir_cache_invalidate :: proc(cache: ^Dir_Entry_Cache, loc: Chain_Location) {
	lru.remove(&cache.lru, loc)
}
