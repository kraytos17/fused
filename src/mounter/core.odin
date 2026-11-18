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
	lfn_cache:    lru.Cache(Lfn_Cache_Key, string),
	// extents caches resolved extent chains keyed by (data_cluster, offset).
	// Cached slices are owned by the cache; invalidated on any metadata
	// mutation (write/truncate/fallocate/unlink/xattr).
	extents:      map[Extent_Cache_Key][]fs.Extent_Run,
	// free_sectors caches the volume's free sector count so statfs is O(1).
	free_sectors: u64,
	// locks holds POSIX fcntl region locks per file (in-memory, advisory).
	locks:        map[fs.File_Identity][dynamic]Region_Lock,
	// open_files maps table fhs (see Open_File) to entry identities.
	// Inserted by open/create, removed by release, re-pointed by rename.
	open_files:   map[u64]Open_File,
	// next_fh is the monotonic counter backing open_files keys (never 0).
	next_fh:      u64,
	// trace, when non-nil, receives one JSONL event per FUSE callback
	// (see trace.odin). Nil by default so untraced mounts — including
	// all unit-test FS instances — pay a single branch per callback.
	trace:        ^Trace_Sink,
	// flock_locks holds BSD flock holders per file (in-memory, advisory).
	flock_locks:  map[fs.File_Identity][dynamic]Flock_State,
	// used_entries is the live inode count (existing .Exists entries,
	// root excluded): incremented on create/mkdir/symlink/mknod success,
	// decremented by remove_directory_entry after the cleared entry
	// persists. Seeded at mount by a tree walk (fs.count_tree_entries);
	// statfs reports f_ffree = capacity - used,
	used_entries: u64,
}

// Extent_Cache_Key identifies a resolved extent chain by its start cluster and
// sector offset within that cluster.
Extent_Cache_Key :: struct {
	cluster: u64,
	offset:  u16,
}

// Lfn_Cache_Key identifies a cached long filename by its directory and
// chain-relative entry index. It is a struct, not a packed integer:
// packing (cluster, offset, index) into a u64 collides once the entry
// index exceeds the offset field (directories can hold more than 2^16
// entries — there is no directory-size cap), handing back the wrong name
// on lookup. Chain-relative index is the stable identity (slots never
// shift), so no sector arithmetic is needed to name an entry.
Lfn_Cache_Key :: struct {
	dir:   fs.Chain_Location,
	index: int,
}

// get_fs retrieves the FS pointer from the FUSE context's private_data.
get_fs :: #force_inline proc "contextless" () -> ^FS {
	return (^FS)(fuse3.fuse_get_context().private_data)
}

// begin_op locks the mutex exclusively, resets the temp allocator, sets the
// logger, and returns the FS pointer. Must be paired with end_op. Use for
// callbacks that mutate shared state (caches, lock tables, free count).
// NOTE: `context` does not propagate upward to callers, so assignments here
// only affect this frame. Anything stored into shared structures must name
// its allocator explicitly (fsys.allocator), never rely on context. The
// `context.logger` assignment below is likewise callee-local: every caller
// must repeat `context.logger = fsys.logger` after the call, or debugf in
// its own frame goes nowhere.
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
// logger, and returns the FS pointer.
// Must be paired with end_read_op. Use for read-only callbacks: while the
// shared lock is held, touch shared state only through non-mutating access (lru.peek, snapshot helpers that
// upgrade internally). Never insert into or clear a cache while shared-held
// except through an upgrade helper (resolve_extents_shared,
// lfn_lookup_shared), which releases shared, takes exclusive, re-checks,
// and re-takes shared before returning. Like begin_op, the logger
// assignment inside is callee-local: callers must repeat
// `context.logger = fsys.logger` after the call.
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

