// ops.odin — FUSE callbacks for the fused filesystem.
//
// Every callback retrieves its FS state via fuse_get_context().private_data
// (the get_fs() helper), eliminating package-level globals.
#+build linux
package main

import "base:runtime"
import "core:c"
import "core:container/lru"
import "core:log"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"
import "src:fuse3"
import "src:fs"

get_dir_entry :: #force_inline proc(buf: []u8, index: int, features: u64) -> ^fs.Directory_Entry {
	des := int(fs.dir_entry_size(transmute(fs.Features)features))
	return (^fs.Directory_Entry)(mem.ptr_offset(&buf[0], index * des))
}

dir_entries_per_buf :: #force_inline proc(features: u64) -> int {
	return int(fs.dir_entries_per_sector(transmute(fs.Features)features))
}

// FS is the per-mount filesystem state, passed as fuse user_data.
FS :: struct {
	disk:        ^os.File,
	disk_raw_fd: c.int,
	master:      fs.Master_Record,
	logger:      log.Logger,
	image_size:  u64,
	mu:          sync.Mutex,
	path_cache:  lru.Cache(string, Path_Cache_Value),
	lfn_cache:   lru.Cache(u64, string),
	alloc_cache: fs.Cluster_Bitmap_Cache,
	lfn_bump:    LFN_Bump,
}

LFN_Bump :: struct {
	active:     bool,
	cluster:    fs.Cluster,
	offset:     fs.Sector_Offset,
	sector:     fs.Sector,
	next_byte:  u16,
}

get_fs :: #force_inline proc "contextless" () -> ^FS {
	return (^FS)(fuse3.fuse_get_context().private_data)
}

UTIME_NOW  :: 1073741822
UTIME_OMIT :: 1073741823

set_entry_time_from_unix :: proc(entry: ^fs.Directory_Entry, sec: i64) {
	_set_time_fields(&entry.year, &entry.date_time, sec)
	_set_time_fields(&entry.atime_year, &entry.atime_date_time, sec)
}

set_entry_time_to_now :: proc(entry: ^fs.Directory_Entry) {
	_set_time_fields_now(&entry.year, &entry.date_time)
	_set_time_fields_now(&entry.atime_year, &entry.atime_date_time)
}

set_entry_mtime_from_unix :: proc(entry: ^fs.Directory_Entry, sec: i64) {
	_set_time_fields(&entry.year, &entry.date_time, sec)
}

set_entry_atime_from_unix :: proc(entry: ^fs.Directory_Entry, sec: i64) {
	_set_time_fields(&entry.atime_year, &entry.atime_date_time, sec)
}

set_entry_mtime_to_now :: proc(entry: ^fs.Directory_Entry) {
	_set_time_fields_now(&entry.year, &entry.date_time)
}

set_entry_atime_to_now :: proc(entry: ^fs.Directory_Entry) {
	_set_time_fields_now(&entry.atime_year, &entry.atime_date_time)
}

@private
_set_time_fields :: proc(year: ^u16, dt: ^fs.Packed_Date_Time, sec: i64) {
	t := time.unix(sec, 0)
	y, mo, d := time.date(t)
	h, m, s := time.clock(t)
	year^ = u16(y)
	dt^ = fs.Packed_Date_Time{month = u32(int(mo)), date = u32(d), hour = u32(h), minute = u32(m), second = u32(s)}
}

@private
_set_time_fields_now :: proc(year: ^u16, dt: ^fs.Packed_Date_Time) {
	now := time.now()
	y, mo, d := time.date(now)
	h, m, s := time.clock(now)
	year^ = u16(y)
	dt^ = fs.Packed_Date_Time{month = u32(int(mo)), date = u32(d), hour = u32(h), minute = u32(m), second = u32(s)}
}

unpack_fh :: proc(fh: u64) -> (fs.Cluster, fs.Sector_Offset, int) {
	return fs.Cluster(fh >> 32), fs.Sector_Offset((fh >> 16) & 0xFFFF), int(fh & 0xFFFF)
}

