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
import "core:strings"
import "core:sys/posix"
import "core:time"
import "src:fuse3"
import "src:fs"

// FS is the per-mount filesystem state, passed as fuse user_data.
FS :: struct {
	disk:        ^os.File,
	fd:          posix.FD,
	master:      fs.Master_Record,
	logger:      log.Logger,
	image_size:  u64,
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
	dir_ce, dir_ok := fs.find_cluster_entry(fsys.disk, &fsys.master, pc, po)
	if !dir_ok {
		return {}, 0, 0, false
	}

	buf: [fs.SECTOR_SIZE]u8
	data_sector := fs.Sector(u64(pc) * fsys.master.cluster_size + u64(dir_ce.sector_start))
	if !fs.sector_read(fsys.disk, data_sector, buf[:]) {
		return {}, 0, 0, false
	}

	entries := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(buf[:]))
	if idx < 0 || idx >= fs.DIR_ENTRIES_PER_SECTOR {
		return {}, 0, 0, false
	}
	e := entries[idx]
	if .Exists not_in e.flags {
		return {}, 0, 0, false
	}
	return e, fs.Cluster(e.stored_cluster), fs.Sector_Offset(e.sector_index), true
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
		dir_ce, dir_ok := fs.find_cluster_entry(fsys.disk, &fsys.master, current_cluster, current_offset)
		if !dir_ok {
			return {}, {}, {}, 0, false
		}

		dirs, dirs_ok := fs.read_directory_entries(fsys.disk, &fsys.master, current_cluster, fs.Sector_Offset(dir_ce.sector_start))
		if !dirs_ok {
			return {}, {}, {}, 0, false
		}

		found := false
		for &d, didx in dirs {
			if fs.entry_short_name(&d) == target {
				found = true
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

split_parent_name :: proc(path: string) -> (parent: string, name: string) {
	last_slash := 0
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' {
			last_slash = i + 1
			break
		}
	}

	parent = path[:max(last_slash, 1)]
	if len(parent) == 0 {
		parent = "/"
	}
	name = path[last_slash:]
	return
}

@(private)
write_entry_back :: proc(fsys: ^FS, entry: ^fs.Directory_Entry, cluster: fs.Cluster, offset: fs.Sector_Offset, index: int) -> bool {
	dir_ce := fs.find_cluster_entry(fsys.disk, &fsys.master, cluster, offset) or_return
	return fs.write_directory_entry_at(
		fsys.disk, &fsys.master,
		cluster, fs.Sector_Offset(dir_ce.sector_start),
		index, entry)
}

// find_free_slot_in_extent returns (absolute_sector, entry_index) for the first
// free slot found by scanning the directory's extent chain.
// Returns ok=false when no free slot exists (caller should extend the chain).
find_free_slot_in_extent :: proc(fsys: ^FS, dir_cluster: fs.Cluster, dir_offset: fs.Sector_Offset) -> (dsec: fs.Sector_Offset, didx: int, ok: bool) {
	dir_runs, dir_ok := fs.resolve_extents(fsys.disk, &fsys.master, dir_cluster, dir_offset)
	if !dir_ok {
		return {}, 0, false
	}

	scan_buf: [fs.SECTOR_SIZE]u8
	for run in dir_runs {
		n := int(run.count)
		for si in 0 ..< n {
			sec := fs.Sector(u64(run.sector) + u64(si))
			if !fs.sector_read(fsys.disk, sec, scan_buf[:]) {
				return {}, 0, false
			}

			raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(scan_buf[:]))
			for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
				zero_flags: fs.Dir_Flags
				if raw[i].flags == zero_flags {
					dsec = fs.Sector_Offset(u64(sec) - u64(dir_cluster) * fsys.master.cluster_size)
					return dsec, i, true
				}
			}
		}
	}
	return {}, 0, false
}