// checked_offset converts a FUSE byte offset, rejecting negatives that
// would wrap on u64 conversion. Kernel syscalls never deliver negatives
// (rejected in VFS), so this is defense-in-depth at the trust boundary,
// matching the overflow guards on off+size spans.
checked_offset :: proc(off: posix.off_t) -> (uoff: u64, ok: bool) {
	if off < 0 {
		return 0, false
	}
	return u64(off), true
}

// fs_error_to_errno translates an FS_Error to a POSIX errno value.
// Keep in sync with `FS_Error` in src/fs/structure.odin.
@(require_results)
fs_error_to_errno :: proc(err: fs.FS_Error) -> c.int {
	switch err {
	case .None:
		return 0
	case .Entry_Not_Found:
		return -c.int(posix.ENOENT)
	case .Not_A_Directory:
		return -c.int(posix.ENOTDIR)
	case .Not_A_File:
		return -c.int(posix.EISDIR)
	case .Name_Too_Long:
		return -c.int(posix.ENAMETOOLONG)
	case .No_Space, .Cluster_Map_Full:
		return -c.int(posix.ENOSPC)
	case .Sector_Read_Error,
	     .Sector_Write_Error,
	     .Cluster_Not_Found,
	     .Multi_Sector_Cluster_Map_Unsupported,
	     .Invalid_Signature,
	     .Version_Too_Old,
	     .Version_Too_New,
	     .Feature_Not_Supported,
	     .Corrupt_Master_Record,
	     .Corrupt_XAttr_Blob:
		return -c.int(posix.EIO)
	}
	unreachable()
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

// Open_File names one open file description: the entry identity it was
// opened from. The fh handed to the kernel is a monotonic id into
// FS.open_files, never a packed slot, so a cross-directory rename can
// re-point live handles instead of stranding them on the cleared old
// slot (E-04 step 1). Removal sweeps handles naming the entry
// (open_handle_sweep), so a later reuse of the freed slot cannot resurrect
// a stale fd onto a different file: unlinked-but-open handles fail closed
// (ENOENT). True orphan-inode persistence (keep the chain alive until last
// close) needs the on-disk orphan list, E-04 full.
Open_File :: struct {
	id: fs.File_Identity,
}

// open_handle_insert registers an opened entry and returns its table fh
// (never 0; the kernel treats 0 as "no handle" in some paths).
open_handle_insert :: proc(fsys: ^FS, id: fs.File_Identity) -> u64 {
	fsys.next_fh += 1
	if fsys.next_fh == 0 {
		fsys.next_fh = 1
	}

	fsys.open_files[fsys.next_fh] = Open_File {
		id = id,
	}
	return fsys.next_fh
}

// open_loc resolves a table fh to its current identity. Unknown (stale)
// handles fail closed: the entry they named is gone.
open_loc :: proc(fsys: ^FS, fh: u64) -> (loc: fs.File_Identity, ok: bool) {
	if of, hit := fsys.open_files[fh]; hit {
		return of.id, true
	}
	return {}, false
}

// open_handle_remove drops a table entry, returning its last identity.
open_handle_remove :: proc(fsys: ^FS, fh: u64) -> (loc: fs.File_Identity, ok: bool) {
	if of, hit := fsys.open_files[fh]; hit {
		delete_key(&fsys.open_files, fh)
		return of.id, true
	}
	return {}, false
}

// open_handle_repoint moves every open handle (and the lock tables, which
// are keyed by identity) from an old slot to a new one after a
// cross-directory rename. Same-slot renames never call this (the identity
// does not change when only the name does).
open_handle_repoint :: proc(fsys: ^FS, old, new: fs.File_Identity) {
	if old == new {
		return
	}

	moved: [dynamic]u64
	defer delete(moved)
	for fh, of in fsys.open_files {
		if of.id == old {
			append(&moved, fh)
		}
	}
	for fh in moved {
		fsys.open_files[fh] = Open_File {
			id = new,
		}
	}
	// Lock state follows the file, not the slot: the overwritten
	// destination's locks were already dropped by remove_directory_entry,
	// so a plain move cannot collide.
	if recs, ok := fsys.locks[old]; ok {
		delete_key(&fsys.locks, old)
		fsys.locks[new] = recs
	}
	if fls, ok := fsys.flock_locks[old]; ok {
		delete_key(&fsys.flock_locks, old)
		fsys.flock_locks[new] = fls
	}
}

// open_handle_swap exchanges the identity of every open handle and lock
// record between two slots (RENAME_EXCHANGE): the content moved slots in
// both directions simultaneously, so fds and advisory locks follow the
// content, not the path. Collect-then-apply: mutating map values during
// range is legal, but two swaps in one pass need both lists first.
open_handle_swap :: proc(fsys: ^FS, a, b: fs.File_Identity) {
	if a == b {
		return
	}

	fhs_a: [dynamic]u64
	fhs_b: [dynamic]u64

	defer delete(fhs_a)
	defer delete(fhs_b)
	for fh, of in fsys.open_files {
		if of.id == a {
			append(&fhs_a, fh)
		} else if of.id == b {
			append(&fhs_b, fh)
		}
	}
	for fh in fhs_a {
		fsys.open_files[fh] = Open_File {
			id = b,
		}
	}
	for fh in fhs_b {
		fsys.open_files[fh] = Open_File {
			id = a,
		}
	}

	// Advisory locks follow the content too (they are per-file state).
	recs_a, has_a := fsys.locks[a]
	recs_b, has_b := fsys.locks[b]
	delete_key(&fsys.locks, a)
	delete_key(&fsys.locks, b)

	if has_a { fsys.locks[b] = recs_a }
	if has_b { fsys.locks[a] = recs_b }

	fls_a, fl_has_a := fsys.flock_locks[a]
	fls_b, fl_has_b := fsys.flock_locks[b]
	delete_key(&fsys.flock_locks, a)
	delete_key(&fsys.flock_locks, b)

	if fl_has_a { fsys.flock_locks[b] = fls_a }
	if fl_has_b { fsys.flock_locks[a] = fls_b }
}

// open_handle_sweep drops every open handle naming a removed entry, so a
// later reuse of the freed slot cannot resurrect a stale fd onto a
// different file (ABA). Unlinked-but-open handles therefore fail closed
// (ENOENT) instead of operating on the new occupant; true orphan-inode
// persistence (keep the chain alive until last close) needs the on-disk
// orphan list, E-04 full.
open_handle_sweep :: proc(fsys: ^FS, dead: fs.File_Identity) {
	dropped: [dynamic]u64
	defer delete(dropped)
	for fh, of in fsys.open_files {
		if of.id == dead {
			append(&dropped, fh)
		}
	}
	for fh in dropped {
		delete_key(&fsys.open_files, fh)
	}
}

// Mutate_Request bundles the inputs to mutate_entry_at: the target path,
// the FUSE file info, the caller-provided mutation with its user context,
// and whether caches invalidate wholesale. Callers spell every field
// (there are no struct defaults); invalidate_all=true preserves the old
// default at the chmod/chown sites.
Mutate_Request :: struct {
	path:           cstring,
	fi:             ^fuse3.File_Info,
	mutate:         proc(entry: ^fs.Directory_Entry, user: rawptr) -> bool,
	user:           rawptr,
	invalidate_all: bool,
}

// mutate_entry_at is the shared read-modify-write wrapper for metadata-only
// FUSE callbacks that update a single directory entry (chmod, chown,
// utimens, and xattr entry writes). It resolves the entry, calls mutate
// with the caller-provided user context, writes it back, and invalidates
// caches. mutate returning false skips the write without error. When
// invalidate_all is false only the single path is removed (used by utimens,
// where the directory structure hasn't changed).
mutate_entry_at :: proc(fsys: ^FS, req: Mutate_Request) -> c.int {
	entry, entry_cluster, entry_offset, entry_idx, _, _, rerr := resolve_entry(
		fsys,
		req.path,
		req.fi,
	)

	if rerr != .None {
		return fs_error_to_errno(rerr)
	}
	if !req.mutate(&entry, req.user) {
		return 0
	}
	if werr := write_entry_at(
		fsys,
		fs.File_Identity{entry_cluster, entry_offset, entry_idx},
		&entry,
	); werr != .None {
		return fs_error_to_errno(werr)
	}
	if req.invalidate_all {
		path_cache_invalidate_all(fsys)
	} else {
		lru.remove(&fsys.path_cache, string(req.path))
	}
	return 0
}

// read_entry_from_fh reads a Directory_Entry through the open-file table,
// returning the entry, its data cluster, and its data offset. Unknown or
// unlinked handles fail as Entry_Not_Found (fail closed, never a wrong
// file); I/O errors propagate as FS_Error instead of collapsing to ENOENT
// at call sites.
read_entry_from_fh :: proc(
	fsys: ^FS,
	fh: u64,
) -> (
	fs.Directory_Entry,
	fs.Cluster,
	fs.Sector_Offset,
	fs.FS_Error,
) {
	id, ok := open_loc(fsys, fh)
	if !ok {
		return {}, 0, 0, .Entry_Not_Found
	}

	e, err := fs.read_entry_at_index(&fsys.vol, id)
	if err != .None {
		return {}, 0, 0, err
	}
	return e, fs.Cluster(e.stored_cluster), fs.Sector_Offset(e.sector_index), .None
}

// Path_Cache_Value holds a cached path resolution result.
Path_Cache_Value :: struct {
	entry:       fs.Directory_Entry,
	cluster:     fs.Cluster,
	offset:      fs.Sector_Offset,
	entry_index: int,
}

// path_cache_on_remove is the LRU eviction callback for the path cache.
// Keys are cloned with fsys.allocator at insert; the allocator rides along
// as user_data (see init_fs_state) so eviction frees with the same
// allocator regardless of the evicting caller's context.
path_cache_on_remove :: proc(key: string, val: Path_Cache_Value, user_data: rawptr) {
	fsys := (^FS)(user_data)
	if fsys != nil {
		delete(key, fsys.allocator)
	} else {
		delete(key)
	}
}

// lfn_cache_on_remove is the LRU eviction callback for the LFN cache.
// Same allocator discipline as path_cache_on_remove.
lfn_cache_on_remove :: proc(key: Lfn_Cache_Key, val: string, user_data: rawptr) {
	fsys := (^FS)(user_data)
	if fsys != nil {
		delete(val, fsys.allocator)
	} else {
		delete(val)
	}
}

// lfn_cache_key builds the cache key for an entry's long filename from its
// directory and chain-relative entry index. See Lfn_Cache_Key for why the
// key is a struct rather than a packed integer.
@(require_results)
lfn_cache_key :: #force_inline proc(dir: fs.Chain_Location, index: int) -> Lfn_Cache_Key {
	return {dir, index}
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
	key: Lfn_Cache_Key,
	vol: ^fs.Volume,
	entry: ^fs.Directory_Entry,
) -> (
	name: string,
	ok: bool,
) {
	if cached, hit := lru.peek(&fsys.lfn_cache, key); hit {
		// A failed temp clone must fail the lookup, not hand back an
		// empty string as a valid name (fail-closed).
		out, cerr := strings.clone(cached, context.temp_allocator)
		if cerr != .None {
			return "", false
		}
		return out, true
	}

	sync.rw_mutex_shared_unlock(&fsys.mu)
	sync.rw_mutex_lock(&fsys.mu)
	if cached, hit := lru.peek(&fsys.lfn_cache, key); hit {
		out, cerr := strings.clone(cached, context.temp_allocator)
		if cerr != .None {
			sync.rw_mutex_unlock(&fsys.mu)
			sync.rw_mutex_shared_lock(&fsys.mu)
			return "", false
		}

		sync.rw_mutex_unlock(&fsys.mu)
		sync.rw_mutex_shared_lock(&fsys.mu)
		return out, true
	}

	lfn, l_ok := fs.resolve_lfn(vol, entry, context.temp_allocator)
	if l_ok {
		c, cerr := strings.clone(lfn, fsys.allocator)
		if cerr == .None && c != "" {
			if lru.set(&fsys.lfn_cache, key, c) != nil {
				delete(c, fsys.allocator)
			}
		}
	}

	sync.rw_mutex_unlock(&fsys.mu)
	sync.rw_mutex_shared_lock(&fsys.mu)
	if !l_ok {
		return "", false
	}
	if cached, hit := lru.peek(&fsys.lfn_cache, key); hit {
		out, cerr := strings.clone(cached, context.temp_allocator)
		if cerr != .None {
			return "", false
		}
		return out, true
	}
	return lfn, true
}