read_entry_from_fh :: proc(fsys: ^FS, fh: u64) -> (fs.Directory_Entry, fs.Cluster, fs.Sector_Offset, bool) {
	pc, po, idx := unpack_fh(fh)
	if idx < 0 {
		return {}, 0, 0, false
	}

	runs, runs_ok := fs.resolve_extents(fsys.disk, &fsys.master, pc, po)
	if !runs_ok {
		return {}, 0, 0, false
	}

	depc := dir_entries_per_buf(fsys.master.features)
	remaining := idx
	buf: [fs.SECTOR_SIZE]u8
	for run in runs {
		n := int(run.count)
		for si in 0 ..< n {
			if remaining < depc {
				sec := fs.Sector(u64(run.sector) + u64(si))
				if !fs.sector_read(fsys.disk, sec, buf[:]) {
					return {}, 0, 0, false
				}

				e := get_dir_entry(buf[:], remaining, fsys.master.features)^
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

Path_Cache_Value :: struct {
	entry:       fs.Directory_Entry,
	cluster:     fs.Cluster,
	offset:      fs.Sector_Offset,
	entry_index: int,
}

path_cache_on_remove :: proc(key: string, val: Path_Cache_Value, user_data: rawptr) {
	delete(key)
}

lfn_cache_on_remove :: proc(key: u64, val: string, user_data: rawptr) {
	delete(val)
}

lfn_cache_key :: #force_inline proc(cluster: fs.Cluster, offset: fs.Sector_Offset, index: int) -> u64 {
	return (u64(cluster) << 32) | (u64(offset) << 16) | u64(index)
}

path_cache_get :: proc(fsys: ^FS, path: string) -> (Path_Cache_Value, bool) {
	return lru.get(&fsys.path_cache, path)
}

path_cache_put :: proc(fsys: ^FS, path: string, val: Path_Cache_Value) {
	if len(path) > 256 {
		return
	}
	key := strings.clone(path, context.allocator)
	lru.set(&fsys.path_cache, key, val)
}

path_cache_invalidate_all :: proc(fsys: ^FS) {
	lru.clear(&fsys.path_cache, true)
	lru.clear(&fsys.lfn_cache, true)
}

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

	entry, cluster, offset, entry_index, ok = resolve_path(fsys, path, allocator)
	if ok {
		path_cache_put(fsys, path, {entry, cluster, offset, entry_index})
	}
	return entry, cluster, offset, entry_index, ok
}

resolve_path :: proc(fsys: ^FS, path: string, allocator := context.allocator) -> (
	entry:       fs.Directory_Entry,
	cluster:     fs.Cluster,
	offset:      fs.Sector_Offset,
	entry_index: int,
	ok:          bool,
) {
	if path == "/" || len(path) == 0 {
		entry = fs.Directory_Entry{
			flags          = fs.Dir_Flags{.Allocated, .Directory, .Exists},
			sector_index   = fsys.master.root_sector_index,
			stored_cluster = fsys.master.root_cluster,
		}
		return entry, fs.Cluster(fsys.master.root_cluster), fs.Sector_Offset(fsys.master.root_sector_index), 0, true
	}

	Component :: struct {
		start, end: int,
	}

	comps: [16]Component
	n_comps := 0
	start := 1
	i := start
	for i <= len(path) {
		if i == len(path) || path[i] == '/' {
			if i > start {
				if n_comps >= len(comps) {
					return {}, {}, {}, 0, false
				}

				comps[n_comps] = Component{start, i}
				n_comps += 1
			}
			start = i + 1
		}
		i += 1
	}
	if n_comps == 0 {
		return resolve_path(fsys, "/")
	}

	current_cluster := fs.Cluster(fsys.master.root_cluster)
	current_offset := fs.Sector_Offset(fsys.master.root_sector_index)
	for comp_idx in 0 ..< n_comps {
		target := path[comps[comp_idx].start:comps[comp_idx].end]
		is_last := comp_idx == n_comps - 1
		dirs, dirs_ok := fs.read_directory_entries(fsys.disk, &fsys.master, current_cluster, current_offset)
		defer delete(dirs)

		if !dirs_ok {
			return {}, {}, {}, 0, false
		}

		found := false
		for &d, didx in dirs {
			if fs.entry_short_name(&d) == target {
				found = true
			}
			if !found && .LFN in d.flags {
				lfn_name, lfn_ok := fs.resolve_lfn(fsys.disk, &fsys.master, &d, context.temp_allocator)
				if lfn_ok && lfn_name == target {
					found = true
				}
			}
			if found {
				if is_last {
					return d, current_cluster, current_offset, didx, true
				}
				if .Directory not_in d.flags {
					return {}, {}, {}, 0, false
				}

				current_cluster = fs.Cluster(d.stored_cluster)
				current_offset = fs.Sector_Offset(d.sector_index)
				break
			}
		}
		if !found {
			return {}, {}, {}, 0, false
		}
	}
	return {}, {}, {}, 0, false
}

@(private)
write_entry_back :: proc(fsys: ^FS, entry: ^fs.Directory_Entry, cluster: fs.Cluster, offset: fs.Sector_Offset, index: int) -> bool {
	depc := dir_entries_per_buf(fsys.master.features)
	runs, runs_ok := fs.resolve_extents(fsys.disk, &fsys.master, cluster, offset)
	if !runs_ok {
		return false
	}

	remaining := index
	for run in runs {
		n := int(run.count)
		for si in 0 ..< n {
			if remaining < depc {
				dsec := fs.Sector_Offset(u64(run.sector) + u64(si) - u64(cluster) * fsys.master.cluster_size)
				return fs.write_directory_entry_at(
					fsys.disk, &fsys.master,
					cluster, dsec,
					remaining, entry)
			}
			remaining -= depc
		}
	}
	return false
}

// find_free_slot_in_extent returns (cluster, sector_offset, entry_index) for the first
// free slot found by scanning the directory's extent chain.
// Returns ok=false when no free slot exists (caller should extend the chain).
find_free_slot_in_extent :: proc(fsys: ^FS, dir_cluster: fs.Cluster, dir_offset: fs.Sector_Offset) -> (dcluster: fs.Cluster, dsec: fs.Sector_Offset, didx: int, ok: bool) {
	depc := dir_entries_per_buf(fsys.master.features)
	dir_runs, dir_ok := fs.resolve_extents(fsys.disk, &fsys.master, dir_cluster, dir_offset)
	if !dir_ok {
		return {}, 0, 0, false
	}

	scan_buf: [fs.SECTOR_SIZE]u8
	for run in dir_runs {
		n := int(run.count)
		for si in 0 ..< n {
			sec := fs.Sector(u64(run.sector) + u64(si))
			if !fs.sector_read(fsys.disk, sec, scan_buf[:]) {
				return {}, 0, 0, false
			}
			for i in 0 ..< depc {
				zero_flags: fs.Dir_Flags
				if get_dir_entry(scan_buf[:], i, fsys.master.features).flags == zero_flags {
					cluster := u64(sec) / fsys.master.cluster_size
					dsec = fs.Sector_Offset(u64(sec) - cluster * fsys.master.cluster_size)
					return fs.Cluster(cluster), dsec, i, true
				}
			}
		}
	}
	return {}, 0, 0, false
}

// find_or_extend_dir finds a free slot in a directory, extending the chain
// if needed. Returns (cluster, sector_offset_within_cluster, entry_index, ok).
find_or_extend_dir :: proc(fsys: ^FS, dir_cluster: fs.Cluster, dir_offset: fs.Sector_Offset) -> (dcluster: fs.Cluster, dsec: fs.Sector_Offset, didx: int, ok: bool) {
	dcluster, dsec, didx, ok = find_free_slot_in_extent(fsys, dir_cluster, dir_offset)
	if ok {
		return
	}

	current_runs, cr_ok := fs.resolve_extents(fsys.disk, &fsys.master, dir_cluster, dir_offset)
	if !cr_ok {
		return {}, {}, 0, false
	}

	current_count: u64
	for r in current_runs {
		current_count += u64(r.count)
	}

	_, _, ext_err := fs.allocate_sectors(&fsys.master, fsys.disk, &fsys.alloc_cache, dir_cluster, dir_offset, current_count + 1, .Directory)
	if ext_err != .None {
		return {}, {}, 0, false
	}

	dir_runs, dir_ok := fs.resolve_extents(fsys.disk, &fsys.master, dir_cluster, dir_offset)
	if !dir_ok {
		return {}, {}, 0, false
	}

	depc := dir_entries_per_buf(fsys.master.features)
	last_run := dir_runs[len(dir_runs) - 1]
	last_sec := fs.Sector(u64(last_run.sector) + u64(last_run.count) - 1)
	ext_buf: [fs.SECTOR_SIZE]u8
	if !fs.sector_read(fsys.disk, last_sec, ext_buf[:]) {
		return {}, {}, 0, false
	}

	zero_flags: fs.Dir_Flags
	for i in 0 ..< depc {
		if get_dir_entry(ext_buf[:], i, fsys.master.features).flags == zero_flags {
			dlc := u64(last_sec) / fsys.master.cluster_size
			dcluster = fs.Cluster(dlc)
			dsec = fs.Sector_Offset(u64(last_sec) - dlc * fsys.master.cluster_size)
			didx = i
			ok = true
			return
		}
	}
	return {}, 0, 0, false
}

// check_name_exists scans the directory for a name collision.
check_name_exists :: proc(fsys: ^FS, dir_cluster: fs.Cluster, dir_offset: fs.Sector_Offset, name: string) -> bool {
	depc := dir_entries_per_buf(fsys.master.features)
	dir_runs, dir_ok := fs.resolve_extents(fsys.disk, &fsys.master, dir_cluster, dir_offset)
	if !dir_ok {
		return false
	}

	scan_buf: [fs.SECTOR_SIZE]u8
	for run in dir_runs {
		n := int(run.count)
		for si in 0 ..< n {
			sec := fs.Sector(u64(run.sector) + u64(si))
			if !fs.sector_read(fsys.disk, sec, scan_buf[:]) {
				return false
			}
			for i in 0 ..< depc {
				if .Exists in get_dir_entry(scan_buf[:], i, fsys.master.features).flags {
					if fs.entry_short_name(get_dir_entry(scan_buf[:], i, fsys.master.features)) == name {
						return true
					}
				}
			}
		}
	}
	return false
}

// write_entry_with_lfn writes a directory entry, handling LFN allocation for
// names longer than 16 characters.
write_entry_with_lfn :: proc(fsys: ^FS, entry: ^fs.Directory_Entry, name: string) -> bool {
	set_entry_time_to_now(entry)
	return set_entry_name(fsys, entry, name)
}

// set_entry_name writes a name into a DirectoryEntry, handling LFN allocation
// and old LFN deallocation. Does NOT modify timestamps — caller is responsible.
set_entry_name :: proc(fsys: ^FS, entry: ^fs.Directory_Entry, name: string) -> bool {
	if .LFN in entry.flags {
		ptr := (^fs.LFN_Pointer)(&entry.file_name[0])
		if ptr.cluster != 0 {
			if derr := fs.deallocate_sectors(&fsys.master, fsys.disk, &fsys.alloc_cache, fs.Cluster(ptr.cluster), fs.Sector_Offset(ptr.sector)); derr != .None {
				return false
			}
		}
		entry.flags -= {.LFN}
	}
	if len(name) > 16 {
		needed := u16(len(name))
		if !fsys.lfn_bump.active || fsys.lfn_bump.next_byte + needed > fs.SECTOR_SIZE {
			new_c, new_o, lerr := fs.allocate_sectors(&fsys.master, fsys.disk, &fsys.alloc_cache, 0, 0, 1, .LFN)
			if lerr != .None {
				return false
			}

			lfn_runs, lfn_ok := fs.resolve_extents(fsys.disk, &fsys.master, new_c, new_o)
			if !lfn_ok || len(lfn_runs) == 0 {
				return false
			}

			fsys.lfn_bump.active = true
			fsys.lfn_bump.cluster = new_c
			fsys.lfn_bump.offset = new_o
			fsys.lfn_bump.sector = lfn_runs[0].sector
			fsys.lfn_bump.next_byte = 0
		}

		sector_buf: [fs.SECTOR_SIZE]u8
		if !fs.sector_read(fsys.disk, fsys.lfn_bump.sector, sector_buf[:]) {
			return false
		}

		copy(sector_buf[fsys.lfn_bump.next_byte:], transmute([]u8)(name))
		if !fs.sector_write(fsys.disk, fsys.lfn_bump.sector, sector_buf[:]) {
			return false
		}

		ptr := (^fs.LFN_Pointer)(&entry.file_name[0])
		ptr.cluster = u64(fsys.lfn_bump.cluster)
		ptr.size = u32(len(name))
		ptr.sector = u16(fsys.lfn_bump.offset)
		ptr._pad = fsys.lfn_bump.next_byte
		entry.flags += {.LFN}
		fsys.lfn_bump.next_byte += needed
	} else {
		copy(entry.file_name[:], name)
		mem.zero_slice(entry.file_name[len(name):])
	}
	return true
}

fused_getattr :: proc "c" (path: cstring, stbuf: ^fuse3.Stat, _: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	sync.mutex_lock(&fsys.mu)
	defer sync.mutex_unlock(&fsys.mu)

	entry, _, _, _, ok := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if !ok {
		log.debugf("getattr: %s → ENOENT", path)
		return fuse3.nix(.ENOENT)
	}

	stbuf^ = {}
	is_link := .Link in entry.flags
	is_dir := .Directory in entry.flags
	if is_link {
		mode := posix.mode_t{
			posix.Mode_Bits.IFREG, posix.Mode_Bits.IFCHR, .IRUSR, .IWUSR, .IRGRP, .IROTH,
		}
		if .No_Write in entry.flags || .Read_Only in entry.flags {
			mode -= {.IWUSR, .IWGRP, .IWOTH}
		}
		if .No_Read in entry.flags {
			mode -= {.IRUSR, .IRGRP, .IROTH}
		}

		stbuf.st_mode = mode
		stbuf.st_nlink = 1
		stbuf.st_size = posix.off_t(entry.file_size)
	} else if is_dir {
		mode := posix.mode_t{
			posix.Mode_Bits.IFDIR, .IRUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH,
		}
		if .No_Read in entry.flags {
			mode -= {.IRUSR, .IRGRP, .IROTH}
		}
		if .No_Write in entry.flags {
			mode -= {.IWUSR, .IWGRP, .IWOTH}
		}
		if .No_Execute in entry.flags {
			mode -= {.IXUSR, .IXGRP, .IXOTH}
		}
		stbuf.st_mode = mode
		stbuf.st_nlink = 2
	} else {
		mode := posix.mode_t{posix.Mode_Bits.IFREG, .IRUSR, .IWUSR, .IRGRP, .IROTH}
		if .No_Write in entry.flags || .Read_Only in entry.flags {
			mode -= {.IWUSR, .IWGRP, .IWOTH}
		}
		if .No_Read in entry.flags {
			mode -= {.IRUSR, .IRGRP, .IROTH}
		}

		stbuf.st_mode = mode
		stbuf.st_nlink = 1
		stbuf.st_size = posix.off_t(entry.file_size)
	}

	dt := entry.date_time
	t, _ := time.components_to_time(
		i64(entry.year), i64(dt.month), i64(dt.date),
		i64(dt.hour), i64(dt.minute), i64(dt.second),
	)

	ts := posix.time_t(time.time_to_unix(t))
	stbuf.st_mtim.tv_sec = ts
	stbuf.st_ctim.tv_sec = ts
	at := entry.atime_date_time
	atime_t, _ := time.components_to_time(
		i64(entry.atime_year), i64(at.month), i64(at.date),
		i64(at.hour), i64(at.minute), i64(at.second),
	)

	stbuf.st_atim.tv_sec = posix.time_t(time.time_to_unix(atime_t))
	stbuf.st_uid = posix.uid_t(entry.uid)
	stbuf.st_gid = posix.gid_t(entry.gid)
	return 0
}

fused_readdir :: proc "c" (
	path:   cstring,
	buf:    rawptr,
	filler: fuse3.Fill_Dir_Proc,
	off:    posix.off_t,
	_:      ^fuse3.File_Info,
	flags:  c.int,
) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger

	// Fast path: resolve path without holding the lock long-term.
	// We release the lock after resolving, since the directory's
	// on-disk data is stable for the duration of the readdir call.
	sync.mutex_lock(&fsys.mu)
	depc := dir_entries_per_buf(fsys.master.features)
	entry, _, _, _, ok := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if !ok || .Directory not_in entry.flags {
		sync.mutex_unlock(&fsys.mu)
		log.debugf("readdir: %s → ENOENT/not-dir", path)
		return fuse3.nix(.ENOENT)
	}
	dir_cluster := fs.Cluster(entry.stored_cluster)
	dir_offset := fs.Sector_Offset(entry.sector_index)
	dir_runs, dir_ok := fs.resolve_extents(fsys.disk, &fsys.master, dir_cluster, dir_offset)
	sync.mutex_unlock(&fsys.mu)

	if !dir_ok {
		log.debugf("readdir: %s → extent resolve failed", path)
		return fuse3.nix(.ENOENT)
	}

	if rc := fuse3.fill_dir(filler, buf, ".", nil); rc != 0 {return rc}
	if rc := fuse3.fill_dir(filler, buf, "..", nil); rc != 0 {return rc}

	e: int
	sector_buf: [fs.SECTOR_SIZE]u8
	for run in dir_runs {
		n := int(run.count)
		for si in 0 ..< n {
			sec := fs.Sector(u64(run.sector) + u64(si))
			if !fs.sector_read(fsys.disk, sec, sector_buf[:]) {
				log.debugf("readdir: %s → sector read failed at %d", path, sec)
				break
			}
			for i in 0 ..< depc {
				if .Exists in get_dir_entry(sector_buf[:], i, fsys.master.features).flags {
					name := fs.entry_short_name(get_dir_entry(sector_buf[:], i, fsys.master.features))
					if .LFN in get_dir_entry(sector_buf[:], i, fsys.master.features).flags {
						// LFN cache is read-only after setup, safe without lock
						sec_off := fs.Sector_Offset(u64(run.sector) + u64(si) - u64(dir_cluster) * fsys.master.cluster_size)
						cache_k := lfn_cache_key(dir_cluster, sec_off, i)
						if cached, hit := lru.get(&fsys.lfn_cache, cache_k); hit {
							name = cached
						} else {
							lfn, l_ok := fs.resolve_lfn(fsys.disk, &fsys.master, get_dir_entry(sector_buf[:], i, fsys.master.features))
							if l_ok {
								name = lfn
								c := strings.clone(name, context.allocator)
								lru.set(&fsys.lfn_cache, cache_k, c)
							}
						}
					}

					name_cstr := strings.clone_to_cstring(name) or_continue
					if rc := fuse3.fill_dir(filler, buf, name_cstr, nil); rc != 0 {
						delete(name_cstr)
						return rc
					}
					delete(name_cstr)
					e += 1
				}
			}
		}
	}
	log.debugf("readdir: %s → ok %d entries", path, e)
	return 0
}

fused_open :: proc "c" (path: cstring, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	sync.mutex_lock(&fsys.mu)
	defer sync.mutex_unlock(&fsys.mu)

	entry, parent_cluster, parent_offset, entry_idx, ok := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if !ok {
		log.debugf("open: %s → ENOENT", path)
		return fuse3.nix(.ENOENT)
	}
	if .Directory in entry.flags {
		log.debugf("open: %s → EISDIR", path)
		return fuse3.nix(.EISDIR)
	}

	open_flags := transmute(posix.O_Flags)(fi.flags)
	wants_write := .WRONLY in open_flags || .RDWR in open_flags
	if wants_write && (.No_Write in entry.flags || .Read_Only in entry.flags) {
		return fuse3.nix(.EACCES)
	}
	if !wants_write && .No_Read in entry.flags {
		return fuse3.nix(.EACCES)
	}

	fi.fh = (u64(parent_cluster) << 32) | (u64(parent_offset) << 16) | u64(entry_idx)
	log.debugf("open: %s → ok", path)
	return 0
}

fused_read :: proc "c" (
	path: cstring,
	buf:  [^]c.char,
	size: c.size_t,
	off:  posix.off_t,
	fi:   ^fuse3.File_Info,
) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	read_start := time.now()
	_, data_cluster, data_offset, ok := read_entry_from_fh(fsys, fi.fh)
	if !ok {
		return fuse3.nix(.ENOENT)
	}

	runs, runs_ok := fs.resolve_extents(fsys.disk, &fsys.master, data_cluster, data_offset)
	if !runs_ok {
		return fuse3.nix(.ENOENT)
	}

	pos_in_file: u64 = 0
	bytes_read: u64 = 0
	sector_buf: [fs.SECTOR_SIZE]u8
	for run in runs {
		run_bytes := u64(run.count) * fs.SECTOR_SIZE
		if pos_in_file + run_bytes <= u64(off) {
			pos_in_file += run_bytes
			continue
		}

		skip_in_run := u64(off) - pos_in_file
		start_sector := u64(run.sector) + skip_in_run / fs.SECTOR_SIZE
		byte_offset := skip_in_run % fs.SECTOR_SIZE
		remaining_in_run := u64(run.sector) + u64(run.count) - start_sector
		if byte_offset > 0 && remaining_in_run > 0 {
			if !fs.sector_read(fsys.disk, fs.Sector(start_sector), sector_buf[:]) {break}

			avail := u64(len(sector_buf[byte_offset:]))
			need := min(avail, u64(size) - bytes_read)
			mem.copy(rawptr(buf[bytes_read:]), raw_data(sector_buf[byte_offset:]), int(need))

			bytes_read += need
			pos_in_file += u64(byte_offset) + need
			start_sector += 1
			remaining_in_run -= 1
			byte_offset = 0
			if bytes_read >= u64(size) {break}
		}
		if remaining_in_run > 0 && bytes_read < u64(size) {
			need_bytes := min(remaining_in_run * fs.SECTOR_SIZE, u64(size) - bytes_read)
			aligned_sectors := need_bytes / fs.SECTOR_SIZE
			if aligned_sectors > 0 {
				bulk_buf := buf[bytes_read:bytes_read + aligned_sectors * fs.SECTOR_SIZE]
				if !fs.sector_read(fsys.disk, fs.Sector(start_sector), bulk_buf) {break}

				bytes_read += aligned_sectors * fs.SECTOR_SIZE
				pos_in_file += aligned_sectors * fs.SECTOR_SIZE
				start_sector += aligned_sectors
				remaining_in_run -= aligned_sectors
				if bytes_read >= u64(size) {break}
			}
			if remaining_in_run > 0 && bytes_read < u64(size) {
				if !fs.sector_read(fsys.disk, fs.Sector(start_sector), sector_buf[:]) {break}

				need := min(u64(size) - bytes_read, fs.SECTOR_SIZE)
				mem.copy(rawptr(buf[bytes_read:]), raw_data(sector_buf[:]), int(need))
				bytes_read += need
				pos_in_file += need
			}
		}
		if bytes_read >= u64(size) {
			break
		}
		pos_in_file = u64(run.sector + fs.Sector(run.count)) * fs.SECTOR_SIZE
	}

	log.debugf("read: %s off=%d size=%d → %d bytes (%v)", path, off, size, bytes_read, time.since(read_start))
	return c.int(bytes_read)
}

