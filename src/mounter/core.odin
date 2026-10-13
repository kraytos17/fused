// core.odin — Shared infrastructure for the FUSE callbacks.
//
// Every callback retrieves its FS state via fuse_get_context().private_data
// (the get_fs() helper).
#+build linux
package mounter

import "core:c"
import "core:container/lru"
import "core:log"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"
import "src:fs"
import "src:fuse3"

// get_dir_entry returns a pointer to the Directory_Entry at the given index
// within a sector-sized buffer.
get_dir_entry :: #force_inline proc(
	buf: []u8,
	index: int,
	features: fs.Features,
) -> ^fs.Directory_Entry {
	des := int(fs.dir_entry_size(features))
	return (^fs.Directory_Entry)(mem.ptr_offset(&buf[0], index * des))
}

// dir_entries_per_buf returns the number of directory entries that fit in a
// single sector.
dir_entries_per_buf :: #force_inline proc(features: fs.Features) -> int {
	return int(fs.dir_entries_per_sector(features))
}

// FS is the per-mount filesystem state, passed as fuse user_data.
FS :: struct {
	// vol is the opened disk volume.
	vol:          fs.Volume,
	// disk_raw_fd is the raw file descriptor for the disk image, used for
	// zero-copy splice I/O.
	disk_raw_fd:  c.int,
	// logger is the per-mount logger instance.
	logger:       log.Logger,
	// mu serialises access to the volume and caches. Mutating callbacks take
	// it exclusively (begin_op); read-only callbacks share it
	// (begin_read_op) and must use only non-mutating cache access (peek or
	// snapshot helpers) while it is held.
	mu:           sync.RW_Mutex,
	// allocator is the allocator passed to init_fs_state; used for cache
	// reconstruction so tests with custom allocators stay consistent.
	allocator:    mem.Allocator,
	// path_cache is an LRU cache mapping path strings to resolved entries.
	path_cache:   lru.Cache(string, Path_Cache_Value),
	// lfn_cache is an LRU cache mapping (cluster,offset,index) to long
	// file names.
	lfn_cache:    lru.Cache(u64, string),
	// extents caches resolved extent chains keyed by (data_cluster, offset).
	// Cached slices are owned by the cache; invalidated on any metadata
	// mutation (write/truncate/fallocate/unlink/xattr).
	extents:      map[Extent_Cache_Key][]fs.Extent_Run,
	// free_sectors caches the volume's free sector count so statfs is O(1).
	free_sectors: u64,
	// locks holds POSIX fcntl region locks per file (in-memory, advisory).
	locks:        map[File_Identity][dynamic]Region_Lock,
	// flock_locks holds BSD flock holders per file (in-memory, advisory).
	flock_locks:  map[File_Identity][dynamic]Flock_State,
}

// Extent_Cache_Key identifies a resolved extent chain by its start cluster and
// sector offset within that cluster.
Extent_Cache_Key :: struct {
	cluster: u64,
	offset:  u16,
}

// get_fs retrieves the FS pointer from the FUSE context's private_data.
get_fs :: #force_inline proc "contextless" () -> ^FS {
	return (^FS)(fuse3.fuse_get_context().private_data)
}

// begin_op locks the mutex exclusively, resets the temp allocator, sets the
// logger, and returns the FS pointer. Must be paired with end_op. Use for
// callbacks that mutate shared state (caches, lock tables, free count).
begin_op :: proc() -> ^FS {
	fsys := get_fs()
	free_all(context.temp_allocator)
	context.logger = fsys.logger
	sync.rw_mutex_lock(&fsys.mu)
	return fsys
}

// end_op unlocks the mutex.
end_op :: proc(fsys: ^FS) {
	sync.rw_mutex_unlock(&fsys.mu)
}

// begin_read_op takes the mutex shared, resets the temp allocator, sets the
// logger, and returns the FS pointer. Must be paired with end_read_op. Use
// for read-only callbacks: while the shared lock is held, touch shared
// state only through non-mutating access (lru.peek, snapshot helpers that
// upgrade internally). Never insert into or clear a cache while shared-held
// except through an upgrade helper (resolve_extents_shared,
// lfn_lookup_shared), which releases shared, takes exclusive, re-checks,
// and re-takes shared before returning.
begin_read_op :: proc() -> ^FS {
	fsys := get_fs()
	free_all(context.temp_allocator)
	context.logger = fsys.logger
	sync.rw_mutex_shared_lock(&fsys.mu)
	return fsys
}

// end_read_op releases the shared lock.
end_read_op :: proc(fsys: ^FS) {
	sync.rw_mutex_shared_unlock(&fsys.mu)
}

