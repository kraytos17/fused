// core.odin — Shared infrastructure for the FUSE callbacks.
//
// Every callback retrieves its FS state via fuse_get_context().private_data
// (the get_fs() helper), eliminating package-level globals.
#+build linux
package mounter

import "core:c"
import "core:container/lru"
import "core:log"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"
import "src:fuse3"
import "src:fs"

// get_dir_entry returns a pointer to the Directory_Entry at the given index
// within a sector-sized buffer.
get_dir_entry :: #force_inline proc(buf: []u8, index: int, features: fs.Features) -> ^fs.Directory_Entry {
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
	vol:         fs.Volume,
	// disk_raw_fd is the raw file descriptor for the disk image, used for
	// zero-copy splice I/O.
	disk_raw_fd: c.int,
	// logger is the per-mount logger instance.
	logger:      log.Logger,
	// mu serialises access to the volume and caches.
	mu:          sync.Mutex,
	// path_cache is an LRU cache mapping path strings to resolved entries.
	path_cache:  lru.Cache(string, Path_Cache_Value),
	// lfn_cache is an LRU cache mapping (cluster,offset,index) to long
	// file names.
	lfn_cache:   lru.Cache(u64, string),
}

// get_fs retrieves the FS pointer from the FUSE context's private_data.
get_fs :: #force_inline proc "contextless" () -> ^FS {
	return (^FS)(fuse3.fuse_get_context().private_data)
}

// begin_op locks the mutex, resets the temp allocator, sets the logger, and
// returns the FS pointer. Must be paired with end_op.
begin_op :: proc () -> ^FS {
	fsys := get_fs()
	free_all(context.temp_allocator)
	context.logger = fsys.logger
	sync.mutex_lock(&fsys.mu)
	return fsys
}

// end_op unlocks the mutex.
end_op :: proc (fsys: ^FS) {
	sync.mutex_unlock(&fsys.mu)
}

// fs_error_to_errno translates an FS_Error to a POSIX errno value.
// Unknown errors fall through to EIO.
fs_error_to_errno :: proc(err: fs.FS_Error) -> c.int {
	#partial switch err {
	case .None:                return 0
	case .Entry_Not_Found:     return -c.int(posix.ENOENT)
	case .Not_A_Directory:     return -c.int(posix.ENOTDIR)
	case .Name_Too_Long:       return -c.int(posix.ENAMETOOLONG)
	case .No_Space:            return -c.int(posix.ENOSPC)
	case .Sector_Read_Error,
	     .Sector_Write_Error:  return -c.int(posix.EIO)
	case:                      return -c.int(posix.EIO)
	}
}

UTIME_NOW  :: 1073741822
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
@private
_set_time_fields :: proc(year: ^u16, dt: ^fs.Packed_Date_Time, sec: i64) {
	t := time.unix(sec, 0)
	y, mo, d := time.date(t)
	h, m, s := time.clock(t)
	year^ = u16(y)
	dt^ = fs.Packed_Date_Time{month = u32(int(mo)), date = u32(d), hour = u32(h), minute = u32(m), second = u32(s)}
}

// _set_time_fields_now writes the current wall-clock time into the given
// date/time fields.
@private
_set_time_fields_now :: proc(year: ^u16, dt: ^fs.Packed_Date_Time) {
	now := time.now()
	y, mo, d := time.date(now)
	h, m, s := time.clock(now)
	year^ = u16(y)
	dt^ = fs.Packed_Date_Time{month = u32(int(mo)), date = u32(d), hour = u32(h), minute = u32(m), second = u32(s)}
}

// read_entry_from_fh reads a Directory_Entry from a packed File_Handle,
// returning the entry, its data cluster, data offset, and whether it succeeded.
read_entry_from_fh :: proc(fsys: ^FS, fh: u64) -> (fs.Directory_Entry, fs.Cluster, fs.Sector_Offset, bool) {
	fh_packed := transmute(fs.File_Handle)(fh)
	runs, ext_err := fs.resolve_extents(&fsys.vol,fs.Cluster(fh_packed.dir_cluster), fs.Sector_Offset(fh_packed.dir_offset))
	defer delete(runs)
	if ext_err != .None {
		return {}, 0, 0, false
	}

	depc := dir_entries_per_buf(fsys.vol.master.features)
	remaining := int(fh_packed.entry_index)
	buf: [fs.SECTOR_SIZE]u8
	for run in runs {
		n := int(run.count)
		for si in 0 ..< n {
			if remaining < depc {
				sec := fs.Sector(u64(run.sector) + u64(si))
				if !fs.sector_read(&fsys.vol, sec, buf[:]) {
					return {}, 0, 0, false
				}

				e := get_dir_entry(buf[:], remaining, fsys.vol.master.features)^
				if .Exists not_in e.flags {
					return {}, 0, 0, false
				}
				return e, fs.Cluster(e.stored_cluster), fs.Sector_Offset(e.sector_index), true
			}
			remaining -= depc
		}
	}
	return {}, 0, 0, false
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
lfn_cache_key :: #force_inline proc(cluster: fs.Cluster, offset: fs.Sector_Offset, index: int) -> u64 {
	return (u64(cluster) << 32) | (u64(offset) << 16) | u64(index)
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

// path_cache_invalidate_all clears both the path cache and the LFN cache.
path_cache_invalidate_all :: proc(fsys: ^FS) {
	lru.clear(&fsys.path_cache, true)
	lru.clear(&fsys.lfn_cache, true)
}

// resolve_path_cached resolves a path using the LRU path cache. On a miss the
// result is resolved and cached.
resolve_path_cached :: proc(fsys: ^FS, path: string, allocator := context.allocator) -> (
	entry:       fs.Directory_Entry,
	cluster:     fs.Cluster,
	offset:      fs.Sector_Offset,
	entry_index: int,
	ok:          bool,
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

// resolve_path resolves a path without caching. Wraps fs.resolve_path.
resolve_path :: proc(fsys: ^FS, path: string, allocator := context.allocator) -> (
	entry:       fs.Directory_Entry,
	cluster:     fs.Cluster,
	offset:      fs.Sector_Offset,
	entry_index: int,
	ok:          bool,
) {
	res, res_ok := fs.resolve_path(&fsys.vol, path, allocator)
	return res.entry, res.cluster, res.offset, res.entry_index, res_ok
}

// resolve_entry resolves a path or a file handle to a Directory_Entry, its
// directory cluster/offset/index, and its data cluster/offset.
resolve_entry :: proc(fsys: ^FS, path: cstring, fi: ^fuse3.File_Info) -> (
	entry: fs.Directory_Entry, entry_cluster: fs.Cluster, entry_offset: fs.Sector_Offset,
	entry_idx: int, data_cluster: fs.Cluster, data_offset: fs.Sector_Offset, ok: bool,
) {
	if fi != nil {
		fh := transmute(fs.File_Handle)(fi.fh)
		e, dc, ddo, rok := read_entry_from_fh(fsys, fi.fh)
		if !rok { return {}, 0, 0, 0, 0, 0, false }
		return e, fs.Cluster(fh.dir_cluster), fs.Sector_Offset(fh.dir_offset), int(fh.entry_index), dc, ddo, true
	}

	e, c, o, i, rok := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if !rok { return {}, 0, 0, 0, 0, 0, false }
	return e, c, o, i, fs.Cluster(e.stored_cluster), fs.Sector_Offset(e.sector_index), true
}