fused_read_buf :: proc "c" (
	path: cstring,
	bufp: ^^fuse3.Bufvec,
	size: c.size_t,
	off:  posix.off_t,
	fi:   ^fuse3.File_Info,
) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	read_start := time.now()
	_, data_cluster, data_offset, ok := read_entry_from_fh(fsys, fi.fh)
	if !ok {
		return fuse3.nix(.ENOENT)
	}

	runs, runs_ok := fs.resolve_extents(fsys.disk, &fsys.master, data_cluster, data_offset)
	if !runs_ok {
		return fuse3.nix(.ENOENT)
	}

	remaining := u64(size)
	req_off := u64(off)
	total_provided: u64
	buf_count: int
	for run in runs {
		run_bytes := u64(run.count) * fs.SECTOR_SIZE
		if req_off >= run_bytes {
			req_off -= run_bytes
			continue
		}

		avail := min(run_bytes - req_off, remaining)
		if avail > 0 {
			buf_count += 1
			total_provided += avail
			remaining -= avail
			req_off = 0
		}
		if remaining == 0 {break}
	}
	if buf_count == 0 {
		return fuse3.nix(.ENOENT)
	}

	alloc_size := c.size_t(size_of(fuse3.Bufvec) + (buf_count - 1) * size_of(fuse3.Buf))
	bv := (^fuse3.Bufvec)(posix.malloc(alloc_size))
	if bv == nil {
		return fuse3.nix(.ENOMEM)
	}

	bv.count = c.size_t(buf_count)
	bv.idx = 0
	bv.off = 0
	remaining = u64(size)
	req_off = u64(off)
	bufs := slice.from_ptr(&bv._buf[0], int(bv.count))
	idx := 0
	for run in runs {
		run_bytes := u64(run.count) * fs.SECTOR_SIZE
		if req_off >= run_bytes {
			req_off -= run_bytes
			continue
		}

		avail := min(run_bytes - req_off, remaining)
		if avail == 0 {continue}

		buf_entry := &bufs[idx]
		buf_entry.size = c.size_t(avail)
		buf_entry.flags = fuse3.FUSE_BUF_IS_FD | fuse3.FUSE_BUF_FD_SEEK
		buf_entry.fd = fsys.disk_raw_fd
		buf_entry.pos = posix.off_t(u64(run.sector) * fs.SECTOR_SIZE + req_off)
		buf_entry.mem = nil
		buf_entry.mem_size = 0
		idx += 1
		remaining -= avail
		req_off = 0
		if remaining == 0 {break}
	}

	bufp^ = bv
	log.debugf("read_buf: %s off=%d size=%d → %d bytes (%d bufs, %v)",
		path, off, size, total_provided, buf_count, time.since(read_start))
	return c.int(total_provided)
}