// fs_error_to_errno translates an FS_Error to a POSIX errno value.
// Unknown errors fall through to EIO (the `case:` default is deliberate —
// a new FS_Error value is a mapping decision, not a compile error; keep it
// in sync with `FS_Error` in src/fs/structure.odin).
fs_error_to_errno :: proc(err: fs.FS_Error) -> c.int {
	#partial switch err {
	case .None:
		return 0
	case .Entry_Not_Found:
		return -c.int(posix.ENOENT)
	case .Not_A_Directory:
		return -c.int(posix.ENOTDIR)
	case .Name_Too_Long:
		return -c.int(posix.ENAMETOOLONG)
	case .No_Space:
		return -c.int(posix.ENOSPC)
	case .Sector_Read_Error, .Sector_Write_Error:
		return -c.int(posix.EIO)
	case:
		return -c.int(posix.EIO)
	}
}

UTIME_NOW :: 1073741822
UTIME_OMIT :: 1073741823

// set_entry_time_from_unix sets both mtime and atime on an entry from a Unix
// timestamp.
set_entry_time_from_unix :: proc(entry: ^fs.Directory_Entry, sec: i64) {
	_set_time_fields(&entry.year, &entry.date_time, sec)
	_set_time_fields(&entry.atime_year, &entry.atime_date_time, sec)
}

// set_entry_time_to_now sets both mtime and atime on an entry to the current
// wall clock.
set_entry_time_to_now :: proc(entry: ^fs.Directory_Entry) {
	_set_time_fields_now(&entry.year, &entry.date_time)
	_set_time_fields_now(&entry.atime_year, &entry.atime_date_time)
}

// set_entry_mtime_from_unix sets the modification time from a Unix timestamp.
set_entry_mtime_from_unix :: proc(entry: ^fs.Directory_Entry, sec: i64) {
	_set_time_fields(&entry.year, &entry.date_time, sec)
}

// set_entry_atime_from_unix sets the access time from a Unix timestamp.
set_entry_atime_from_unix :: proc(entry: ^fs.Directory_Entry, sec: i64) {
	_set_time_fields(&entry.atime_year, &entry.atime_date_time, sec)
}

// set_entry_mtime_to_now sets the modification time to the current time.
set_entry_mtime_to_now :: proc(entry: ^fs.Directory_Entry) {
	_set_time_fields_now(&entry.year, &entry.date_time)
}

// set_entry_atime_to_now sets the access time to the current time.
set_entry_atime_to_now :: proc(entry: ^fs.Directory_Entry) {
	_set_time_fields_now(&entry.atime_year, &entry.atime_date_time)
}

// _set_time_fields writes year/month/day/hour/minute/second into the given
// fields from a Unix timestamp.
@(private = "file")
_set_time_fields :: proc(year: ^u16, dt: ^fs.Packed_Date_Time, sec: i64) {
	t := time.unix(sec, 0)
	y, mo, d := time.date(t)
	h, m, s := time.clock(t)
	year^ = u16(y)
	dt^ = fs.Packed_Date_Time {
		month  = u32(int(mo)),
		date   = u32(d),
		hour   = u32(h),
		minute = u32(m),
		second = u32(s),
	}
}

// _set_time_fields_now writes the current wall-clock time into the given
// date/time fields.
@(private = "file")
_set_time_fields_now :: proc(year: ^u16, dt: ^fs.Packed_Date_Time) {
	now := time.now()
	y, mo, d := time.date(now)
	h, m, s := time.clock(now)
	year^ = u16(y)
	dt^ = fs.Packed_Date_Time {
		month  = u32(int(mo)),
		date   = u32(d),
		hour   = u32(h),
		minute = u32(m),
		second = u32(s),
	}
}

// fh_parts unpacks a packed file handle into its identity fields (the
// directory location of the entry it refers to).
fh_parts :: proc "contextless" (
	fh: u64,
) -> (
	dir_cluster: fs.Cluster,
	dir_offset: fs.Sector_Offset,
	entry_index: int,
) {
	f := transmute(fs.File_Handle)(fh)
	return fs.Cluster(f.dir_cluster), fs.Sector_Offset(f.dir_offset), int(f.entry_index)
}