// path_cache_get retrieves a cached path resolution.
path_cache_get :: proc(fsys: ^FS, path: string) -> (Path_Cache_Value, bool) {
	return lru.get(&fsys.path_cache, path)
}

// PATH_CACHE_MAX_BYTES caps the path length admitted to the path cache.
// Paths longer than this are still resolved, just never cached. This is a
// byte-length limit, distinct from Cache_Config.path_cap (entry count).
PATH_CACHE_MAX_BYTES :: 256

// path_cache_put stores a path resolution in the cache. Paths longer than
// PATH_CACHE_MAX_BYTES are not cached. The key is cloned with fsys.allocator
// and freed in path_cache_on_remove with the same allocator.
path_cache_put :: proc(fsys: ^FS, path: string, val: Path_Cache_Value) {
	if len(path) > PATH_CACHE_MAX_BYTES {
		return
	}

	key, kerr := strings.clone(path, fsys.allocator)
	if kerr != .None {
		return
	}
	lru.set(&fsys.path_cache, key, val)
}

// path_cache_invalidate_all clears the path cache, LFN cache, and extent cache.
path_cache_invalidate_all :: proc(fsys: ^FS) {
	lru.clear(&fsys.path_cache, true)
	lru.clear(&fsys.lfn_cache, true)
	extent_cache_invalidate_all(fsys)
}