fused_write :: proc "c" (
	path: cstring,
	buf:  [^]c.char,
	size: c.size_t,
	off:  posix.off_t,
	fi:   ^fuse3.File_Info,
) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	write_start := time.now()
	sync.mutex_lock(&fsys.mu)
	defer sync.mutex_unlock(&fsys.mu)

	entry, data_cluster, data_offset, ok := read_entry_from_fh(fsys, fi.fh)
	if !ok {
		log.debugf("write: %s → ENOENT", path)
		return fuse3.nix(.ENOENT)
	}

	entry_cluster, entry_offset, entry_idx := unpack_fh(fi.fh)
	runs, runs_ok := fs.resolve_extents(fsys.disk, &fsys.master, data_cluster, data_offset)
	total_sectors := (u64(off) + u64(size) + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE
	current_sectors: u64
	if runs_ok {
		for r in runs {
			current_sectors += u64(r.count)
		}
	}
	if total_sectors > current_sectors {
		new_c, new_o, aerr := fs.allocate_sectors(
			&fsys.master, fsys.disk, &fsys.alloc_cache,
			data_cluster, data_offset,
			total_sectors, .File_Content)
		if aerr != .None {
			log.errorf("write: %s → ENOSPC", path)
			return fuse3.nix(.ENOSPC)
		}
		if data_cluster == 0 {
			entry.stored_cluster = u64(new_c)
			entry.sector_index = u16(new_o)
			data_cluster = new_c
			data_offset = new_o
		}
		runs, runs_ok = fs.resolve_extents(fsys.disk, &fsys.master, data_cluster, data_offset)
	}
	if !runs_ok {
		log.errorf("write: %s → extents failed", path)
		return fuse3.nix(.ENOENT)
	}

	log.debugf("write: %s → enter write loop (runs=%d)", path, len(runs))
	pos_in_file: u64 = 0
	bytes_written: u64 = 0

	remaining := u64(size)
	write_off := u64(off)
	sector_rw: [fs.SECTOR_SIZE]u8
	new_size := max(u64(entry.file_size), write_off + u64(size))
	for run in runs {
		run_bytes := u64(run.count) * fs.SECTOR_SIZE
		if pos_in_file + run_bytes <= write_off {
			pos_in_file += run_bytes
			continue
		}

		skip := write_off - pos_in_file
		start_sec := u64(run.sector) + skip / fs.SECTOR_SIZE
		byte_off := skip % fs.SECTOR_SIZE
		remaining_in_run := u64(run.sector) + u64(run.count) - start_sec
		if byte_off > 0 && remaining_in_run > 0 && remaining > 0 {
			if !fs.sector_read(fsys.disk, fs.Sector(start_sec), sector_rw[:]) {break}

			avail := u64(len(sector_rw[byte_off:]))
			take := min(avail, remaining)
			mem.copy(raw_data(sector_rw[byte_off:]), rawptr(buf[bytes_written:]), int(take))
			if !fs.sector_write(fsys.disk, fs.Sector(start_sec), sector_rw[:]) {break}

			bytes_written += take
			remaining -= take
			pos_in_file += u64(byte_off) + take
			start_sec += 1
			remaining_in_run -= 1
			byte_off = 0
			if remaining == 0 {break}
		}
		if remaining_in_run > 0 && remaining > 0 {
			full_sectors := remaining / fs.SECTOR_SIZE
			if full_sectors > remaining_in_run {full_sectors = remaining_in_run}
			if full_sectors > 0 {
				bulk_buf := buf[bytes_written:bytes_written + full_sectors * fs.SECTOR_SIZE]
				if !fs.sector_write_bulk(fsys.disk, fs.Sector(start_sec), bulk_buf) {
					break
				}

				bytes_written += full_sectors * fs.SECTOR_SIZE
				remaining -= full_sectors * fs.SECTOR_SIZE
				pos_in_file += full_sectors * fs.SECTOR_SIZE
				start_sec += full_sectors
				remaining_in_run -= full_sectors
				if remaining == 0 {break}
			}
		}
		if remaining_in_run > 0 && remaining > 0 {
			if !fs.sector_read(fsys.disk, fs.Sector(start_sec), sector_rw[:]) {break}
			mem.copy(raw_data(sector_rw[:]), rawptr(buf[bytes_written:]), int(remaining))
			if !fs.sector_write(fsys.disk, fs.Sector(start_sec), sector_rw[:]) {break}

			last := remaining
			pos_in_file += last
			bytes_written += last
			remaining = 0
		}
		if remaining == 0 {break}
		pos_in_file = u64(run.sector + fs.Sector(run.count)) * fs.SECTOR_SIZE
	}
	if new_size != u64(entry.file_size) {
		set_entry_time_to_now(&entry)
		entry.file_size = new_size
		write_entry_back(fsys, &entry, entry_cluster, entry_offset, entry_idx)
	}

	lru.remove(&fsys.path_cache, string(path))
	log.debugf("write: %s off=%d size=%d → %d bytes (%v)", path, off, size, bytes_written, time.since(write_start))
	return c.int(bytes_written)
}

fused_write_buf :: proc "c" (
	path: cstring,
	buf:  ^fuse3.Bufvec,
	off:  posix.off_t,
	fi:   ^fuse3.File_Info,
) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	write_start := time.now()
	sync.mutex_lock(&fsys.mu)
	defer sync.mutex_unlock(&fsys.mu)

	entry, data_cluster, data_offset, ok := read_entry_from_fh(fsys, fi.fh)
	if !ok {
		log.debugf("write_buf: %s → ENOENT", path)
		return fuse3.nix(.ENOENT)
	}

	total_size: u64
	bufs := slice.from_ptr(&buf._buf[0], int(buf.count))
	for i in 0 ..< buf.count {
		b := bufs[i]
		total_size += u64(b.size)
	}

	entry_cluster, entry_offset, entry_idx := unpack_fh(fi.fh)
	runs, runs_ok := fs.resolve_extents(fsys.disk, &fsys.master, data_cluster, data_offset)
	total_sectors := (u64(off) + total_size + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE
	current_sectors: u64
	if runs_ok {
		for r in runs {
			current_sectors += u64(r.count)
		}
	}
	if total_sectors > current_sectors {
		new_c, new_o, aerr := fs.allocate_sectors(
			&fsys.master, fsys.disk, &fsys.alloc_cache,
			data_cluster, data_offset,
			total_sectors, .File_Content)
		if aerr != .None {
			log.errorf("write_buf: %s → ENOSPC", path)
			return fuse3.nix(.ENOSPC)
		}
		if data_cluster == 0 {
			entry.stored_cluster = u64(new_c)
			entry.sector_index = u16(new_o)
			data_cluster = new_c
			data_offset = new_o
		}
		runs, runs_ok = fs.resolve_extents(fsys.disk, &fsys.master, data_cluster, data_offset)
	}
	if !runs_ok {
		log.errorf("write_buf: %s → extents failed", path)
		return fuse3.nix(.ENOENT)
	}

	log.debugf("write_buf: %s → enter write loop (runs=%d, bufs=%d)", path, len(runs), buf.count)
	write_off := u64(off)
	new_size := max(u64(entry.file_size), write_off + total_size)

	pos_in_file: u64
	bytes_written: u64
	buf_idx: int
	sector_rw: [fs.SECTOR_SIZE]u8
	for run in runs {
		run_bytes := u64(run.count) * fs.SECTOR_SIZE
		if pos_in_file + run_bytes <= write_off {
			pos_in_file += run_bytes
			continue
		}

		skip := write_off - pos_in_file
		start_sec := u64(run.sector) + skip / fs.SECTOR_SIZE
		byte_off := skip % fs.SECTOR_SIZE
		remaining_in_run := u64(run.sector) + u64(run.count) - start_sec
		for (byte_off > 0 || remaining_in_run > 0) && buf_idx < int(buf.count) {
			b := bufs[buf_idx]
			buf_remaining := u64(b.size)
			if byte_off > 0 && remaining_in_run > 0 && buf_remaining > 0 {
				if !fs.sector_read(fsys.disk, fs.Sector(start_sec), sector_rw[:]) {break}

				avail := u64(len(sector_rw[byte_off:]))
				take := min(avail, buf_remaining)
				if b.flags & fuse3.FUSE_BUF_IS_FD != 0 {
					panic("write_buf: fd-backed buf at unaligned offset not supported")
				} else {
					src := ([^]u8)(b.mem)[:b.size]
					mem.copy(raw_data(sector_rw[byte_off:]), raw_data(src), int(take))
				}
				if !fs.sector_write(fsys.disk, fs.Sector(start_sec), sector_rw[:]) {
					break
				}

				bytes_written += take
				write_off += take
				pos_in_file += u64(byte_off) + take
				b.size -= c.size_t(take)
				b.mem = rawptr(uintptr(b.mem) + uintptr(take))
				start_sec += 1
				remaining_in_run -= 1
				byte_off = 0
				buf_remaining -= take
				if buf_remaining == 0 {buf_idx += 1}
				continue
			}
			if remaining_in_run == 0 || buf_remaining == 0 {break}

			full_sectors := buf_remaining / fs.SECTOR_SIZE
			if full_sectors > remaining_in_run {full_sectors = remaining_in_run}
			if full_sectors > 0 {
				bulk_len := full_sectors * fs.SECTOR_SIZE
				if b.flags & fuse3.FUSE_BUF_IS_FD != 0 {
					phys_off := i64(start_sec * fs.SECTOR_SIZE)
					for written: u64; written < bulk_len; /**/ {
						n, err := linux.splice(
							linux.Fd(b.fd), nil,
							linux.Fd(fsys.disk_raw_fd), &phys_off,
							uint(bulk_len - written), {})
						if err != .NONE {break}
						written += u64(n)
					}
				} else {
					src := ([^]u8)(b.mem)[:bulk_len]
					if !fs.sector_write_bulk(fsys.disk, fs.Sector(start_sec), src) {break}
				}

				bytes_written += bulk_len
				write_off += bulk_len
				pos_in_file += bulk_len
				b.size -= c.size_t(bulk_len)
				if b.flags & fuse3.FUSE_BUF_IS_FD == 0 {
					b.mem = rawptr(uintptr(b.mem) + uintptr(bulk_len))
				}

				start_sec += full_sectors
				remaining_in_run -= full_sectors
				buf_remaining -= bulk_len
				if buf_remaining == 0 {buf_idx += 1}
				continue
			}
			if remaining_in_run > 0 && buf_remaining > 0 {
				if !fs.sector_read(fsys.disk, fs.Sector(start_sec), sector_rw[:]) {break}
				if b.flags & fuse3.FUSE_BUF_IS_FD != 0 {
					panic("write_buf: fd-backed buf at partial sector tail not supported")
				} else {
					src := ([^]u8)(b.mem)[:buf_remaining]
					mem.copy(raw_data(sector_rw[:]), raw_data(src), int(buf_remaining))
				}
				if !fs.sector_write(fsys.disk, fs.Sector(start_sec), sector_rw[:]) {break}

				bytes_written += buf_remaining
				write_off += buf_remaining
				pos_in_file += buf_remaining
				remaining_in_run = 0
				buf_idx += 1
			}
		}
		if buf_idx >= int(buf.count) {break}
		pos_in_file = u64(run.sector + fs.Sector(run.count)) * fs.SECTOR_SIZE
	}
	if new_size != u64(entry.file_size) {
		set_entry_time_to_now(&entry)
		entry.file_size = new_size
		write_entry_back(fsys, &entry, entry_cluster, entry_offset, entry_idx)
	}

	lru.remove(&fsys.path_cache, string(path))
	log.debugf("write_buf: %s off=%d → %d bytes (%v)", path, off, bytes_written, time.since(write_start))
	return c.int(bytes_written)
}

