// write.odin — write-related FUSE callbacks for the fused filesystem.
#+build linux
package mounter

import "base:runtime"
import "core:c"
import "core:log"
import "core:slice"
import "core:sys/posix"
import "core:time"
import "src:fuse3"
import "src:fs"

// fused_write writes data to a file at a given offset.
fused_write :: proc "c" (
	path: cstring,
	buf:  [^]c.char,
	size: c.size_t,
	off:  posix.off_t,
	fi:   ^fuse3.File_Info,
) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	write_start := time.now()
	defer end_op(fsys)

	entry, data_cluster, data_offset, ok := read_entry_from_fh(fsys, fi.fh)
	if !ok {
		log.debugf("write: %s → ENOENT", path)
		return fuse3.nix(.ENOENT)
	}

	fh := transmute(fs.File_Handle)(fi.fh)
	total_sectors := (u64(off) + u64(size) + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE
	runs: []fs.Extent_Run
	cerr: fs.FS_Error
	data_cluster, data_offset, runs, _, cerr = ensure_chain_covers(fsys, &entry, data_cluster, data_offset, total_sectors)
	if cerr != .None {
		if cerr == .No_Space {
			log.errorf("write: %s → ENOSPC", path)
			return fuse3.nix(.ENOSPC)
		}
		log.errorf("write: %s → extents failed", path)
		return fuse3.nix(.ENOENT)
	}

	// Metadata allocation is made durable by the journal's own sync
	// (journal_v2_commit); no extra fsync needed here.
	log.debugf("write: %s → enter write loop (runs=%d)", path, len(runs))
	write_off := u64(off)
	new_size := max(u64(entry.file_size), write_off + u64(size))
	mem_src := Mem_Source{fsys = fsys, buf = ([^]u8)(buf), size = u64(size), remaining = u64(size)}
	bytes_src := Buf_Source{
		user      = &mem_src,
		copy      = _mem_copy,
		bulk      = _mem_bulk,
		remaining = _mem_remaining,
	}

	bytes_written := write_range_to_runs(fsys, runs, write_off, &bytes_src)
	log.debugf("write: %s off=%d size=%d → %d bytes (%v)", path, off, size, bytes_written, time.since(write_start))
	return write_finish(fsys, &entry, fh, new_size, bytes_written)
}

// write_finish is the shared epilogue for write operations: updates file size
// and timestamps, writes the entry back, and invalidates caches.
write_finish :: proc(fsys: ^FS, entry: ^fs.Directory_Entry, fh: fs.File_Handle, new_size: u64, bytes_written: u64) -> c.int {
	if new_size != u64(entry.file_size) {
		set_entry_time_to_now(entry)
		entry.file_size = new_size
		write_entry_back(fsys, entry, fs.Cluster(fh.dir_cluster), fs.Sector_Offset(fh.dir_offset), int(fh.entry_index))
	}
	path_cache_invalidate_all(fsys)
	return c.int(bytes_written)
}

// fused_write_buf writes data with bufvec/splice support (FUSE write_buf
// callback).
fused_write_buf :: proc "c" (
	path: cstring,
	buf:  ^fuse3.Bufvec,
	off:  posix.off_t,
	fi:   ^fuse3.File_Info,
) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	write_start := time.now()
	defer end_op(fsys)

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

	fh := transmute(fs.File_Handle)(fi.fh)
	total_sectors := (u64(off) + total_size + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE
	runs: []fs.Extent_Run
	cerr: fs.FS_Error
	data_cluster, data_offset, runs, _, cerr = ensure_chain_covers(fsys, &entry, data_cluster, data_offset, total_sectors)
	if cerr != .None {
		if cerr == .No_Space {
			log.errorf("write_buf: %s → ENOSPC", path)
			return fuse3.nix(.ENOSPC)
		}
		log.errorf("write_buf: %s → extents failed", path)
		return fuse3.nix(.ENOENT)
	}

	log.debugf("write_buf: %s → enter write loop (runs=%d, bufs=%d)", path, len(runs), buf.count)
	write_off := u64(off)
	bufvec_src := Bufvec_Source{
		fsys    = fsys,
		bufs    = bufs,
		count   = u32(buf.count),
	}
	bytes_src := Buf_Source{
		user      = &bufvec_src,
		copy      = _bufvec_copy,
		bulk      = _bufvec_bulk,
		remaining = _bufvec_remaining,
	}

	bytes_written := write_range_to_runs(fsys, runs, write_off, &bytes_src)
	new_size := max(u64(entry.file_size), write_off + bytes_written)
	log.debugf("write_buf: %s off=%d → %d bytes (%v)", path, off, bytes_written, time.since(write_start))
	return write_finish(fsys, &entry, fh, new_size, bytes_written)
}

