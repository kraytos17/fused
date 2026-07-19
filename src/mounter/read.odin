// read.odin — FUSE read-related callbacks for the fused filesystem.
//
// Every callback retrieves its FS state via fuse_get_context().private_data
// (the get_fs() helper), eliminating package-level globals.
#+build linux
package mounter

import "base:runtime"
import "core:c"
import "core:container/lru"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"
import "src:fuse3"
import "src:fs"

// fused_getattr returns file or directory attributes (stat) for a path (FUSE
// getattr callback).
fused_getattr :: proc "c" (path: cstring, stbuf: ^fuse3.Stat, _: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)

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

// fused_readdir fills a directory listing using the FUSE filler callback.
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
	depc := dir_entries_per_buf(fsys.vol.master.features)
	entry, _, _, _, ok := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if !ok || .Directory not_in entry.flags {
		sync.mutex_unlock(&fsys.mu)
		log.debugf("readdir: %s → ENOENT/not-dir", path)
		return fuse3.nix(.ENOENT)
	}

	dir_cluster := fs.Cluster(entry.stored_cluster)
	dir_offset := fs.Sector_Offset(entry.sector_index)
	dir_runs, dir_err := fs.resolve_extents(&fsys.vol,dir_cluster, dir_offset)

	defer delete(dir_runs)
	sync.mutex_unlock(&fsys.mu)
	if dir_err != .None {
		log.debugf("readdir: %s → extent resolve failed", path)
		return fuse3.nix(.ENOENT)
	}
	if rc := fuse3.fill_dir(filler, buf, ".", nil); rc != 0 {
		return rc
	}
	if rc := fuse3.fill_dir(filler, buf, "..", nil); rc != 0 {
		return rc
	}

	e: int
	sector_buf: [fs.SECTOR_SIZE]u8
	for run in dir_runs {
		n := int(run.count)
		for si in 0 ..< n {
			sec := fs.Sector(u64(run.sector) + u64(si))
			if !fs.sector_read(&fsys.vol, sec, sector_buf[:]) {
				log.debugf("readdir: %s → sector read failed at %d", path, sec)
				break
			}
			for i in 0 ..< depc {
				if .Exists in get_dir_entry(sector_buf[:], i, fsys.vol.master.features).flags {
					name := fs.entry_short_name(get_dir_entry(sector_buf[:], i, fsys.vol.master.features))
					if .LFN in get_dir_entry(sector_buf[:], i, fsys.vol.master.features).flags {
						// LFN cache is read-only after setup, safe without lock
						sec_off := fs.Sector_Offset(u64(run.sector) + u64(si) - u64(dir_cluster) * fsys.vol.master.cluster_size)
						cache_k := lfn_cache_key(dir_cluster, sec_off, i)
						if cached, hit := lru.get(&fsys.lfn_cache, cache_k); hit {
							name = cached
						} else {
							lfn, l_ok := fs.resolve_lfn(&fsys.vol, get_dir_entry(sector_buf[:], i, fsys.vol.master.features))
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

// fused_open opens a file and stores the file handle in fi.fh.
fused_open :: proc "c" (path: cstring, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)

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

	fi.fh = transmute(u64)(fs.File_Handle{dir_cluster = u64(parent_cluster), dir_offset = u16(parent_offset), entry_index = u16(entry_idx)})
	log.debugf("open: %s → ok", path)
	return 0
}

// fused_read reads data from a file at a given offset.
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

	runs, ext_err := fs.resolve_extents(&fsys.vol, data_cluster, data_offset)
	defer delete(runs)
	if ext_err != .None {
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
			if !fs.sector_read(&fsys.vol, fs.Sector(start_sector), sector_buf[:]) {break}

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
				if !fs.sector_read(&fsys.vol, fs.Sector(start_sector), bulk_buf) {break}

				bytes_read += aligned_sectors * fs.SECTOR_SIZE
				pos_in_file += aligned_sectors * fs.SECTOR_SIZE
				start_sector += aligned_sectors
				remaining_in_run -= aligned_sectors
				if bytes_read >= u64(size) {break}
			}
			if remaining_in_run > 0 && bytes_read < u64(size) {
				if !fs.sector_read(&fsys.vol, fs.Sector(start_sector), sector_buf[:]) {break}

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

// fused_read_buf reads data with zero-copy splice support (FUSE read_buf
// callback).
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

	runs, ext_err := fs.resolve_extents(&fsys.vol, data_cluster, data_offset)
	defer delete(runs)
	if ext_err != .None {
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

// fused_readlink reads the target of a symbolic link.
fused_readlink :: proc "c" (path: cstring, buf: [^]c.char, size: c.size_t) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)

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

	runs, ext_err := fs.resolve_extents(&fsys.vol, fs.Cluster(entry.stored_cluster), fs.Sector_Offset(entry.sector_index))
	defer delete(runs)
	if ext_err != .None {
		return fuse3.nix(.EIO)
	}

	sector_buf: [fs.SECTOR_SIZE]u8
	if !fs.sector_read(&fsys.vol, runs[0].sector, sector_buf[:]) {
		return fuse3.nix(.EIO)
	}

	clen := min(int(size) - 1, int(entry.file_size))
	mem.copy(rawptr(buf), raw_data(sector_buf[:]), clen)
	buf[clen] = 0
	log.debugf("readlink: %s → %d bytes", path, clen)
	return 0
}