fused_create :: proc "c" (path: cstring, mode: posix.mode_t, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	sync.mutex_lock(&fsys.mu)
	defer sync.mutex_unlock(&fsys.mu)

	parent, name := os.split_path(string(path))
	parent_entry, _, _, _, ok := resolve_path_cached(fsys, parent, context.temp_allocator)
	if !ok {
		log.debugf("create: %s → parent ENOENT", path)
		return fuse3.nix(.ENOENT)
	}

	dir_cluster := fs.Cluster(parent_entry.stored_cluster)
	dir_offset := fs.Sector_Offset(parent_entry.sector_index)
	if check_name_exists(fsys, dir_cluster, dir_offset, name) {
		log.debugf("create: %s → EEXIST", path)
		return fuse3.nix(.EEXIST)
	}

	dcluster, dsec, didx, slot_ok := find_or_extend_dir(fsys, dir_cluster, dir_offset)
	if !slot_ok {
		log.debugf("create: %s → ENOSPC (dir full)", path)
		return fuse3.nix(.ENOSPC)
	}

	flags := fs.Dir_Flags{.Allocated, .Exists}
	if .IFDIR in mode {
		flags += {.Directory}
	}

	ctx := fuse3.fuse_get_context()
	new_entry: fs.Directory_Entry
	new_entry.flags = flags
	new_entry.uid = u32(ctx.uid)
	new_entry.gid = u32(ctx.gid)
	if !write_entry_with_lfn(fsys, &new_entry, name) {
		return fuse3.nix(.ENOSPC)
	}
	if !fs.write_directory_entry_at(fsys.disk, &fsys.master, dcluster, dsec, didx, &new_entry) {
		return fuse3.nix(.EIO)
	}

	fi.fh = (u64(dcluster) << 32) | (u64(dsec) << 16) | u64(didx)
	path_cache_invalidate_all(fsys)
	log.debugf("create: %s → ok", path)
	return 0
}

fused_mkdir :: proc "c" (path: cstring, mode: posix.mode_t) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	sync.mutex_lock(&fsys.mu)
	defer sync.mutex_unlock(&fsys.mu)

	parent, name := os.split_path(string(path))
	parent_entry, _, _, _, ok := resolve_path_cached(fsys, parent, context.temp_allocator)
	if !ok {
		return fuse3.nix(.ENOENT)
	}

	dir_cluster := fs.Cluster(parent_entry.stored_cluster)
	dir_offset := fs.Sector_Offset(parent_entry.sector_index)
	if check_name_exists(fsys, dir_cluster, dir_offset, name) {
		return fuse3.nix(.EEXIST)
	}

	dcluster, dsec, didx, slot_ok := find_or_extend_dir(fsys, dir_cluster, dir_offset)
	if !slot_ok {
		return fuse3.nix(.ENOSPC)
	}

	new_cluster, new_offset, derr := fs.allocate_sectors(&fsys.master, fsys.disk, &fsys.alloc_cache, 0, 0, 1, .Directory)
	if derr != .None {
		return fuse3.nix(.ENOSPC)
	}

	dir_runs, dr_ok := fs.resolve_extents(fsys.disk, &fsys.master, new_cluster, new_offset)
	if !dr_ok || len(dir_runs) == 0 {
		return fuse3.nix(.EIO)
	}

	zero: [fs.SECTOR_SIZE]u8
	if !fs.sector_write(fsys.disk, dir_runs[0].sector, zero[:]) {
		return fuse3.nix(.EIO)
	}

	new_entry: fs.Directory_Entry
	new_entry.flags = fs.Dir_Flags{.Allocated, .Directory, .Exists}
	new_entry.sector_index = u16(new_offset)
	new_entry.stored_cluster = u64(new_cluster)
	ctx := fuse3.fuse_get_context()
	new_entry.uid = u32(ctx.uid)
	new_entry.gid = u32(ctx.gid)

	set_entry_time_to_now(&new_entry)
	copy(new_entry.file_name[:], name)
	if len(name) < 16 {
		new_entry.file_name[len(name)] = 0
	}
	if !fs.write_directory_entry_at(fsys.disk, &fsys.master, dcluster, dsec, didx, &new_entry) {
		return fuse3.nix(.EIO)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("mkdir: %s → ok", path)
	return 0
}