// find_or_extend_dir finds a free slot in a directory, extending the chain
// if needed. Returns (sector_offset, entry_index, ok).
find_or_extend_dir :: proc(fsys: ^FS, dir_cluster: fs.Cluster, dir_offset: fs.Sector_Offset) -> (dsec: fs.Sector_Offset, didx: int, ok: bool) {
	dsec, didx, ok = find_free_slot_in_extent(fsys, dir_cluster, dir_offset)
	if ok {
		return
	}

	_, _, ext_err := fs.allocate_sectors(&fsys.master, fsys.disk, &fsys.alloc_cache, dir_cluster, dir_offset, 1, .Directory)
	if ext_err != .None {
		return {}, 0, false
	}

	dir_runs, dir_ok := fs.resolve_extents(fsys.disk, &fsys.master, dir_cluster, dir_offset)
	if !dir_ok {
		return {}, 0, false
	}

	last_run := dir_runs[len(dir_runs) - 1]
	last_sec := fs.Sector(u64(last_run.sector) + u64(last_run.count) - 1)
	ext_buf: [fs.SECTOR_SIZE]u8
	if !fs.sector_read(fsys.disk, last_sec, ext_buf[:]) {
		return {}, 0, false
	}

	raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(ext_buf[:]))
	zero_flags: fs.Dir_Flags
	for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
		if raw[i].flags == zero_flags {
			dsec = fs.Sector_Offset(u64(last_sec) - u64(dir_cluster) * fsys.master.cluster_size)
			return dsec, i, true
		}
	}
	return {}, 0, false
}

// check_name_exists scans the directory for a name collision.
check_name_exists :: proc(fsys: ^FS, dir_cluster: fs.Cluster, dir_offset: fs.Sector_Offset, name: string) -> bool {
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

			raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(scan_buf[:]))
			for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
				if .Exists in raw[i].flags {
					if fs.entry_short_name(&raw[i]) == name {
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

		ptr := (^fs.LFN_Pointer)(raw_data(entry.file_name[:]))
		ptr.cluster = u64(fsys.lfn_bump.cluster)
		ptr.size = u32(len(name))
		ptr.sector = u16(fsys.lfn_bump.offset)
		ptr._pad = fsys.lfn_bump.next_byte
		entry.flags += {.LFN}

		fsys.lfn_bump.next_byte += needed
	} else {
		copy(entry.file_name[:], name)
		entry.file_name[min(15, len(name))] = 0
	}
	return true
}