// mutate_entry_at is the shared read-modify-write wrapper for metadata-only
// FUSE callbacks that update a single directory entry (chmod, chown,
// utimens, and xattr entry writes). It resolves the entry, calls mutate
// with the caller-provided user context, writes it back, and invalidates
// caches. mutate returning false skips the write without error. When
// invalidate_all is false only the single path is removed (used by utimens,
// where the directory structure hasn't changed).
mutate_entry_at :: proc(
	fsys: ^FS,
	path: cstring,
	fi: ^fuse3.File_Info,
	mutate: proc(entry: ^fs.Directory_Entry, user: rawptr) -> bool,
	user: rawptr = nil,
	invalidate_all := true,
) -> c.int {
	entry, entry_cluster, entry_offset, entry_idx, _, _, resolved := resolve_entry(fsys, path, fi)
	if !resolved {
		return fuse3.nix(.ENOENT)
	}
	if !mutate(&entry, user) {
		return 0
	}
	if !write_entry_back(fsys, &entry, entry_cluster, entry_offset, entry_idx) {
		return fuse3.nix(.EIO)
	}
	if invalidate_all {
		path_cache_invalidate_all(fsys)
	} else {
		lru.remove(&fsys.path_cache, string(path))
	}
	return 0
}

// read_entry_from_fh reads a Directory_Entry from a packed File_Handle,
// returning the entry, its data cluster, data offset, and whether it succeeded.
read_entry_from_fh :: proc(
	fsys: ^FS,
	fh: u64,
) -> (
	fs.Directory_Entry,
	fs.Cluster,
	fs.Sector_Offset,
	bool,
) {
	dir_cluster, dir_offset, entry_index := fh_parts(fh)
	e, err := fs.read_entry_at_index(&fsys.vol, dir_cluster, dir_offset, entry_index)
	if err != .None {
		return {}, 0, 0, false
	}
	return e, fs.Cluster(e.stored_cluster), fs.Sector_Offset(e.sector_index), true
}

// Path_Cache_Value holds a cached path resolution result.
Path_Cache_Value :: struct {
	entry:       fs.Directory_Entry,
	cluster:     fs.Cluster,
	offset:      fs.Sector_Offset,
	entry_index: int,
}

// path_cache_on_remove is the LRU eviction callback for the path cache.
path_cache_on_remove :: proc(key: string, val: Path_Cache_Value, user_data: rawptr) {
	delete(key)
}

// lfn_cache_on_remove is the LRU eviction callback for the LFN cache.
lfn_cache_on_remove :: proc(key: u64, val: string, user_data: rawptr) {
	delete(val)
}

// lfn_cache_key builds a 64-bit key from a cluster, offset, and entry index
// for the LFN cache.
lfn_cache_key :: #force_inline proc(
	cluster: fs.Cluster,
	offset: fs.Sector_Offset,
	index: int,
) -> u64 {
	return (u64(cluster) << 32) | (u64(offset) << 16) | u64(index)
}

// lfn_lookup_shared resolves a long filename through the LFN cache without
// requiring the write lock. Caller must hold the READ lock on entry; it is
// still held on return. Uses lru.peek (non-mutating, unlike lru.get which
// rewrites recency) under shared; on a miss upgrades internally — releases
// shared, takes exclusive, re-checks, resolves, inserts, releases, re-takes
// shared — then re-peeks rather than reusing the inserted value, so a
// concurrent clear between downgrade and re-acquire cannot hand back a freed
// string. The returned string is cloned into the temp allocator: safe to use
// after the read lock is released.
lfn_lookup_shared :: proc(
	fsys: ^FS,
	key: u64,
	vol: ^fs.Volume,
	entry: ^fs.Directory_Entry,
) -> (
	name: string,
	ok: bool,
) {
	if cached, hit := lru.peek(&fsys.lfn_cache, key); hit {
		out, _ := strings.clone(cached, context.temp_allocator)
		return out, true
	}

	sync.rw_mutex_shared_unlock(&fsys.mu)
	sync.rw_mutex_lock(&fsys.mu)
	if cached, hit := lru.peek(&fsys.lfn_cache, key); hit {
		out, _ := strings.clone(cached, context.temp_allocator)
		sync.rw_mutex_unlock(&fsys.mu)
		sync.rw_mutex_shared_lock(&fsys.mu)
		return out, true
	}

	lfn, l_ok := fs.resolve_lfn(vol, entry, context.temp_allocator)
	if l_ok {
		c, _ := strings.clone(lfn, context.allocator)
		if c != "" {
			if lru.set(&fsys.lfn_cache, key, c) != nil {
				delete(c)
			}
		}
	}

	sync.rw_mutex_unlock(&fsys.mu)
	sync.rw_mutex_shared_lock(&fsys.mu)
	if !l_ok {
		return "", false
	}
	if cached, hit := lru.peek(&fsys.lfn_cache, key); hit {
		out, _ := strings.clone(cached, context.temp_allocator)
		return out, true
	}
	return lfn, true
}