// resolve_path_cached resolves a path using the LRU path cache. On a miss the
// result is resolved and cached. Lookup errors propagate as FS_Error.
resolve_path_cached :: proc(
	fsys: ^FS,
	path: string,
	allocator := context.allocator,
) -> (
	entry: fs.Directory_Entry,
	cluster: fs.Cluster,
	offset: fs.Sector_Offset,
	entry_index: int,
	err: fs.FS_Error,
) {
	if val, hit := path_cache_get(fsys, path); hit {
		return val.entry, val.cluster, val.offset, val.entry_index, .None
	}

	res, rerr := fs.resolve_path(&fsys.vol, path, allocator)
	if rerr == .None {
		path_cache_put(fsys, path, {res.entry, res.cluster, res.offset, res.entry_index})
	}
	return res.entry, res.cluster, res.offset, res.entry_index, rerr
}

// resolve_entry resolves a path or a file handle to a Directory_Entry, its
// directory cluster/offset/index, and its data cluster/offset. Lookup
// errors propagate as FS_Error.
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
	err: fs.FS_Error,
) {
	if fi != nil {
		e, dc, ddo, rerr := read_entry_from_fh(fsys, fi.fh)
		if rerr != .None { return {}, 0, 0, 0, 0, 0, rerr }

		id, ok := open_loc(fsys, fi.fh)
		if !ok { return {}, 0, 0, 0, 0, 0, .Entry_Not_Found }
		return e, id.dir_cluster, id.dir_offset, id.entry_index, dc, ddo, .None
	}

	e, c, o, i, rerr := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if rerr != .None { return {}, 0, 0, 0, 0, 0, rerr }
	return e, c, o, i, fs.Cluster(e.stored_cluster), fs.Sector_Offset(e.sector_index), .None
}