fused_getattr :: proc "c" (path: cstring, stbuf: ^fuse3.Stat, _: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	entry, _, _, _, ok := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if !ok {
		log.debugf("getattr: %s → ENOENT", path)
		return fuse3.nix(.ENOENT)
	}

	stbuf^ = {}
	is_dir := .Directory in entry.flags
	if is_dir {
		stbuf.st_mode = posix.mode_t{posix.Mode_Bits.IFDIR, .IRUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH}
		stbuf.st_nlink = 2
	} else {
		stbuf.st_mode = posix.mode_t{posix.Mode_Bits.IFREG, .IRUSR, .IRGRP, .IROTH}
		stbuf.st_nlink = 1
		stbuf.st_size = posix.off_t(entry.file_size)
	}

	dt := entry.date_time
	ts := posix.time_t(
		i64(entry.year - 1970) * 365 * 86400 +
		i64(dt.date) * 86400 +
		i64(dt.hour) * 3600 +
		i64(dt.minute) * 60 +
		i64(dt.second),
	)

	stbuf.st_atim.tv_sec = ts
	stbuf.st_mtim.tv_sec = ts
	stbuf.st_ctim.tv_sec = ts
	log.debugf("getattr: %s → ok size=%d dir=%v", path, entry.file_size, is_dir)
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
	entry, _, _, _, ok := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if !ok || .Directory not_in entry.flags {
		log.debugf("readdir: %s → ENOENT/not-dir", path)
		return fuse3.nix(.ENOENT)
	}
	if rc := fuse3.fill_dir(filler, buf, ".", nil); rc != 0 {
		return rc
	}
	if rc := fuse3.fill_dir(filler, buf, "..", nil); rc != 0 {
		return rc
	}

	dir_cluster := fs.Cluster(entry.stored_cluster)
	dir_offset := fs.Sector_Offset(entry.sector_index)
	dir_runs, dir_ok := fs.resolve_extents(fsys.disk, &fsys.master, dir_cluster, dir_offset)
	if !dir_ok {
		return fuse3.nix(.ENOENT)
	}

	e: int
	sector_buf: [fs.SECTOR_SIZE]u8
	for run in dir_runs {
		n := int(run.count)
		for si in 0 ..< n {
			if !fs.sector_read(fsys.disk, fs.Sector(u64(run.sector) + u64(si)), sector_buf[:]) {
				break
			}

			raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(sector_buf[:]))
			for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
				if .Exists in raw[i].flags {
					name := fs.entry_short_name(&raw[i])
					if .LFN in raw[i].flags {
						sec_off := fs.Sector_Offset(u64(run.sector) + u64(si) - u64(dir_cluster) * fsys.master.cluster_size)
						cache_k := lfn_cache_key(dir_cluster, sec_off, i)
						if cached, hit := lru.get(&fsys.lfn_cache, cache_k); hit {
							name = cached
						} else {
							lfn, l_ok := fs.resolve_lfn(fsys.disk, &fsys.master, &raw[i])
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
	entry, parent_cluster, parent_offset, entry_idx, ok := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if !ok {
		log.debugf("open: %s → ENOENT", path)
		return fuse3.nix(.ENOENT)
	}
	if .Directory in entry.flags {
		log.debugf("open: %s → EISDIR", path)
		return fuse3.nix(.EISDIR)
	}
	fi.fh = (u64(parent_cluster) << 32) | (u64(parent_offset) << 16) | u64(entry_idx)
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
	log.debugf("read: %s off=%d size=%d → %d bytes", path, off, size, bytes_read)
	return c.int(bytes_read)
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
	if new_size != u64(entry.file_size) {
		set_entry_time_to_now(&entry)
		entry.file_size = new_size
		write_entry_back(fsys, &entry, entry_cluster, entry_offset, entry_idx)
	}
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
	lru.remove(&fsys.path_cache, string(path))
	return c.int(bytes_written)
}

fused_create :: proc "c" (path: cstring, mode: posix.mode_t, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	parent, name := split_parent_name(string(path))
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

	dsec, didx, slot_ok := find_or_extend_dir(fsys, dir_cluster, dir_offset)
	if !slot_ok {
		log.debugf("create: %s → ENOSPC (dir full)", path)
		return fuse3.nix(.ENOSPC)
	}

	flags := fs.Dir_Flags{.Allocated, .Exists}
	if .IFDIR in mode {
		flags += {.Directory}
	}

	new_entry: fs.Directory_Entry
	new_entry.flags = flags
	if !write_entry_with_lfn(fsys, &new_entry, name) {
		return fuse3.nix(.ENOSPC)
	}

	fs.write_directory_entry_at(fsys.disk, &fsys.master, dir_cluster, dsec, didx, &new_entry)
	fi.fh = (u64(dir_cluster) << 32) | (u64(dsec) << 16) | u64(didx)
	path_cache_invalidate_all(fsys)
	log.debugf("create: %s → ok", path)
	return 0
}

fused_mkdir :: proc "c" (path: cstring, mode: posix.mode_t) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	parent, name := split_parent_name(string(path))
	parent_entry, _, _, _, ok := resolve_path_cached(fsys, parent, context.temp_allocator)
	if !ok {
		return fuse3.nix(.ENOENT)
	}

	dir_cluster := fs.Cluster(parent_entry.stored_cluster)
	dir_offset := fs.Sector_Offset(parent_entry.sector_index)
	if check_name_exists(fsys, dir_cluster, dir_offset, name) {
		return fuse3.nix(.EEXIST)
	}

	dsec, didx, slot_ok := find_or_extend_dir(fsys, dir_cluster, dir_offset)
	if !slot_ok {
		return fuse3.nix(.ENOSPC)
	}

	new_cluster, new_offset, derr := fs.allocate_sectors(&fsys.master, fsys.disk, &fsys.alloc_cache, 0, 0, 1, .Directory)
	if derr != .None {
		return fuse3.nix(.ENOSPC)
	}

	dir_runs, _ := fs.resolve_extents(fsys.disk, &fsys.master, new_cluster, new_offset)
	zero: [fs.SECTOR_SIZE]u8
	fs.sector_write(fsys.disk, dir_runs[0].sector, zero[:])

	new_entry: fs.Directory_Entry
	new_entry.flags = fs.Dir_Flags{.Allocated, .Directory, .Exists}
	new_entry.sector_index = u16(new_offset)
	new_entry.stored_cluster = u64(new_cluster)

	set_entry_time_to_now(&new_entry)
	copy(new_entry.file_name[:], name)
	new_entry.file_name[min(15, len(name))] = 0

	fs.write_directory_entry_at(fsys.disk, &fsys.master, dir_cluster, dsec, didx, &new_entry)
	path_cache_invalidate_all(fsys)
	log.debugf("mkdir: %s → ok", path)
	return 0
}

fused_unlink :: proc "c" (path: cstring) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
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
		fs.deallocate_sectors(&fsys.master, fsys.disk, &fsys.alloc_cache, fs.Cluster(entry.stored_cluster), fs.Sector_Offset(entry.sector_index))
	}

	entry.flags = {}
	write_entry_back(fsys, &entry, cluster, offset, idx)
	path_cache_invalidate_all(fsys)
	log.debugf("unlink: %s → ok", path)
	return 0
}

fused_rmdir :: proc "c" (path: cstring) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	entry, cluster, offset, idx, ok := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if !ok {
		return fuse3.nix(.ENOENT)
	}
	if .Directory not_in entry.flags {
		log.debugf("rmdir: %s → ENOTDIR", path)
		return fuse3.nix(.ENOTDIR)
	}

	dirs, _ := fs.read_directory_entries(fsys.disk, &fsys.master, fs.Cluster(entry.stored_cluster), fs.Sector_Offset(entry.sector_index))
	for &d in dirs {
		if .Exists in d.flags {
			log.debugf("rmdir: %s → ENOTEMPTY", path)
			return fuse3.nix(.ENOTEMPTY)
		}
	}
	if entry.stored_cluster != 0 {
		fs.deallocate_sectors(&fsys.master, fsys.disk, &fsys.alloc_cache, fs.Cluster(entry.stored_cluster), fs.Sector_Offset(entry.sector_index))
	}

	entry.flags = {}
	write_entry_back(fsys, &entry, cluster, offset, idx)
	path_cache_invalidate_all(fsys)
	log.debugf("rmdir: %s → ok", path)
	return 0
}