fused_symlink :: proc "c" (target: cstring, linkpath: cstring) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	sync.mutex_lock(&fsys.mu)
	defer sync.mutex_unlock(&fsys.mu)

	target_str := string(target)
	parent, name := os.split_path(string(linkpath))
	parent_entry, _, _, _, ok := resolve_path_cached(fsys, parent, context.temp_allocator)
	if !ok {
		return fuse3.nix(.ENOENT)
	}

	dir_cluster := fs.Cluster(parent_entry.stored_cluster)
	dir_offset := fs.Sector_Offset(parent_entry.sector_index)
	if check_name_exists(fsys, dir_cluster, dir_offset, name) {
		return fuse3.nix(.EEXIST)
	}

	dcluster, dsec, didx, slot_ok := find_or_extend_dir(fsys, dir_cluster, dir_offset)
	if !slot_ok {
		return fuse3.nix(.ENOSPC)
	}

	sectors_needed := (u64(len(target_str)) + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE
	new_c, new_o, aerr := fs.allocate_sectors(&fsys.master, fsys.disk, &fsys.alloc_cache, 0, 0, sectors_needed, .File_Content)
	if aerr != .None {
		return fuse3.nix(.ENOSPC)
	}

	{
		runs, rok := fs.resolve_extents(fsys.disk, &fsys.master, new_c, new_o)
		if !rok || len(runs) == 0 {
			return fuse3.nix(.EIO)
		}

		buf: [fs.SECTOR_SIZE]u8
		copy(buf[:], transmute([]u8)(target_str))
		if !fs.sector_write(fsys.disk, runs[0].sector, buf[:]) {
			return fuse3.nix(.EIO)
		}
	}

	new_entry: fs.Directory_Entry
	new_entry.flags = fs.Dir_Flags{.Allocated, .Exists, .Link}
	new_entry.stored_cluster = u64(new_c)
	new_entry.sector_index = u16(new_o)
	new_entry.file_size = u64(len(target_str))
	ctx2 := fuse3.fuse_get_context()
	new_entry.uid = u32(ctx2.uid)
	new_entry.gid = u32(ctx2.gid)

	set_entry_time_to_now(&new_entry)
	if !write_entry_with_lfn(fsys, &new_entry, name) {
		return fuse3.nix(.ENOSPC)
	}
	if !fs.write_directory_entry_at(fsys.disk, &fsys.master, dcluster, dsec, didx, &new_entry) {
		return fuse3.nix(.EIO)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("symlink: %s → %s ok", linkpath, target)
	return 0
}

fused_unlink :: proc "c" (path: cstring) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	sync.mutex_lock(&fsys.mu)
	defer sync.mutex_unlock(&fsys.mu)

	entry, cluster, offset, idx, ok := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if !ok {
		log.debugf("unlink: %s → ENOENT", path)
		return fuse3.nix(.ENOENT)
	}
	if .Directory in entry.flags {
		log.debugf("unlink: %s → EISDIR", path)
		return fuse3.nix(.EISDIR)
	}
	if entry.stored_cluster != 0 {
		if derr := fs.deallocate_sectors(&fsys.master, fsys.disk, &fsys.alloc_cache, fs.Cluster(entry.stored_cluster), fs.Sector_Offset(entry.sector_index)); derr != .None {
			return fuse3.nix(.EIO)
		}
	}

	entry.flags = {}
	if !write_entry_back(fsys, &entry, cluster, offset, idx) {
		return fuse3.nix(.EIO)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("unlink: %s → ok", path)
	return 0
}

fused_rmdir :: proc "c" (path: cstring) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	sync.mutex_lock(&fsys.mu)
	defer sync.mutex_unlock(&fsys.mu)

	entry, cluster, offset, idx, ok := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if !ok {
		return fuse3.nix(.ENOENT)
	}
	if .Directory not_in entry.flags {
		log.debugf("rmdir: %s → ENOTDIR", path)
		return fuse3.nix(.ENOTDIR)
	}

	dirs, _ := fs.read_directory_entries(fsys.disk, &fsys.master, fs.Cluster(entry.stored_cluster), fs.Sector_Offset(entry.sector_index))
	defer delete(dirs)

	for &d in dirs {
		if .Exists in d.flags {
			log.debugf("rmdir: %s → ENOTEMPTY", path)
			return fuse3.nix(.ENOTEMPTY)
		}
	}
	if entry.stored_cluster != 0 {
		if derr := fs.deallocate_sectors(&fsys.master, fsys.disk, &fsys.alloc_cache, fs.Cluster(entry.stored_cluster), fs.Sector_Offset(entry.sector_index)); derr != .None {
			return fuse3.nix(.EIO)
		}
	}

	entry.flags = {}
	if !write_entry_back(fsys, &entry, cluster, offset, idx) {
		return fuse3.nix(.EIO)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("rmdir: %s → ok", path)
	return 0
}

fused_truncate :: proc "c" (path: cstring, size: posix.off_t, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	sync.mutex_lock(&fsys.mu)
	defer sync.mutex_unlock(&fsys.mu)

	log.debugf("truncate: %s size=%d fi=%v", path, size, fi != nil)

	entry: fs.Directory_Entry
	data_cluster: fs.Cluster
	data_offset: fs.Sector_Offset
	entry_cluster: fs.Cluster
	entry_offset: fs.Sector_Offset
	entry_idx: int
	if fi != nil {
		entry_cluster, entry_offset, entry_idx = unpack_fh(fi.fh)
		e, dc, ddo, ok := read_entry_from_fh(fsys, fi.fh)
		if !ok {
			log.debugf("truncate: %s → ENOENT (fh)", path)
			return fuse3.nix(.ENOENT)
		}

		entry = e
		data_cluster = dc
		data_offset = ddo
	} else {
		e, c, o, i, resolved := resolve_path_cached(fsys, string(path), context.temp_allocator)
		if !resolved {
			log.debugf("truncate: %s → ENOENT", path)
			return fuse3.nix(.ENOENT)
		}

		entry = e
		entry_cluster = c
		entry_offset = o
		entry_idx = i
		data_cluster = fs.Cluster(entry.stored_cluster)
		data_offset = fs.Sector_Offset(entry.sector_index)
	}

	if .Directory in entry.flags {
		log.debugf("truncate: %s → EISDIR", path)
		return fuse3.nix(.EISDIR)
	}

	new_sectors := (u64(size) + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE
	current_sectors: u64
	runs, runs_ok := fs.resolve_extents(fsys.disk, &fsys.master, data_cluster, data_offset)
	if runs_ok {
		for r in runs {
			current_sectors += u64(r.count)
		}
	}
	if new_sectors < current_sectors {
		cntr := u64(0)
		current_c := fs.Cluster(entry.stored_cluster)
		current_o := fs.Sector_Offset(entry.sector_index)
		for {
			ce_idx: int
			ce, ce_ok := fs.find_cluster_entry(fsys.disk, &fsys.master, current_c, current_o, nil, &ce_idx)
			if !ce_ok {
				break
			}

			before := cntr
			cntr += u64(ce.allocation_size)
			if cntr > new_sectors {
				needed := new_sectors - before
				if needed == 0 {
					nc := fs.Cluster(ce.next_cluster)
					no := fs.Sector_Offset(ce.next_sector_index)
					if derr := fs.deallocate_sectors(&fsys.master, fsys.disk, &fsys.alloc_cache, current_c, current_o); derr != .None {
						return fuse3.nix(.EIO)
					}
					if nc != 0 {
						if derr := fs.deallocate_sectors(&fsys.master, fsys.disk, &fsys.alloc_cache, nc, no); derr != .None {
							return fuse3.nix(.EIO)
						}
					}
				} else {
					if ce.next_cluster != 0 {
						nc := fs.Cluster(ce.next_cluster)
						no := fs.Sector_Offset(ce.next_sector_index)
						if derr := fs.deallocate_sectors(&fsys.master, fsys.disk, &fsys.alloc_cache, nc, no); derr != .None {
							return fuse3.nix(.EIO)
						}
						ce.next_cluster = 0
						ce.next_sector_index = 0
					}

					ce.allocation_size = u16(needed)
					if !fs.write_cluster_entry_at(fsys.disk, &fsys.master, current_c, ce_idx, &ce) {
						return fuse3.nix(.EIO)
					}
				}
				break
			}
			if ce.next_cluster == 0 {
				break
			}
			current_c = fs.Cluster(ce.next_cluster)
			current_o = fs.Sector_Offset(ce.next_sector_index)
		}
	} else if new_sectors > current_sectors {
		_, _, aerr := fs.allocate_sectors(&fsys.master, fsys.disk, &fsys.alloc_cache, fs.Cluster(entry.stored_cluster), fs.Sector_Offset(entry.sector_index), new_sectors, .File_Content)
		if aerr != .None {
			return fuse3.nix(.ENOSPC)
		}
	}

	set_entry_time_to_now(&entry)
	entry.file_size = u64(size)
	if !write_entry_back(fsys, &entry, entry_cluster, entry_offset, entry_idx) {
		return fuse3.nix(.EIO)
	}

	lru.remove(&fsys.path_cache, string(path))
	log.debugf("truncate: %s → %d", path, size)
	return 0
}

zero_file_range :: proc(fsys: ^FS, entry: ^fs.Directory_Entry, data_cluster: fs.Cluster, data_offset: fs.Sector_Offset, start: u64, end: u64) -> bool {
	if start >= end {return true}

	runs, rok := fs.resolve_extents(fsys.disk, &fsys.master, data_cluster, data_offset)
	if !rok {return false}

	zero_sector: [fs.SECTOR_SIZE]u8
	file_pos: u64 = 0
	for run in runs {
		run_bytes := u64(run.count) * fs.SECTOR_SIZE
		run_start := file_pos
		run_end := file_pos + run_bytes
		if run_end <= start {file_pos += run_bytes; continue}
		if run_start >= end {break}
		for si: u64; si < u64(run.count); si += 1 {
			sector_start := file_pos
			sector_end := file_pos + fs.SECTOR_SIZE
			if sector_end <= start || sector_start >= end {
				file_pos += fs.SECTOR_SIZE
				continue
			}

			sec := fs.Sector(u64(run.sector) + si)
			sector_buf: [fs.SECTOR_SIZE]u8
			if sector_start >= start && sector_end <= end {
				if !fs.sector_write(fsys.disk, sec, zero_sector[:]) {
					return false
				}
			} else {
				if !fs.sector_read(fsys.disk, sec, sector_buf[:]) {
					return false
				}

				zero_begin := max(sector_start, start) - sector_start
				zero_end := min(sector_end, end) - sector_start
				mem.zero_slice(sector_buf[zero_begin:zero_end])
				if !fs.sector_write(fsys.disk, sec, sector_buf[:]) {
					return false
				}
			}
			file_pos += fs.SECTOR_SIZE
		}
	}
	return true
}

fused_fallocate :: proc "c" (path: cstring, mode: c.int, off: posix.off_t, length: posix.off_t, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	sync.mutex_lock(&fsys.mu)
	defer sync.mutex_unlock(&fsys.mu)

	if mode & (fuse3.FALLOC_FL_COLLAPSE_RANGE | fuse3.FALLOC_FL_INSERT_RANGE) != 0 {
		return fuse3.nix(.EOPNOTSUPP)
	}

	entry, data_cluster, data_offset, ok := read_entry_from_fh(fsys, fi.fh)
	if !ok {
		return fuse3.nix(.ENOENT)
	}

	entry_cluster, entry_offset, entry_idx := unpack_fh(fi.fh)
	if .Directory in entry.flags {
		return fuse3.nix(.EISDIR)
	}

	alloc_start := u64(off)
	alloc_len := u64(length)
	total_sectors := (alloc_start + alloc_len + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE
	current_sectors: u64
	runs, runs_ok := fs.resolve_extents(fsys.disk, &fsys.master, data_cluster, data_offset)
	if runs_ok {
		for r in runs {
			current_sectors += u64(r.count)
		}
	}
	if mode & fuse3.FALLOC_FL_PUNCH_HOLE != 0 {
		punch_start := alloc_start
		punch_end := alloc_start + alloc_len
		zok := zero_file_range(fsys, &entry, data_cluster, data_offset, punch_start, punch_end)
		if !zok {
			return fuse3.nix(.EIO)
		}
		// Update file_size if needed (PUNCH_HOLE implies KEEP_SIZE)
		if !write_entry_back(fsys, &entry, entry_cluster, entry_offset, entry_idx) {
			return fuse3.nix(.EIO)
		}
		path_cache_invalidate_all(fsys)
		return 0
	}
	if total_sectors > current_sectors {
		new_c, new_o, aerr := fs.allocate_sectors(
			&fsys.master, fsys.disk, &fsys.alloc_cache,
			data_cluster, data_offset,
			total_sectors, .File_Content)
		if aerr != .None {
			return fuse3.nix(.ENOSPC)
		}
		if data_cluster == 0 {
			entry.stored_cluster = u64(new_c)
			entry.sector_index = u16(new_o)
		}
	}
	if total_sectors > current_sectors {
		zero_start := u64(entry.file_size)
		zero_end := max(alloc_start + alloc_len, zero_start)
		if zero_end > zero_start {
			zok := zero_file_range(fsys, &entry, data_cluster, data_offset, zero_start, zero_end)
			if !zok {
				return fuse3.nix(.EIO)
			}
		}
	}
	if mode & fuse3.FALLOC_FL_KEEP_SIZE == 0 {
		new_size := max(u64(entry.file_size), alloc_start + alloc_len)
		if new_size != u64(entry.file_size) {
			set_entry_time_to_now(&entry)
			entry.file_size = new_size
		}
	}
	if !write_entry_back(fsys, &entry, entry_cluster, entry_offset, entry_idx) {
		return fuse3.nix(.EIO)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("fallocate: %s off=%d len=%d mode=%d", path, off, length, mode)
	return 0
}

fused_utimens :: proc "c" (path: cstring, tv: [^]posix.timespec, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	sync.mutex_lock(&fsys.mu)
	defer sync.mutex_unlock(&fsys.mu)

	entry: fs.Directory_Entry
	entry_cluster: fs.Cluster
	entry_offset: fs.Sector_Offset
	entry_idx: int
	if fi != nil {
		entry_cluster, entry_offset, entry_idx = unpack_fh(fi.fh)
		e, _, _, ok := read_entry_from_fh(fsys, fi.fh)
		if !ok {return fuse3.nix(.ENOENT)}
		entry = e
	} else {
		e, c, o, i, ok := resolve_path_cached(fsys, string(path), context.temp_allocator)
		if !ok {return fuse3.nix(.ENOENT)}

		entry = e
		entry_cluster = c
		entry_offset = o
		entry_idx = i
	}
	if tv == nil {
		set_entry_time_to_now(&entry)
	} else {
		nsec1 := int(tv[1].tv_nsec)
		if nsec1 == UTIME_OMIT {
		} else if nsec1 == UTIME_NOW {
			set_entry_mtime_to_now(&entry)
		} else {
			set_entry_mtime_from_unix(&entry, i64(tv[1].tv_sec))
		}

		nsec0 := int(tv[0].tv_nsec)
		if nsec0 == UTIME_OMIT {
		} else if nsec0 == UTIME_NOW {
			set_entry_atime_to_now(&entry)
		} else {
			set_entry_atime_from_unix(&entry, i64(tv[0].tv_sec))
		}
	}
	if !write_entry_back(fsys, &entry, entry_cluster, entry_offset, entry_idx) {
		return fuse3.nix(.EIO)
	}
	lru.remove(&fsys.path_cache, string(path))
	return 0
}

fused_rename :: proc "c" (oldpath: cstring, newpath: cstring, flags: c.uint) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	sync.mutex_lock(&fsys.mu)
	defer sync.mutex_unlock(&fsys.mu)

	if u32(flags) & u32(fuse3.RENAME_NOREPLACE) != 0 {
		log.debugf("rename: RENAME_NOREPLACE not supported")
		return fuse3.nix(.ENOSYS)
	}
	if u32(flags) & u32(fuse3.RENAME_EXCHANGE) != 0 {
		log.debugf("rename: RENAME_EXCHANGE not supported")
		return fuse3.nix(.ENOSYS)
	}

	entry, old_cluster, old_offset, old_idx, ok := resolve_path_cached(fsys, string(oldpath), context.temp_allocator)
	if !ok {
		log.debugf("rename: %s → ENOENT", oldpath)
		return fuse3.nix(.ENOENT)
	}

	new_parent_path, new_name := os.split_path(string(newpath))
	_, new_parent_c, new_parent_o, _, np_ok := resolve_path_cached(fsys, new_parent_path, context.temp_allocator)
	if !np_ok {
		log.debugf("rename: %s → parent ENOENT", newpath)
		return fuse3.nix(.ENOENT)
	}
	if old_cluster == new_parent_c && old_offset == new_parent_o {
		if dst_entry, _, _, dst_idx, dst_ok := resolve_path_cached(fsys, string(newpath), context.temp_allocator); dst_ok {
			if .Directory not_in dst_entry.flags {
				if dst_entry.stored_cluster != 0 {
					if derr := fs.deallocate_sectors(&fsys.master, fsys.disk, &fsys.alloc_cache, fs.Cluster(dst_entry.stored_cluster), fs.Sector_Offset(dst_entry.sector_index)); derr != .None {
						return fuse3.nix(.EIO)
					}
				}

				dst_entry.flags = {}
				if !write_entry_back(fsys, &dst_entry, new_parent_c, new_parent_o, dst_idx) {
					return fuse3.nix(.EIO)
				}
			} else {
				log.debugf("rename: %s → %s → EISDIR (destination is dir)", oldpath, newpath)
				return fuse3.nix(.EISDIR)
			}
		}
		if !set_entry_name(fsys, &entry, new_name) {
			return fuse3.nix(.ENOSPC)
		}
		if !write_entry_back(fsys, &entry, old_cluster, old_offset, old_idx) {
			return fuse3.nix(.EIO)
		}

		path_cache_invalidate_all(fsys)
		log.debugf("rename: %s → %s ok", oldpath, newpath)
		return 0
	}
	if .Directory in entry.flags {
		check_path := new_parent_path
		for check_path != "/" {
			check_entry, _, _, _, check_ok := resolve_path_cached(fsys, check_path, context.temp_allocator)
			if !check_ok {
				break
			}
			if fs.Cluster(check_entry.stored_cluster) == old_cluster && fs.Sector_Offset(check_entry.sector_index) == old_offset {
				log.debugf("rename: %s → %s → EINVAL (circular)", oldpath, newpath)
				return fuse3.nix(.EINVAL)
			}

			parent_of_check, _ := os.split_path(check_path)
			check_path = parent_of_check
		}
	}

	dst_idx := -1
	if dst_entry, _, _, dst_idx_resolved, dst_ok := resolve_path_cached(fsys, string(newpath), context.temp_allocator); dst_ok {
		dst_idx = dst_idx_resolved
		if .Directory not_in dst_entry.flags {
			if dst_entry.stored_cluster != 0 {
				if derr := fs.deallocate_sectors(&fsys.master, fsys.disk, &fsys.alloc_cache, fs.Cluster(dst_entry.stored_cluster), fs.Sector_Offset(dst_entry.sector_index)); derr != .None {
					return fuse3.nix(.EIO)
				}
			}

			dst_entry.flags = {}
			if !write_entry_back(fsys, &dst_entry, new_parent_c, new_parent_o, dst_idx) {
				return fuse3.nix(.EIO)
			}
		} else {
			log.debugf("rename: %s → %s → EISDIR (destination is dir)", oldpath, newpath)
			return fuse3.nix(.EISDIR)
		}
	}

	dst_cluster, dst_sec, dst_slot_idx, slot_ok := find_or_extend_dir(fsys, new_parent_c, new_parent_o)
	if !slot_ok {
		return fuse3.nix(.ENOSPC)
	}
	if !set_entry_name(fsys, &entry, new_name) {
		return fuse3.nix(.ENOSPC)
	}
	if !fs.write_directory_entry_at(fsys.disk, &fsys.master, dst_cluster, dst_sec, dst_slot_idx, &entry) {
		return fuse3.nix(.EIO)
	}

	entry.flags = {}
	if !write_entry_back(fsys, &entry, old_cluster, old_offset, old_idx) {
		return fuse3.nix(.EIO)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("rename: %s → %s ok (cross-directory)", oldpath, newpath)
	return 0
}

fused_access :: proc "c" (path: cstring, mask: c.int) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	sync.mutex_lock(&fsys.mu)
	defer sync.mutex_unlock(&fsys.mu)

	entry, _, _, _, ok := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if !ok {
		return fuse3.nix(.ENOENT)
	}

	m := transmute(posix.Mode_Flags)(mask)
	if (posix.Mode_Flag_Bits.R_OK in m) && .No_Read in entry.flags {
		return fuse3.nix(.EACCES)
	}
	if (posix.Mode_Flag_Bits.W_OK in m) && (.No_Write in entry.flags || .Read_Only in entry.flags) {
		return fuse3.nix(.EACCES)
	}
	if (posix.Mode_Flag_Bits.X_OK in m) && .No_Execute in entry.flags {
		if .Directory not_in entry.flags {
			return fuse3.nix(.EACCES)
		}
	}
	log.debugf("access: %s → mask=%d ok", path, mask)
	return 0
}

fused_chmod :: proc "c" (path: cstring, mode: posix.mode_t, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	sync.mutex_lock(&fsys.mu)
	defer sync.mutex_unlock(&fsys.mu)

	entry: fs.Directory_Entry
	entry_cluster: fs.Cluster
	entry_offset: fs.Sector_Offset
	entry_idx: int
	if fi != nil {
		e, _, _, ok := read_entry_from_fh(fsys, fi.fh)
		if !ok {
			return fuse3.nix(.ENOENT)
		}

		entry = e
		entry_cluster, entry_offset, entry_idx = unpack_fh(fi.fh)
	} else {
		e, c, o, i, ok := resolve_path_cached(fsys, string(path), context.temp_allocator)
		if !ok {
			return fuse3.nix(.ENOENT)
		}

		entry = e
		entry_cluster, entry_offset, entry_idx = c, o, i
	}

	mr := posix.mode_t{.IRUSR, .IRGRP, .IROTH} & mode
	has_read := mr != {}
	mw := posix.mode_t{.IWUSR, .IWGRP, .IWOTH} & mode
	has_write := mw != {}
	mx := posix.mode_t{.IXUSR, .IXGRP, .IXOTH} & mode
	has_exec := mx != {}

	if has_read {entry.flags -= {.No_Read}} else {entry.flags += {.No_Read}}
	if has_write {entry.flags -= {.No_Write, .Read_Only}} else {entry.flags += {.No_Write, .Read_Only}}
	if has_exec {entry.flags -= {.No_Execute}} else {entry.flags += {.No_Execute}}
	if !write_entry_back(fsys, &entry, entry_cluster, entry_offset, entry_idx) {
		return fuse3.nix(.EIO)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("chmod: %s → mode=%v", path, mode)
	return 0
}

fused_chown :: proc "c" (path: cstring, uid: posix.uid_t, gid: posix.gid_t, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	sync.mutex_lock(&fsys.mu)
	defer sync.mutex_unlock(&fsys.mu)

	entry: fs.Directory_Entry
	entry_cluster: fs.Cluster
	entry_offset: fs.Sector_Offset
	entry_idx: int
	if fi != nil {
		e, _, _, ok := read_entry_from_fh(fsys, fi.fh)
		if !ok {return fuse3.nix(.ENOENT)}
		entry = e
		entry_cluster, entry_offset, entry_idx = unpack_fh(fi.fh)
	} else {
		e, c, o, i, ok := resolve_path_cached(fsys, string(path), context.temp_allocator)
		if !ok {return fuse3.nix(.ENOENT)}
		entry = e
		entry_cluster, entry_offset, entry_idx = c, o, i
	}

	uid_t_max :: posix.uid_t(0xFFFFFFFF)
	gid_t_max :: posix.gid_t(0xFFFFFFFF)
	if uid != uid_t_max {
		entry.uid = u32(uid)
	}
	if gid != gid_t_max {
		entry.gid = u32(gid)
	}
	if !write_entry_back(fsys, &entry, entry_cluster, entry_offset, entry_idx) {
		return fuse3.nix(.EIO)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("chown: %s → uid=%d gid=%d", path, entry.uid, entry.gid)
	return 0
}

fused_flush :: proc "c" (path: cstring, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	os.sync(fsys.disk)
	log.debugf("flush: %s → ok", path)
	return 0
}

fused_release :: proc "c" (path: cstring, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	log.debugf("release: %s → ok", path)
	return 0
}

fused_readlink :: proc "c" (path: cstring, buf: [^]c.char, size: c.size_t) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	sync.mutex_lock(&fsys.mu)
	defer sync.mutex_unlock(&fsys.mu)

	entry, _, _, _, ok := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if !ok {
		return fuse3.nix(.ENOENT)
	}
	if .Link not_in entry.flags {
		return fuse3.nix(.EINVAL)
	}
	if entry.stored_cluster == 0 {
		return fuse3.nix(.EIO)
	}

	runs, rok := fs.resolve_extents(fsys.disk, &fsys.master, fs.Cluster(entry.stored_cluster), fs.Sector_Offset(entry.sector_index))
	if !rok {
		return fuse3.nix(.EIO)
	}

	sector_buf: [fs.SECTOR_SIZE]u8
	if !fs.sector_read(fsys.disk, runs[0].sector, sector_buf[:]) {
		return fuse3.nix(.EIO)
	}

	clen := min(int(size) - 1, int(entry.file_size))
	mem.copy(rawptr(buf), raw_data(sector_buf[:]), clen)
	buf[clen] = 0
	log.debugf("readlink: %s → %d bytes", path, clen)
	return 0
}

find_sector_at_offset :: proc(runs: []fs.Extent_Run, file_off: u64) -> (sec: fs.Sector, offset_in_sector: u64, ok: bool) {
	pos: u64 = 0
	for run in runs {
		run_bytes := u64(run.count) * fs.SECTOR_SIZE
		if pos + run_bytes > file_off {
			skip := file_off - pos
			return fs.Sector(u64(run.sector) + skip / fs.SECTOR_SIZE), skip % fs.SECTOR_SIZE, true
		}
		pos += run_bytes
	}
	return 0, 0, false
}

fused_copy_file_range :: proc "c" (
	path_in:  cstring,
	fi_in:    ^fuse3.File_Info,
	off_in:   posix.off_t,
	path_out: cstring,
	fi_out:   ^fuse3.File_Info,
	off_out:  posix.off_t,
	size:     c.size_t,
	flags:    c.int,
) -> c.ssize_t {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	log.debugf("copy_file_range: path_in=%s size=%d off_in=%d off_out=%d", path_in, size, off_in, off_out)
	sync.mutex_lock(&fsys.mu)
	defer sync.mutex_unlock(&fsys.mu)

	_, src_cluster, src_offset, src_ok := read_entry_from_fh(fsys, fi_in.fh)
	if !src_ok {
		return c.ssize_t(-int(fuse3.nix(.ENOENT)))
	}

	dst_entry, dst_cluster, dst_offset, dst_ok := read_entry_from_fh(fsys, fi_out.fh)
	if !dst_ok {
		return c.ssize_t(-int(fuse3.nix(.ENOENT)))
	}

	dst_cluster2, dst_offset2, dst_idx := unpack_fh(fi_out.fh)
	src_runs, src_rok := fs.resolve_extents(fsys.disk, &fsys.master, src_cluster, src_offset)
	if !src_rok {
		return c.ssize_t(-int(fuse3.nix(.ENOENT)))
	}

	dst_runs, dst_rok := fs.resolve_extents(fsys.disk, &fsys.master, dst_cluster, dst_offset)
	if !dst_rok {dst_runs = {}}

	src_off := u64(off_in)
	dst_off := u64(off_out)
	dst_total_sectors := (dst_off + u64(size) + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE
	dst_current: u64
	for r in dst_runs {dst_current += u64(r.count)}
	if dst_total_sectors > dst_current {
		new_c, new_o, aerr := fs.allocate_sectors(
			&fsys.master, fsys.disk, &fsys.alloc_cache,
			dst_cluster, dst_offset, dst_total_sectors, .File_Content)
		if aerr != .None {return c.ssize_t(-int(fuse3.nix(.ENOSPC)))}
		if dst_cluster == 0 {
			dst_entry.stored_cluster = u64(new_c)
			dst_entry.sector_index = u16(new_o)
			dst_cluster = new_c
			dst_offset = new_o
		}
		dst_runs, dst_rok = fs.resolve_extents(fsys.disk, &fsys.master, dst_cluster, dst_offset)
		if !dst_rok {return c.ssize_t(-int(fuse3.nix(.ENOENT)))}
	}

	read_sector: [fs.SECTOR_SIZE]u8
	bytes_copied: u64 = 0
	remaining := u64(size)
	for remaining > 0 {
		src_sec, src_sec_off, src_found := find_sector_at_offset(src_runs[:], src_off)
		if !src_found {break}
		if !fs.sector_read(fsys.disk, src_sec, read_sector[:]) {break}

		take := min(remaining, fs.SECTOR_SIZE - src_sec_off)
		dst_sec, dst_sec_off, dst_found := find_sector_at_offset(dst_runs[:], dst_off)
		if !dst_found {break}
		if dst_sec_off != 0 || take < fs.SECTOR_SIZE {
			dst_buf: [fs.SECTOR_SIZE]u8
			if !fs.sector_read(fsys.disk, dst_sec, dst_buf[:]) {break}
			copy(dst_buf[dst_sec_off:], read_sector[src_sec_off:][:take])
			if !fs.sector_write(fsys.disk, dst_sec, dst_buf[:]) {break}
		} else {
			if !fs.sector_write(fsys.disk, dst_sec, read_sector[src_sec_off:][:take]) {break}
		}

		bytes_copied += take
		remaining -= take
		src_off += take
		dst_off += take
	}

	new_size := max(u64(dst_entry.file_size), dst_off)
	if new_size != u64(dst_entry.file_size) {
		set_entry_time_to_now(&dst_entry)
		dst_entry.file_size = new_size
		if !write_entry_back(fsys, &dst_entry, dst_cluster2, dst_offset2, dst_idx) {
			return c.ssize_t(-int(fuse3.nix(.EIO)))
		}
	}

	path_cache_invalidate_all(fsys)
	log.debugf("copy_file_range: %s → %s  %d bytes", path_in, path_out, bytes_copied)
	return c.ssize_t(bytes_copied)
}

fused_opendir :: proc "c" (path: cstring, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	return 0
}

fused_releasedir :: proc "c" (path: cstring, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	return 0
}

fused_fsync :: proc "c" (path: cstring, datasync: c.int, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	os.sync(fsys.disk)
	return 0
}

fused_lseek :: proc "c" (path: cstring, off: posix.off_t, whence: c.int, fi: ^fuse3.File_Info) -> posix.off_t {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	sync.mutex_lock(&fsys.mu)
	defer sync.mutex_unlock(&fsys.mu)

	if whence != fuse3.SEEK_DATA && whence != fuse3.SEEK_HOLE {
		return posix.off_t(-int(fuse3.nix(.ENOSYS)))
	}

	entry, data_cluster, data_offset, ok := read_entry_from_fh(fsys, fi.fh)
	if !ok {
		return posix.off_t(-int(fuse3.nix(.ENOENT)))
	}

	runs, rok := fs.resolve_extents(fsys.disk, &fsys.master, data_cluster, data_offset)
	if !rok {
		return posix.off_t(-int(fuse3.nix(.ENOENT)))
	}

	pos := u64(off)
	file_size := u64(entry.file_size)
	if len(runs) == 0 {
		if whence == fuse3.SEEK_DATA {
			return posix.off_t(file_size)
		}
		return posix.off_t(pos)
	}

	// Walk extent runs in file-offset space
	offset: u64 = 0
	if whence == fuse3.SEEK_DATA {
		for run in runs {
			run_end := offset + u64(run.count) * fs.SECTOR_SIZE
			if pos < run_end {
				return posix.off_t(max(pos, offset))
			}
			offset = run_end
		}
		return posix.off_t(file_size)
	}
	// SEEK_HOLE
	for run in runs {
		run_end := offset + u64(run.count) * fs.SECTOR_SIZE
		if pos < offset {
			return posix.off_t(pos)
		}
		if pos >= offset && pos < run_end {
			pos = run_end
		}
		offset = run_end
	}
	if pos < file_size {
		return posix.off_t(pos)
	}
	return posix.off_t(file_size)
}

fused_statfs :: proc "c" (path: cstring, stbuf: ^posix.statvfs_t) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	total_sectors := fsys.image_size / fs.SECTOR_SIZE
	free_sectors := fs.alloc_cache_count_free(&fsys.alloc_cache, &fsys.master, fsys.disk)
	stbuf^ = {
		f_bsize   = c.ulong(fs.SECTOR_SIZE),
		f_frsize  = c.ulong(fs.SECTOR_SIZE),
		f_blocks  = posix.fsblkcnt_t(total_sectors),
		f_bfree   = posix.fsblkcnt_t(free_sectors),
		f_bavail  = posix.fsblkcnt_t(free_sectors),
		f_files   = posix.fsblkcnt_t(fsys.master.cluster_map_size * u64(dir_entries_per_buf(fsys.master.features))),
		f_ffree   = posix.fsblkcnt_t(fsys.master.cluster_map_size * u64(dir_entries_per_buf(fsys.master.features))),
		f_favail  = posix.fsblkcnt_t(fsys.master.cluster_map_size * u64(dir_entries_per_buf(fsys.master.features))),
		f_flag    = posix.VFS_Flags{},
		f_namemax = c.ulong(255),
	}
	return 0
}

fused_init :: proc "c" (conn_info: ^fuse3.Conn_Info, cfg: ^fuse3.Config) -> rawptr {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	conn_info.time_gran = 1
	conn_info.max_background = 16
	conn_info.congestion_threshold = 12
	log.debugf("init: fused rev %d, cluster_size=%d", fsys.master.rev_max, fsys.master.cluster_size)
	return fsys
}

fused_destroy :: proc "c" (private_data: rawptr) {
	context = runtime.default_context()
	fsys := (^FS)(private_data)
	context.logger = fsys.logger
	log.debugf("destroy: fused unmounting")
}

fused_fsyncdir :: proc "c" (path: cstring, datasync: c.int, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	os.sync(fsys.disk)
	return 0
}

fused_mknod :: proc "c" (path: cstring, mode: posix.mode_t, rdev: posix.dev_t) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	return -posix.ENOSYS
}

fused_ioctl :: proc "c" (path: cstring, cmd: c.int, arg: rawptr, fi: ^fuse3.File_Info, flags: c.uint, data: rawptr) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	return -posix.ENOSYS
}

fused_link :: proc "c" (oldpath: cstring, newpath: cstring) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	return -posix.ENOSYS
}

fused_statx :: proc "c" (path: cstring, flags: c.int, mask: c.int, stxbuf: rawptr, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	return -posix.ENOSYS
}
