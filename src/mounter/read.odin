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

@(private="file")
Readdir_Ctx :: struct {
	fsys:        ^FS,
	depc:      int,
	sector_buf:  [fs.SECTOR_SIZE]u8,
	dir_cluster: fs.Cluster,
	filler:      fuse3.Fill_Dir_Proc,
	buf:         rawptr,
	e:           int,
	stop_rc:     c.int,
}

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

	// Mode construction is table-driven: pick a base profile by entry kind,
	// then clear permission bits that the entry's flags deny. A new Dir_Flag
	// that affects permissions only needs one subtraction line here.
	base_mode: posix.mode_t
	base_nlink: posix.nlink_t
	switch {
	case .Link in entry.flags:
		base_mode = {.IFREG, .IFCHR, .IRUSR, .IWUSR, .IRGRP, .IROTH}
		base_nlink = posix.nlink_t(1)
	case .Directory in entry.flags:
		base_mode = {.IFDIR, .IRUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH}
		base_nlink = posix.nlink_t(2)
	case:
		base_mode = {.IFREG, .IRUSR, .IWUSR, .IRGRP, .IROTH}
		base_nlink = posix.nlink_t(1)
	}
	if .No_Read in entry.flags {
		base_mode -= {.IRUSR, .IRGRP, .IROTH}
	}
	if .No_Write in entry.flags || .Read_Only in entry.flags {
		base_mode -= {.IWUSR, .IWGRP, .IWOTH}
	}
	// Directories gate execute separately; regular files and links never had it.
	if .Directory in entry.flags && .No_Execute in entry.flags {
		base_mode -= {.IXUSR, .IXGRP, .IXOTH}
	} else if .Directory not_in entry.flags {
		// Links and regular files: No_Execute is not applicable (they never
		// had exec bits in base_mode), so nothing to clear.
	}

	stbuf.st_mode = base_mode
	stbuf.st_nlink = base_nlink
	if .Directory not_in entry.flags {
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

	sync.mutex_unlock(&fsys.mu)
	if rc := fuse3.fill_dir(filler, buf, ".", nil); rc != 0 {
		return rc
	}
	if rc := fuse3.fill_dir(filler, buf, "..", nil); rc != 0 {
		return rc
	}

	visit := proc(sec: fs.Sector, user: rawptr) -> bool {
		ctx := (^Readdir_Ctx)(user)
		if fs.sector_read(&ctx.fsys.vol, sec, ctx.sector_buf[:]) != .None {
			ctx.stop_rc = fuse3.nix(.EIO)
			return false
		}
		for i in 0 ..< ctx.depc {
			if .Exists in get_dir_entry(ctx.sector_buf[:], i, ctx.fsys.vol.master.features).flags {
				name := fs.entry_short_name(get_dir_entry(ctx.sector_buf[:], i, ctx.fsys.vol.master.features))
				if .LFN in get_dir_entry(ctx.sector_buf[:], i, ctx.fsys.vol.master.features).flags {
					// LFN cache is read-only after setup, safe without lock
					sec_off := fs.Sector_Offset(u64(sec) - u64(ctx.dir_cluster) * ctx.fsys.vol.master.cluster_size)
					cache_k := lfn_cache_key(ctx.dir_cluster, sec_off, i)
					if cached, hit := lru.get(&ctx.fsys.lfn_cache, cache_k); hit {
						name = cached
					} else {
						lfn, l_ok := fs.resolve_lfn(&ctx.fsys.vol, get_dir_entry(ctx.sector_buf[:], i, ctx.fsys.vol.master.features))
						if l_ok {
							name = lfn
							c := strings.clone(name, context.allocator)
							lru.set(&ctx.fsys.lfn_cache, cache_k, c)
						}
					}
				}

				name_cstr := strings.clone_to_cstring(name) or_continue
				if rc := fuse3.fill_dir(ctx.filler, ctx.buf, name_cstr, nil); rc != 0 {
					delete(name_cstr)
					ctx.stop_rc = rc
					return false
				}
				delete(name_cstr)
				ctx.e += 1
			}
		}
		return true
	}

	ctx := Readdir_Ctx{fsys = fsys, depc = depc, dir_cluster = dir_cluster, filler = filler, buf = buf}
	if werr := fs.walk_chain_sectors(&fsys.vol, dir_cluster, dir_offset, visit, &ctx); werr != .None {
		log.debugf("readdir: %s → extent resolve failed", path)
		return fuse3.nix(.ENOENT)
	}
	if ctx.stop_rc != 0 {
		return ctx.stop_rc
	}

	e := ctx.e
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

	runs, ext_ok := resolve_extents_cached(fsys, data_cluster, data_offset)
	if !ext_ok {
		return fuse3.nix(.ENOENT)
	}

	mem_sink := Mem_Read_Sink{fsys = fsys, buf = ([^]u8)(buf), size = u64(size), remaining = u64(size)}
	sink := Read_Sink{
		user      = &mem_sink,
		copy_to   = _mem_read_copy_to,
		bulk      = _mem_read_bulk,
		remaining = _mem_read_remaining,
	}

	bytes_read := read_range_from_runs(fsys, runs, u64(off), &sink)
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

	runs, ext_ok := resolve_extents_cached(fsys, data_cluster, data_offset)
	if !ext_ok {
		return fuse3.nix(.ENOENT)
	}

	slices, total_provided := collect_read_slices(runs, u64(off), u64(size), context.temp_allocator)
	defer delete(slices)
	if len(slices) == 0 {
		return fuse3.nix(.ENOENT)
	}

	buf_count := len(slices)
	alloc_size := c.size_t(size_of(fuse3.Bufvec) + (buf_count - 1) * size_of(fuse3.Buf))
	bv := (^fuse3.Bufvec)(posix.malloc(alloc_size))
	if bv == nil {
		return fuse3.nix(.ENOMEM)
	}

	bv.count = c.size_t(buf_count)
	bv.idx = 0
	bv.off = 0
	bufs := slice.from_ptr(&bv._buf[0], int(bv.count))
	for s, i in slices {
		bufs[i].size = c.size_t(s.len)
		bufs[i].flags = fuse3.FUSE_BUF_IS_FD | fuse3.FUSE_BUF_FD_SEEK
		bufs[i].fd = fsys.disk_raw_fd
		bufs[i].pos = posix.off_t(u64(s.sector) * fs.SECTOR_SIZE)
		bufs[i].mem = nil
		bufs[i].mem_size = 0
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

	runs, ext_ok := resolve_extents_cached(fsys, fs.Cluster(entry.stored_cluster), fs.Sector_Offset(entry.sector_index))
	if !ext_ok {
		return fuse3.nix(.EIO)
	}

	sector_buf: [fs.SECTOR_SIZE]u8
	if fs.sector_read(&fsys.vol, runs[0].sector, sector_buf[:]) != .None {
		return fuse3.nix(.EIO)
	}

	clen := min(int(size) - 1, int(entry.file_size))
	mem.copy(rawptr(buf), raw_data(sector_buf[:]), clen)
	buf[clen] = 0
	log.debugf("readlink: %s → %d bytes", path, clen)
	return 0
}