// init_fs_for_test builds an FS for direct callback unit testing (no live FUSE
// mount). The caller installs it as the FUSE context private_data via
// fuse3.set_test_context, and must call destroy_fs_for_test when done.
// Takes fsys by pointer (not by value) because the caches store a
// back-pointer to fsys as their on_remove user_data; returning by value
// would leave that pointer dangling at the callee frame after the copy.
init_fs_for_test :: proc(
	fsys: ^FS,
	vol: fs.Volume,
	allocator := context.allocator,
	cache := fs.DEFAULT_CACHE_CONFIG,
) {
	fsys.vol = vol
	fsys.disk_raw_fd = c.int(os.fd(vol.disk))
	fsys.logger = log.Logger{}
	if fi, err := os.fstat(vol.disk, context.temp_allocator); err == nil {
		fsys.vol.image_size = fs.Byte_Offset(u64(fi.size))
	}
	init_fs_state(fsys, allocator, cache)
}

// init_fs_state initialises the caches, lock tables, and free-sector count
// shared by the FUSE daemon (run) and the test harness (init_fs_for_test).
// fsys.vol must already be set.
init_fs_state :: proc(
	fsys: ^FS,
	allocator := context.allocator,
	cache := fs.DEFAULT_CACHE_CONFIG,
) {
	fsys.allocator = allocator
	path_cap := cache.path_cap if cache.path_cap > 0 else fs.DEFAULT_CACHE_CONFIG.path_cap
	lfn_cap := cache.lfn_cap if cache.lfn_cap > 0 else fs.DEFAULT_CACHE_CONFIG.lfn_cap
	lru.init(&fsys.path_cache, path_cap, allocator, allocator)
	fsys.path_cache.on_remove = path_cache_on_remove
	fsys.path_cache.on_remove_user_data = fsys
	lru.init(&fsys.lfn_cache, lfn_cap, allocator, allocator)
	fsys.lfn_cache.on_remove = lfn_cache_on_remove
	fsys.lfn_cache.on_remove_user_data = fsys

	fsys.extents = make(map[Extent_Cache_Key][]fs.Extent_Run, allocator)
	fsys.free_sectors = fs.alloc_cache_count_free(&fsys.vol)
	fsys.locks = make(map[fs.File_Identity][dynamic]Region_Lock, allocator)
	fsys.flock_locks = make(map[fs.File_Identity][dynamic]Flock_State, allocator)
	fsys.open_files = make(map[u64]Open_File, allocator)
	fsys.next_fh = 0
	// seed the inode counter from a fresh tree walk. On a walk
	// error (corrupt image) keep 0 and let the checker own the diagnosis;
	// statfs then over-reports free inodes rather than blocking mount.
	fsys.used_entries = 0
	if n, cerr := fs.count_tree_entries(&fsys.vol); cerr == .None {
		fsys.used_entries = n
	}
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
	delete(fsys.open_files)
	lru.destroy(&fsys.path_cache, true)
	lru.destroy(&fsys.lfn_cache, true)
	fsys^ = {}
}

