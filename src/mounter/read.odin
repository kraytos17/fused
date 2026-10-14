// read.odin — FUSE read-related callbacks for the fused filesystem.
//
// Every callback retrieves its FS state via fuse_get_context().private_data
// (the get_fs() helper), eliminating package-level globals.
#+build linux
package mounter

import "base:runtime"
import "core:c"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"
import "src:fs"
import "src:fuse3"

// fused_getattr returns file or directory attributes (stat) for a path (FUSE
// getattr callback).
fused_getattr :: proc "c" (path: cstring, stbuf: ^fuse3.Stat, _: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	context.logger = fsys.logger
	defer end_op(fsys)

	entry, _, _, _, rerr := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if rerr != .None {
		log.debugf("getattr: %s → %v", path, rerr)
		return fs_error_to_errno(rerr)
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
		i64(entry.year),
		i64(dt.month),
		i64(dt.date),
		i64(dt.hour),
		i64(dt.minute),
		i64(dt.second),
	)

	ts := posix.time_t(time.time_to_unix(t))
	stbuf.st_mtim.tv_sec = ts
	stbuf.st_ctim.tv_sec = ts
	at := entry.atime_date_time
	atime_t, _ := time.components_to_time(
		i64(entry.atime_year),
		i64(at.month),
		i64(at.date),
		i64(at.hour),
		i64(at.minute),
		i64(at.second),
	)

	stbuf.st_atim.tv_sec = posix.time_t(time.time_to_unix(atime_t))
	stbuf.st_uid = posix.uid_t(entry.uid)
	stbuf.st_gid = posix.gid_t(entry.gid)
	return 0
}

// fused_readdir fills a directory listing using the FUSE filler callback.
fused_readdir :: proc "c" (
	path: cstring,
	buf: rawptr,
	filler: fuse3.Fill_Dir_Proc,
	off: posix.off_t,
	_: ^fuse3.File_Info,
	flags: c.int,
) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	// Fast path: resolve the path and snapshot the listing under the write
	// lock (both may populate their caches), then release before the fill
	// phase. The fill below re-takes the read lock per LFN entry only;
	// short names come straight from the snapshot, and LFN names go
	// through lfn_lookup_shared, so concurrent writers are never blocked
	// by fill_dir.
	sync.rw_mutex_lock(&fsys.mu)
	entry, _, _, _, rerr := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if rerr != .None {
		sync.rw_mutex_unlock(&fsys.mu)
		log.debugf("readdir: %s → %v", path, rerr)
		return fs_error_to_errno(rerr)
	}
	if .Directory not_in entry.flags {
		sync.rw_mutex_unlock(&fsys.mu)
		log.debugf("readdir: %s → not-dir", path)
		return fuse3.nix(.ENOENT)
	}

	dir_cluster := fs.Cluster(entry.stored_cluster)
	dir_offset := fs.Sector_Offset(entry.sector_index)
	// Snapshot the listing while holding the write lock: the array is an
	// owned heap clone, safe to consume after unlock. On a warm dir cache
	// the fill below becomes pure memory scans — no sector I/O, no walk.
	snapshot, serr := fs.read_directory_entries(&fsys.vol, dir_cluster, dir_offset)
	sync.rw_mutex_unlock(&fsys.mu)
	if serr != .None {
		log.debugf("readdir: %s → entries failed", path)
		return fs_error_to_errno(serr)
	}
	defer delete(snapshot)
	if rc := fuse3.fill_dir(filler, buf, ".", nil); rc != 0 {
		return rc
	}
	if rc := fuse3.fill_dir(filler, buf, "..", nil); rc != 0 {
		return rc
	}

	e := 0
	for w in snapshot {
		ent := w.entry
		name := fs.entry_short_name(&ent)
		if .LFN in ent.flags {
			// Look up under the read lock; the helper upgrades to
			// exclusive internally on a miss. The borrowed string is
			// copied to temp before unlocking so fill_dir below runs
			// lock-free without stalling writers.
			cache_k := lfn_cache_key(fs.Chain_Location{dir_cluster, dir_offset}, w.index)
			sync.rw_mutex_shared_lock(&fsys.mu)
			lfn, l_ok := lfn_lookup_shared(fsys, cache_k, &fsys.vol, &ent)
			lfn_cstr: cstring
			if l_ok {
				lfn_cstr, _ = strings.clone_to_cstring(lfn, context.temp_allocator)
			}

			sync.rw_mutex_shared_unlock(&fsys.mu)
			if l_ok {
				if rc := fuse3.fill_dir(filler, buf, lfn_cstr, nil); rc != 0 {
					return rc
				}
			}

			e += 1
			continue
		}

		name_cstr := strings.clone_to_cstring(name, context.temp_allocator) or_continue
		if rc := fuse3.fill_dir(filler, buf, name_cstr, nil); rc != 0 {
			return rc
		}
		e += 1
	}
	log.debugf("readdir: %s → ok %d entries", path, e)
	return 0
}