// path_cache_get retrieves a cached path resolution.
path_cache_get :: proc(fsys: ^FS, path: string) -> (Path_Cache_Value, bool) {
	return lru.get(&fsys.path_cache, path)
}

// path_cache_put stores a path resolution in the cache. Paths longer than 256
// bytes are not cached.
path_cache_put :: proc(fsys: ^FS, path: string, val: Path_Cache_Value) {
	if len(path) > 256 {
		return
	}

	key := strings.clone(path, context.allocator)
	lru.set(&fsys.path_cache, key, val)
}

// path_cache_invalidate_all clears the path cache, LFN cache, and extent cache.
path_cache_invalidate_all :: proc(fsys: ^FS) {
	lru.clear(&fsys.path_cache, true)
	lru.clear(&fsys.lfn_cache, true)
	extent_cache_invalidate_all(fsys)
}

// resolve_path_cached resolves a path using the LRU path cache. On a miss the
// result is resolved and cached.
resolve_path_cached :: proc(
	fsys: ^FS,
	path: string,
	allocator := context.allocator,
) -> (
	entry: fs.Directory_Entry,
	cluster: fs.Cluster,
	offset: fs.Sector_Offset,
	entry_index: int,
	ok: bool,
) {
	if val, hit := path_cache_get(fsys, path); hit {
		return val.entry, val.cluster, val.offset, val.entry_index, true
	}

	res, res_ok := fs.resolve_path(&fsys.vol, path, allocator)
	if res_ok {
		path_cache_put(fsys, path, {res.entry, res.cluster, res.offset, res.entry_index})
	}
	return res.entry, res.cluster, res.offset, res.entry_index, res_ok
}

// resolve_entry resolves a path or a file handle to a Directory_Entry, its
// directory cluster/offset/index, and its data cluster/offset.
resolve_entry :: proc(
	fsys: ^FS,
	path: cstring,
	fi: ^fuse3.File_Info,
) -> (
	entry: fs.Directory_Entry,
	entry_cluster: fs.Cluster,
	entry_offset: fs.Sector_Offset,
	entry_idx: int,
	data_cluster: fs.Cluster,
	data_offset: fs.Sector_Offset,
	ok: bool,
) {
	if fi != nil {
		e, dc, ddo, rok := read_entry_from_fh(fsys, fi.fh)
		if !rok { return {}, 0, 0, 0, 0, 0, false }

		dir_cluster, dir_offset, fh_entry_idx := fh_parts(fi.fh)
		return e, dir_cluster, dir_offset, fh_entry_idx, dc, ddo, true
	}

	e, c, o, i, rok := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if !rok { return {}, 0, 0, 0, 0, 0, false }
	return e, c, o, i, fs.Cluster(e.stored_cluster), fs.Sector_Offset(e.sector_index), true
}

// init_fs_for_test builds an FS for direct callback unit testing (no live FUSE
// mount). The caller installs it as the FUSE context private_data via
// fuse3.set_test_context, and must call destroy_fs_for_test when done.
init_fs_for_test :: proc(vol: fs.Volume, allocator := context.allocator) -> (fsys: FS) {
	fsys.vol = vol
	fsys.disk_raw_fd = c.int(os.fd(vol.disk))
	fsys.logger = log.Logger{}
	if fi, err := os.fstat(vol.disk, context.temp_allocator); err == nil {
		fsys.vol.image_size = fs.Byte_Offset(u64(fi.size))
	}

	init_fs_state(&fsys, allocator)
	return fsys
}

// init_fs_state initialises the caches, lock tables, and free-sector count
// shared by the FUSE daemon (run) and the test harness (init_fs_for_test).
// fsys.vol must already be set.
init_fs_state :: proc(fsys: ^FS, allocator := context.allocator) {
	fsys.allocator = allocator
	lru.init(&fsys.path_cache, 128, allocator, allocator)
	fsys.path_cache.on_remove = path_cache_on_remove
	lru.init(&fsys.lfn_cache, 256, allocator, allocator)
	fsys.lfn_cache.on_remove = lfn_cache_on_remove

	fsys.extents = make(map[Extent_Cache_Key][]fs.Extent_Run, allocator)
	fsys.free_sectors = fs.alloc_cache_count_free(&fsys.vol)
	fsys.locks = make(map[File_Identity][dynamic]Region_Lock, allocator)
	fsys.flock_locks = make(map[File_Identity][dynamic]Flock_State, allocator)
}