// fused_truncate truncates or extends a file to the given size.
fused_truncate :: proc "c" (path: cstring, size: posix.off_t, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)

	log.debugf("truncate: %s size=%d fi=%v", path, size, fi != nil)
	entry, entry_cluster, entry_offset, entry_idx, data_cluster, data_offset, resolved := resolve_entry(fsys, path, fi)
	if !resolved {
		log.debugf("truncate: %s → ENOENT", path)
		return fuse3.nix(.ENOENT)
	}
	if .Directory in entry.flags {
		log.debugf("truncate: %s → EISDIR", path)
		return fuse3.nix(.EISDIR)
	}

	new_sectors := (u64(size) + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE
	runs: []fs.Extent_Run
	cerr: fs.FS_Error
	data_cluster, data_offset, runs, _, cerr = ensure_chain_covers(fsys, &entry, data_cluster, data_offset, new_sectors)
	if cerr != .None {
		if cerr == .No_Space {
			return fuse3.nix(.ENOSPC)
		}
		return fuse3.nix(.ENOENT)
	}

	current_sectors := fs.chain_sector_count(runs)
	if new_sectors < current_sectors {
		if terr := fs.truncate_chain_at(&fsys.vol, fs.Cluster(entry.stored_cluster), fs.Sector_Offset(entry.sector_index), new_sectors); terr != .None {
			return fs_error_to_errno(terr)
		}
		fsys.free_sectors += current_sectors - new_sectors
	}

	set_entry_time_to_now(&entry)
	entry.file_size = u64(size)
	if !write_entry_back(fsys, &entry, entry_cluster, entry_offset, entry_idx) {
		return fuse3.nix(.EIO)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("truncate: %s → %d", path, size)
	return 0
}

// zero_file_range zeros a byte range within a file by reading partial sectors
// and writing full zeroed sectors where possible.
zero_file_range :: proc(fsys: ^FS, entry: ^fs.Directory_Entry, data_cluster: fs.Cluster, data_offset: fs.Sector_Offset, start: u64, end: u64) -> bool {
	if start >= end {return true}

	runs, ext_err := fs.resolve_extents(&fsys.vol, data_cluster, data_offset)
	defer delete(runs)
	if ext_err != .None {return false}

	zero_src := Zero_Source{fsys = fsys, remaining = end - start}
	bytes_src := Buf_Source{
		user      = &zero_src,
		copy      = _zero_copy,
		bulk      = _zero_bulk,
		remaining = _zero_remaining,
	}
	written := write_range_to_runs(fsys, runs[:], start, &bytes_src)
	return written == end - start
}

// fused_fallocate pre-allocates space for a file (supports PUNCH_HOLE and
// KEEP_SIZE).
fused_fallocate :: proc "c" (path: cstring, mode: c.int, off: posix.off_t, length: posix.off_t, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)
	if mode & (fuse3.FALLOC_FL_COLLAPSE_RANGE | fuse3.FALLOC_FL_INSERT_RANGE) != 0 {
		return fuse3.nix(.EOPNOTSUPP)
	}

	entry, data_cluster, data_offset, ok := read_entry_from_fh(fsys, fi.fh)
	if !ok {
		return fuse3.nix(.ENOENT)
	}
	if .Directory in entry.flags {
		return fuse3.nix(.EISDIR)
	}

	alloc_start := u64(off)
	alloc_len := u64(length)
	if mode & fuse3.FALLOC_FL_PUNCH_HOLE != 0 {
		punch_start := alloc_start
		punch_end := alloc_start + alloc_len
		zok := zero_file_range(fsys, &entry, data_cluster, data_offset, punch_start, punch_end)
		if !zok {
			return fuse3.nix(.EIO)
		}

		// Update file_size if needed (PUNCH_HOLE implies KEEP_SIZE)
		dir_cluster, dir_offset, entry_index := fh_parts(fi.fh)
		if !write_entry_back(fsys, &entry, dir_cluster, dir_offset, entry_index) {
			return fuse3.nix(.EIO)
		}
		path_cache_invalidate_all(fsys)
		return 0
	}

	total_sectors := (alloc_start + alloc_len + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE
	extended: bool
	cerr: fs.FS_Error
	data_cluster, data_offset, _, extended, cerr = ensure_chain_covers(fsys, &entry, data_cluster, data_offset, total_sectors)
	if cerr != .None {
		if cerr == .No_Space {
			return fuse3.nix(.ENOSPC)
		}
		return fuse3.nix(.ENOENT)
	}
	if extended {
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

	dir_cluster, dir_offset, entry_index := fh_parts(fi.fh)
	if !write_entry_back(fsys, &entry, dir_cluster, dir_offset, entry_index) {
		return fuse3.nix(.EIO)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("fallocate: %s off=%d len=%d mode=%d", path, off, length, mode)
	return 0
}

// fused_copy_file_range copies data between two files (FUSE copy_file_range
// callback).
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
	fsys := begin_op()
	log.debugf("copy_file_range: path_in=%s size=%d off_in=%d off_out=%d", path_in, size, off_in, off_out)
	defer end_op(fsys)

	_, src_cluster, src_offset, src_ok := read_entry_from_fh(fsys, fi_in.fh)
	if !src_ok {
		return c.ssize_t(-int(fuse3.nix(.ENOENT)))
	}

	dst_entry, dst_cluster, dst_offset, dst_ok := read_entry_from_fh(fsys, fi_out.fh)
	if !dst_ok {
		return c.ssize_t(-int(fuse3.nix(.ENOENT)))
	}

	src_runs, src_err := resolve_extents_cached(fsys, src_cluster, src_offset)
	if !src_err {
		return c.ssize_t(-int(fuse3.nix(.ENOENT)))
	}

	src_off := u64(off_in)
	dst_off := u64(off_out)
	dst_total_sectors := (dst_off + u64(size) + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE
	// Invalidate only the dst chain so the borrowed src_runs stay valid.
	dst_runs: []fs.Extent_Run
	derr: fs.FS_Error
	dst_cluster, dst_offset, dst_runs, _, derr = ensure_chain_covers(fsys, &dst_entry, dst_cluster, dst_offset, dst_total_sectors)
	if derr != .None {
		if derr == .No_Space {
			return c.ssize_t(-int(fuse3.nix(.ENOSPC)))
		}
		return c.ssize_t(-int(fuse3.nix(.ENOENT)))
	}

	read_sector: [fs.SECTOR_SIZE]u8
	bytes_copied: u64 = 0
	remaining := u64(size)
	src_cur := run_cursor_init(src_runs, src_off)
	dst_cur := run_cursor_init(dst_runs, dst_off)
	for remaining > 0 && src_cur.ok && dst_cur.ok {
		take := min(remaining, fs.SECTOR_SIZE - src_cur.off_in_sec, fs.SECTOR_SIZE - dst_cur.off_in_sec)
		if fs.sector_read(&fsys.vol, src_cur.sec, read_sector[:]) != .None {
			break
		}
		if dst_cur.off_in_sec != 0 || take < fs.SECTOR_SIZE {
			dst_buf: [fs.SECTOR_SIZE]u8
			if fs.sector_read(&fsys.vol, dst_cur.sec, dst_buf[:]) != .None {
				break
			}

			copy(dst_buf[dst_cur.off_in_sec:], read_sector[src_cur.off_in_sec:][:take])
			if fs.sector_write(&fsys.vol, dst_cur.sec, dst_buf[:]) != .None {
				break
			}
		} else {
			if fs.sector_write(&fsys.vol, dst_cur.sec, read_sector[src_cur.off_in_sec:][:take]) != .None {
				break
			}
		}

		bytes_copied += take
		remaining -= take
		run_cursor_advance(&src_cur, take)
		run_cursor_advance(&dst_cur, take)
	}

	new_size := max(u64(dst_entry.file_size), u64(off_out) + bytes_copied)
	if new_size != u64(dst_entry.file_size) {
		set_entry_time_to_now(&dst_entry)
		dst_entry.file_size = new_size
		dir_cluster, dir_offset, entry_index := fh_parts(fi_out.fh)
		if !write_entry_back(fsys, &dst_entry, dir_cluster, dir_offset, entry_index) {
			return c.ssize_t(-int(fuse3.nix(.EIO)))
		}
	}

	path_cache_invalidate_all(fsys)
	log.debugf("copy_file_range: %s → %s  %d bytes", path_in, path_out, bytes_copied)
	return c.ssize_t(bytes_copied)
}