// resolve_extents_cached resolves an extent chain, caching the result so
// repeated reads/writes on the same file skip the metadata walk.  The returned
// slice is owned by the cache — callers must NOT delete it.  Caller must hold
// the WRITE lock (begin_op): the lookup may insert, and the borrowed slice
// is only valid until the next invalidation, which also requires the lock.
// Resolution failures propagate as FS_Error; each boundary maps them to the
// errno its path already reported (lseek/read ENOENT, bmap/readlink EIO).
resolve_extents_cached :: proc(
	fsys: ^FS,
	loc: fs.Chain_Location,
) -> (
	runs: []fs.Extent_Run,
	err: fs.FS_Error,
) {
	key := Extent_Cache_Key{u64(loc.cluster), u16(loc.offset)}
	if cached, hit := fsys.extents[key]; hit {
		return cached, .None
	}

	r := fs.resolve_extents(&fsys.vol, loc) or_return
	slice_copy, cerr := slice.clone(r[:], fsys.allocator)
	if cerr != .None {
		delete(r)
		return nil, .No_Space
	}

	delete(r)
	fsys.extents[key] = slice_copy
	return slice_copy, .None
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
	loc: fs.Chain_Location,
) -> (
	runs: []fs.Extent_Run,
	err: fs.FS_Error,
) {
	key := Extent_Cache_Key{u64(loc.cluster), u16(loc.offset)}
	if cached, hit := fsys.extents[key]; hit {
		out, oerr := slice.clone(cached, context.temp_allocator)
		if oerr != .None {
			return nil, .No_Space
		}
		return out, .None
	}

	sync.rw_mutex_shared_unlock(&fsys.mu)
	sync.rw_mutex_lock(&fsys.mu)
	if cached, hit := fsys.extents[key]; hit {
		out, oerr := slice.clone(cached, context.temp_allocator)
		if oerr != .None {
			sync.rw_mutex_unlock(&fsys.mu)
			sync.rw_mutex_shared_lock(&fsys.mu)
			return nil, .No_Space
		}

		sync.rw_mutex_unlock(&fsys.mu)
		sync.rw_mutex_shared_lock(&fsys.mu)
		return out, .None
	}

	r, rerr := fs.resolve_extents(&fsys.vol, loc)
	if rerr != .None {
		sync.rw_mutex_unlock(&fsys.mu)
		sync.rw_mutex_shared_lock(&fsys.mu)
		return nil, rerr
	}

	slice_copy, cerr := slice.clone(r[:], fsys.allocator)
	if cerr != .None {
		delete(r)
		sync.rw_mutex_unlock(&fsys.mu)
		sync.rw_mutex_shared_lock(&fsys.mu)
		return nil, .No_Space
	}

	delete(r)
	fsys.extents[key] = slice_copy
	out, oerr := slice.clone(slice_copy, context.temp_allocator)
	if oerr != .None {
		sync.rw_mutex_unlock(&fsys.mu)
		sync.rw_mutex_shared_lock(&fsys.mu)
		return nil, .No_Space
	}

	sync.rw_mutex_unlock(&fsys.mu)
	sync.rw_mutex_shared_lock(&fsys.mu)
	return out, .None
}