// fused_open opens a file and stores the file handle in fi.fh.
fused_open :: proc "c" (path: cstring, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	context.logger = fsys.logger
	defer end_op(fsys)

	entry, parent_cluster, parent_offset, entry_idx, rerr := resolve_path_cached(
		fsys,
		string(path),
		context.temp_allocator,
	)
	if rerr != .None {
		log.debugf("open: %s → %v", path, rerr)
		return fs_error_to_errno(rerr)
	}
	if .Directory in entry.flags {
		log.debugf("open: %s → EISDIR", path)
		return fuse3.nix(.EISDIR)
	}

	open_flags := transmute(posix.O_Flags)(fi.flags) // TRANSMUTE: ABI word bit-view as flag set
	wants_write := .WRONLY in open_flags || .RDWR in open_flags
	if wants_write && (.No_Write in entry.flags || .Read_Only in entry.flags) {
		return fuse3.nix(.EACCES)
	}
	if !wants_write && .No_Read in entry.flags {
		return fuse3.nix(.EACCES)
	}

	fi.fh = transmute(u64)fs.make_file_handle(parent_cluster, parent_offset, entry_idx) // TRANSMUTE: bit_field File_Handle pack into u64 fh
	log.debugf("open: %s → ok", path)
	return 0
}

// fused_read reads data from a file at a given offset.
fused_read :: proc "c" (
	path: cstring,
	buf: [^]c.char,
	size: c.size_t,
	off: posix.off_t,
	fi: ^fuse3.File_Info,
) -> c.int {
	context = runtime.default_context()
	fsys := begin_read_op()
	context.logger = fsys.logger
	defer end_read_op(fsys)

	read_start := time.now()
	uoff, ook := checked_offset(off)
	if !ook {
		return fuse3.nix(.EINVAL)
	}

	_, data_cluster, data_offset, rerr := read_entry_from_fh(fsys, fi.fh)
	if rerr != .None {
		return fs_error_to_errno(rerr)
	}

	runs, xerr := resolve_extents_shared(fsys, fs.Chain_Location{data_cluster, data_offset})
	if xerr != .None {
		return fuse3.nix(.ENOENT)
	}

	mem_sink := Mem_Read_Sink {
		fsys      = fsys,
		buf       = ([^]u8)(buf),
		size      = u64(size),
		remaining = u64(size),
	}
	sink := Read_Sink {
		user      = &mem_sink,
		copy_to   = _mem_read_copy_to,
		bulk      = _mem_read_bulk,
		remaining = _mem_read_remaining,
	}

	bytes_read := read_range_from_runs(fsys, runs, uoff, &sink)
	log.debugf(
		"read: %s off=%d size=%d → %d bytes (%v)",
		path,
		off,
		size,
		bytes_read,
		time.since(read_start),
	)
	// Saturate: bytes_read cannot exceed the requested size, but the u64 →
	// c.int narrowing must be total on 64-bit.
	return c.int(min(bytes_read, u64(max(c.int))))
}

// fused_read_buf reads data with zero-copy splice support (FUSE read_buf
// callback).
fused_read_buf :: proc "c" (
	path: cstring,
	bufp: ^^fuse3.Bufvec,
	size: c.size_t,
	off: posix.off_t,
	fi: ^fuse3.File_Info,
) -> c.int {
	context = runtime.default_context()
	fsys := begin_read_op()
	context.logger = fsys.logger
	defer end_read_op(fsys)

	read_start := time.now()
	uoff, ook := checked_offset(off)
	if !ook {
		return fuse3.nix(.EINVAL)
	}

	_, data_cluster, data_offset, rerr := read_entry_from_fh(fsys, fi.fh)
	if rerr != .None {
		return fs_error_to_errno(rerr)
	}

	runs, xerr := resolve_extents_shared(fsys, fs.Chain_Location{data_cluster, data_offset})
	if xerr != .None {
		return fuse3.nix(.ENOENT)
	}

	slices, total_provided := collect_read_slices(
		runs,
		uoff,
		u64(size),
		context.temp_allocator,
	)

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
		bufs[i].flags = {.Is_Fd, .Fd_Seek}
		bufs[i].fd = fsys.disk_raw_fd
		bufs[i].pos = posix.off_t(u64(s.sector) * fs.SECTOR_SIZE)
		bufs[i].mem = nil
		bufs[i].mem_size = 0
	}

	bufp^ = bv
	log.debugf(
		"read_buf: %s off=%d size=%d → %d bytes (%d bufs, %v)",
		path,
		off,
		size,
		total_provided,
		buf_count,
		time.since(read_start),
	)
	// Saturate the u64 → c.int narrowing (total_provided ≤ requested size,
	// but the conversion must be total regardless).
	return c.int(min(total_provided, u64(max(c.int))))
}

// fused_readlink reads the target of a symbolic link.
fused_readlink :: proc "c" (path: cstring, buf: [^]c.char, size: c.size_t) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	context.logger = fsys.logger
	defer end_op(fsys)

	entry, _, _, _, rerr := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if rerr != .None {
		return fs_error_to_errno(rerr)
	}
	if .Link not_in entry.flags {
		return fuse3.nix(.EINVAL)
	}
	if entry.stored_cluster == 0 {
		return fuse3.nix(.EIO)
	}

	runs, xerr := resolve_extents_cached(
		fsys,
		fs.data_chain_of(entry),
	)
	if xerr != .None {
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