fused_truncate :: proc "c" (path: cstring, size: posix.off_t, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	entry, data_cluster, data_offset, ok := read_entry_from_fh(fsys, fi.fh)
	if !ok {
		log.debugf("truncate: %s → ENOENT", path)
		return fuse3.nix(.ENOENT)
	}

	entry_cluster, entry_offset, entry_idx := unpack_fh(fi.fh)
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

			cntr += u64(ce.allocation_size)
			if cntr > new_sectors {
				if ce.next_cluster != 0 {
					next_c := fs.Cluster(ce.next_cluster)
					next_o := fs.Sector_Offset(ce.next_sector_index)
					fs.deallocate_sectors(&fsys.master, fsys.disk, &fsys.alloc_cache, next_c, next_o)
					ce.next_cluster = 0
					ce.next_sector_index = 0
					fs.write_cluster_entry_at(fsys.disk, &fsys.master, current_c, ce_idx, &ce)
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
	write_entry_back(fsys, &entry, entry_cluster, entry_offset, entry_idx)
	log.debugf("truncate: %s → %d", path, size)
	return 0
}

fused_utimens :: proc "c" (path: cstring, tv: [^]posix.timespec, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	entry_cluster, entry_offset, entry_idx := unpack_fh(fi.fh)
	entry, _, _, ok := read_entry_from_fh(fsys, fi.fh)
	if !ok {
		return fuse3.nix(.ENOENT)
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
	write_entry_back(fsys, &entry, entry_cluster, entry_offset, entry_idx)
	return 0
}

fused_rename :: proc "c" (oldpath: cstring, newpath: cstring, flags: c.uint) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
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

	new_parent_path, new_name := split_parent_name(string(newpath))
	_, new_parent_c, new_parent_o, _, np_ok := resolve_path_cached(fsys, new_parent_path, context.temp_allocator)
	if !np_ok {
		log.debugf("rename: %s → parent ENOENT", newpath)
		return fuse3.nix(.ENOENT)
	}
	if old_cluster == new_parent_c && old_offset == new_parent_o {
		if dst_entry, _, _, dst_idx, dst_ok := resolve_path_cached(fsys, string(newpath), context.temp_allocator); dst_ok {
			if .Directory not_in dst_entry.flags {
				if dst_entry.stored_cluster != 0 {
					fs.deallocate_sectors(&fsys.master, fsys.disk, &fsys.alloc_cache, fs.Cluster(dst_entry.stored_cluster), fs.Sector_Offset(dst_entry.sector_index))
				}
				dst_entry.flags = {}
				write_entry_back(fsys, &dst_entry, new_parent_c, new_parent_o, dst_idx)
			} else {
				log.debugf("rename: %s → %s → EISDIR (destination is dir)", oldpath, newpath)
				return fuse3.nix(.EISDIR)
			}
		}

		copy(entry.file_name[:], new_name)
		entry.file_name[min(15, len(new_name))] = 0
		write_entry_back(fsys, &entry, old_cluster, old_offset, old_idx)
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

			parent_of_check, _ := split_parent_name(check_path)
			check_path = parent_of_check
		}
	}

	dst_idx := -1
	if dst_entry, _, _, dst_idx_resolved, dst_ok := resolve_path_cached(fsys, string(newpath), context.temp_allocator); dst_ok {
		dst_idx = dst_idx_resolved
		if .Directory not_in dst_entry.flags {
			if dst_entry.stored_cluster != 0 {
				fs.deallocate_sectors(&fsys.master, fsys.disk, &fsys.alloc_cache, fs.Cluster(dst_entry.stored_cluster), fs.Sector_Offset(dst_entry.sector_index))
			}
			dst_entry.flags = {}
			write_entry_back(fsys, &dst_entry, new_parent_c, new_parent_o, dst_idx)
		} else {
			log.debugf("rename: %s → %s → EISDIR (destination is dir)", oldpath, newpath)
			return fuse3.nix(.EISDIR)
		}
	}

	dst_sec, dst_slot_idx, slot_ok := find_free_slot_in_extent(fsys, new_parent_c, new_parent_o)
	if !slot_ok {
		return fuse3.nix(.ENOSPC)
	}

	copy(entry.file_name[:], new_name)
	entry.file_name[min(15, len(new_name))] = 0
	fs.write_directory_entry_at(fsys.disk, &fsys.master, new_parent_c, dst_sec, dst_slot_idx, &entry)

	entry.flags = {}
	write_entry_back(fsys, &entry, old_cluster, old_offset, old_idx)
	path_cache_invalidate_all(fsys)
	log.debugf("rename: %s → %s ok (cross-directory)", oldpath, newpath)
	return 0
}

fused_access :: proc "c" (path: cstring, mask: c.int) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	_, _, _, _, ok := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if !ok {return fuse3.nix(.ENOENT)}
	return 0
}

fused_flush :: proc "c" (path: cstring, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	if fsys.fd >= 0 {
		posix.fsync(fsys.fd)
	}
	return 0
}

fused_release :: proc "c" (path: cstring, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	if fsys.fd >= 0 {
		posix.fsync(fsys.fd)
	}
	return 0
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
	if fsys.fd >= 0 {
		posix.fsync(fsys.fd)
	}
	return 0
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
		f_files   = posix.fsblkcnt_t(fsys.master.cluster_map_size * fs.DIR_ENTRIES_PER_SECTOR),
		f_ffree   = posix.fsblkcnt_t(fsys.master.cluster_map_size * fs.DIR_ENTRIES_PER_SECTOR),
		f_favail  = posix.fsblkcnt_t(fsys.master.cluster_map_size * fs.DIR_ENTRIES_PER_SECTOR),
		f_flag    = posix.VFS_Flags{},
		f_namemax = c.ulong(255),
	}
	return 0
}