// destroy_fs_for_test tears down an FS: drops the extent/path/LFN caches
// and lock tables without closing the volume (the caller owns it). Shared
// by the test harness and the daemon unmount path so the two can't drift.
destroy_fs_for_test :: proc(fsys: ^FS) {
	extent_cache_invalidate_all(fsys)
	for _, recs in fsys.locks {
		delete(recs)
	}
	for _, fls in fsys.flock_locks {
		delete(fls)
	}

	delete(fsys.locks)
	delete(fsys.flock_locks)
	lru.destroy(&fsys.path_cache, false)
	lru.destroy(&fsys.lfn_cache, false)
	fsys^ = {}
}

// resolve_extents_cached resolves an extent chain, caching the result so
// repeated reads/writes on the same file skip the metadata walk.  The returned
// slice is owned by the cache — callers must NOT delete it.  Caller must hold
// the WRITE lock (begin_op): the lookup may insert, and the borrowed slice
// is only valid until the next invalidation, which also requires the lock.
resolve_extents_cached :: proc(
	fsys: ^FS,
	cluster: fs.Cluster,
	offset: fs.Sector_Offset,
) -> (
	runs: []fs.Extent_Run,
	ok: bool,
) {
	key := Extent_Cache_Key{u64(cluster), u16(offset)}
	if cached, hit := fsys.extents[key]; hit {
		return cached, true
	}

	r, err := fs.resolve_extents(&fsys.vol, cluster, offset)
	if err != .None {
		return nil, false
	}

	slice_copy, _ := slice.clone(r[:])
	delete(r)
	fsys.extents[key] = slice_copy
	return slice_copy, true
}

// resolve_extents_shared resolves an extent chain for read-only paths.
// Caller must hold the READ lock on entry; it is still held on return.  The
// returned slice is cloned into the temp allocator, so it stays valid after
// the read lock is released (unlike the cache-borrowed resolve_extents_cached
// slice).  On a cache miss it upgrades internally: releases shared, takes
// exclusive, re-checks (another thread may have filled), fills, releases,
// and re-takes shared.  Never nests locks — shared is always released before
// exclusive is taken, so no deadlock against concurrent writers.
resolve_extents_shared :: proc(
	fsys: ^FS,
	cluster: fs.Cluster,
	offset: fs.Sector_Offset,
) -> (
	runs: []fs.Extent_Run,
	ok: bool,
) {
	key := Extent_Cache_Key{u64(cluster), u16(offset)}
	if cached, hit := fsys.extents[key]; hit {
		out, _ := slice.clone(cached, context.temp_allocator)
		return out, true
	}

	sync.rw_mutex_shared_unlock(&fsys.mu)
	sync.rw_mutex_lock(&fsys.mu)
	if cached, hit := fsys.extents[key]; hit {
		out, _ := slice.clone(cached, context.temp_allocator)
		sync.rw_mutex_unlock(&fsys.mu)
		sync.rw_mutex_shared_lock(&fsys.mu)
		return out, true
	}

	r, err := fs.resolve_extents(&fsys.vol, cluster, offset)
	if err != .None {
		sync.rw_mutex_unlock(&fsys.mu)
		sync.rw_mutex_shared_lock(&fsys.mu)
		return nil, false
	}

	slice_copy, _ := slice.clone(r[:])
	delete(r)

	fsys.extents[key] = slice_copy
	out, _ := slice.clone(slice_copy, context.temp_allocator)
	sync.rw_mutex_unlock(&fsys.mu)
	sync.rw_mutex_shared_lock(&fsys.mu)
	return out, true
}

// extent_cache_invalidate_all drops every cached extent chain.  Call after any
// metadata mutation that can change a chain (write, truncate, fallocate,
// unlink, rmdir, rename, xattr store/clear).  Do NOT call while borrowed
// slices from this cache are still in use.
extent_cache_invalidate_all :: proc(fsys: ^FS) {
	for _, runs in fsys.extents {
		delete(runs)
	}

	delete(fsys.extents)
	fsys.extents = make(map[Extent_Cache_Key][]fs.Extent_Run, fsys.allocator)
}

// extent_cache_invalidate drops a single cached chain.  Use when a mutation
// affects only one chain so other borrowed cached slices stay valid.
extent_cache_invalidate :: proc(fsys: ^FS, cluster: fs.Cluster, offset: fs.Sector_Offset) {
	key := Extent_Cache_Key{u64(cluster), u16(offset)}
	if runs, ok := fsys.extents[key]; ok {
		delete(runs)
		delete_key(&fsys.extents, key)
	}
}

// reinit_free_sectors recomputes the cached free-sector count from the volume.
// Used after deallocation where the exact freed count isn't tracked.
reinit_free_sectors :: proc(fsys: ^FS) {
	fsys.free_sectors = fs.alloc_cache_count_free(&fsys.vol)
}