// extent_cache_invalidate_all drops every cached extent chain.  Call after any
// metadata mutation that can change a chain (write, truncate, fallocate,
// unlink, rmdir, rename, xattr store/clear).  Do NOT call while borrowed
// slices from this cache are still in use.
extent_cache_invalidate_all :: proc(fsys: ^FS) {
	for _, runs in fsys.extents {
		delete(runs, fsys.allocator)
	}

	delete(fsys.extents)
	fsys.extents = make(map[Extent_Cache_Key][]fs.Extent_Run, fsys.allocator)
}

// extent_cache_invalidate drops a single cached chain.  Use when a mutation
// affects only one chain so other borrowed cached slices stay valid.
extent_cache_invalidate_one :: proc(fsys: ^FS, cluster: fs.Cluster, offset: fs.Sector_Offset) {
	key := Extent_Cache_Key{u64(cluster), u16(offset)}
	if runs, ok := fsys.extents[key]; ok {
		delete(runs, fsys.allocator)
		delete_key(&fsys.extents, key)
	}
}

// extent_cache_invalidate drops cached extent chains: a single chain by
// (cluster, offset), or every chain. Overload resolves on arity, so existing
// call sites read unchanged.
extent_cache_invalidate :: proc {
	extent_cache_invalidate_one,
	extent_cache_invalidate_all,
}

// reinit_free_sectors recomputes the cached free-sector count from the volume.
// Used after deallocation where the exact freed count isn't tracked.
reinit_free_sectors :: proc(fsys: ^FS) {
	fsys.free_sectors = fs.alloc_cache_count_free(&fsys.vol)
}
