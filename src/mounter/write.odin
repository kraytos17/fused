// write.odin — write-related FUSE callbacks for the fused filesystem.
#+build linux
package mounter

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:log"
import "core:slice"
import "core:sys/posix"
import "core:time"
import "src:fs"
import "src:fuse3"

// _checked_add adds two byte offsets, failing closed on overflow. FUSE
// offsets/sizes are kernel-supplied but untrusted at this boundary: a
// wrapped sum would shrink an allocation and let a write run past it.
@(private = "file")
_checked_add :: proc(a, b: u64) -> (sum: u64, ok: bool) {
	total, wrapped := intrinsics.overflow_add(a, b)
	if wrapped {
		return 0, false
	}
	return total, true
}

// _span_sectors converts the byte span [off, off+size) to a covering sector
// count, failing closed if either addition overflows.
@(private = "file")
_span_sectors :: proc(off, size: u64) -> (sectors: u64, ok: bool) {
	end, end_ok := _checked_add(off, size)
	if !end_ok {
		return 0, false
	}

	padded, pad_ok := _checked_add(end, u64(fs.SECTOR_SIZE - 1))
	if !pad_ok {
		return 0, false
	}
	return padded / fs.SECTOR_SIZE, true
}

// fused_write writes data to a file at a given offset.
fused_write :: proc "c" (
	path: cstring,
	buf: [^]c.char,
	size: c.size_t,
	off: posix.off_t,
	fi: ^fuse3.File_Info,
) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	write_start := time.now()
	defer end_op(fsys)

	// ABI inputs validate before any fs work (kernel-parity order).
	uoff, ook := checked_offset(off)
	if !ook {
		return fuse3.nix(.EINVAL)
	}

	entry, data_cluster, data_offset, rerr := read_entry_from_fh(fsys, fi.fh)
	if rerr != .None {
		log.debugf("write: %s → %v", path, rerr)
		return fs_error_to_errno(rerr)
	}

	total_sectors, sok := _span_sectors(uoff, u64(size))
	if !sok {
		return fuse3.nix(.EOVERFLOW)
	}

	runs: []fs.Extent_Run
	cerr: fs.FS_Error
	data_cluster, data_offset, runs, _, cerr = ensure_chain_covers(
		fsys,
		&entry,
		fs.Chain_Location{data_cluster, data_offset},
		total_sectors,
	)
	if cerr != .None {
		if cerr == .No_Space {
			log.errorf("write: %s → ENOSPC", path)
			return fuse3.nix(.ENOSPC)
		}

		log.errorf("write: %s → extents failed", path)
		return fuse3.nix(.ENOENT)
	}

	// Metadata allocation is made durable by the journal's own sync
	// (journal_commit); no extra fsync needed here.
	log.debugf("write: %s → enter write loop (runs=%d)", path, len(runs))
	write_off := uoff
	end, _ := _checked_add(write_off, u64(size)) // cannot wrap: span checked above
	new_size := max(u64(entry.file_size), end)
	mem_src := Mem_Source {
		fsys      = fsys,
		buf       = ([^]u8)(buf),
		size      = u64(size),
		remaining = u64(size),
	}
	bytes_src := Buf_Source {
		user      = &mem_src,
		copy      = _mem_copy,
		bulk      = _mem_bulk,
		remaining = _mem_remaining,
	}

	bytes_written := write_range_to_runs(fsys, runs, write_off, &bytes_src)
	log.debugf(
		"write: %s off=%d size=%d → %d bytes (%v)",
		path,
		off,
		size,
		bytes_written,
		time.since(write_start),
	)
	return write_finish(fsys, &entry, fh_parts(fi.fh), new_size, bytes_written)
}

// write_finish is the shared epilogue for write operations: updates file size
// and timestamps, writes the entry back, and invalidates caches.
write_finish :: proc(
	fsys: ^FS,
	entry: ^fs.Directory_Entry,
	loc: fs.File_Identity,
	new_size: u64,
	bytes_written: u64,
) -> c.int {
	if new_size != u64(entry.file_size) {
		set_entry_time_to_now(entry)
		entry.file_size = new_size
		if werr := write_entry_at(fsys, loc, entry); werr != .None {
			return fs_error_to_errno(werr)
		}
	}

	path_cache_invalidate_all(fsys)
	// Saturate the u64 → c.int narrowing (bytes_written ≤ requested size,
	// but the conversion must be total regardless).
	return c.int(min(bytes_written, u64(max(c.int))))
}

// fused_write_buf writes data with bufvec/splice support (FUSE write_buf
// callback).
fused_write_buf :: proc "c" (
	path: cstring,
	buf: ^fuse3.Bufvec,
	off: posix.off_t,
	fi: ^fuse3.File_Info,
) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	write_start := time.now()
	defer end_op(fsys)

	uoff, ook := checked_offset(off)
	if !ook {
		return fuse3.nix(.EINVAL)
	}

	entry, data_cluster, data_offset, rerr := read_entry_from_fh(fsys, fi.fh)
	if rerr != .None {
		log.debugf("write_buf: %s → %v", path, rerr)
		return fs_error_to_errno(rerr)
	}

	total_size: u64
	bufs := slice.from_ptr(&buf._buf[0], int(buf.count))
	size_ok := true
	for i in 0 ..< buf.count {
		b := bufs[i]
		total_size, size_ok = _checked_add(total_size, u64(b.size))
		if !size_ok {
			break
		}
	}

	total_sectors, sok := _span_sectors(uoff, total_size)
	if !size_ok || !sok {
		return fuse3.nix(.EOVERFLOW)
	}

	runs: []fs.Extent_Run
	cerr: fs.FS_Error
	data_cluster, data_offset, runs, _, cerr = ensure_chain_covers(
		fsys,
		&entry,
		fs.Chain_Location{data_cluster, data_offset},
		total_sectors,
	)
	if cerr != .None {
		if cerr == .No_Space {
			log.errorf("write_buf: %s → ENOSPC", path)
			return fuse3.nix(.ENOSPC)
		}

		log.errorf("write_buf: %s → extents failed", path)
		return fuse3.nix(.ENOENT)
	}

	log.debugf("write_buf: %s → enter write loop (runs=%d, bufs=%d)", path, len(runs), buf.count)
	write_off := uoff
	bufvec_src := Bufvec_Source {
		fsys  = fsys,
		bufs  = bufs,
		count = u32(buf.count),
	}
	bytes_src := Buf_Source {
		user      = &bufvec_src,
		copy      = _bufvec_copy,
		bulk      = _bufvec_bulk,
		remaining = _bufvec_remaining,
	}

	bytes_written := write_range_to_runs(fsys, runs, write_off, &bytes_src)
	new_size := max(u64(entry.file_size), write_off + bytes_written)
	if bufvec_src.err {
		// A source failure (fd-backed partial, splice/I/O error) aborts the
		// transfer: persist the partial size + invalidate caches, but report
		// EIO rather than a silent short count.
		log.errorf("write_buf: %s → source error after %d bytes", path, bytes_written)
		_ = write_finish(fsys, &entry, fh_parts(fi.fh), new_size, bytes_written)
		return fuse3.nix(.EIO)
	}

	log.debugf(
		"write_buf: %s off=%d → %d bytes (%v)",
		path,
		off,
		bytes_written,
		time.since(write_start),
	)
	return write_finish(fsys, &entry, fh_parts(fi.fh), new_size, bytes_written)
}

// fused_truncate truncates or extends a file to the given size.
fused_truncate :: proc "c" (path: cstring, size: posix.off_t, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)

	log.debugf("truncate: %s size=%d fi=%v", path, size, fi != nil)
	usize, sok := checked_offset(size)
	if !sok {
		return fuse3.nix(.EINVAL)
	}
	entry, entry_cluster, entry_offset, entry_idx, data_cluster, data_offset, rerr :=
		resolve_entry(fsys, path, fi)
	if rerr != .None {
		log.debugf("truncate: %s → %v", path, rerr)
		return fs_error_to_errno(rerr)
	}
	if .Directory in entry.flags {
		log.debugf("truncate: %s → EISDIR", path)
		return fuse3.nix(.EISDIR)
	}

	new_sectors := (usize + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE
	runs: []fs.Extent_Run
	cerr: fs.FS_Error
	data_cluster, data_offset, runs, _, cerr = ensure_chain_covers(
		fsys,
		&entry,
		fs.Chain_Location{data_cluster, data_offset},
		new_sectors,
	)
	if cerr != .None {
		if cerr == .No_Space {
			return fuse3.nix(.ENOSPC)
		}
		return fuse3.nix(.ENOENT)
	}

	current_sectors := fs.chain_sector_count(runs)
	if new_sectors < current_sectors {
		if terr := fs.truncate_chain_at(&fsys.vol, fs.data_chain_of(entry), new_sectors); terr != .None {
			return fs_error_to_errno(terr)
		}
		fsys.free_sectors += current_sectors - new_sectors
	}

	set_entry_time_to_now(&entry)
	entry.file_size = usize
	if werr := write_entry_at(fsys, fs.File_Identity{entry_cluster, entry_offset, entry_idx}, &entry);
	   werr != .None {
		return fs_error_to_errno(werr)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("truncate: %s → %d", path, size)
	return 0
}

// Byte_Range is a half-open [start, end) span in file-offset space. It
// groups the offset pairs threaded through the write path so the half-open
// convention is stated once instead of re-derived per call. (Lock ranges
// stay separate: they are i64 with a 0-means-EOF sentinel, a different
// domain that conversions would only obscure.)
Byte_Range :: struct {
	start: u64,
	end:   u64,
}

// byte_range_len returns the span length (0 for empty or inverted ranges).
byte_range_len :: proc(r: Byte_Range) -> u64 {
	if r.end <= r.start { return 0 }
	return r.end - r.start
}

// zero_file_range zeros a byte range within a file by reading partial sectors
// and writing full zeroed sectors where possible. Extent-resolution errors
// propagate; a short write reports .Sector_Write_Error.
zero_file_range :: proc(
	fsys: ^FS,
	entry: ^fs.Directory_Entry,
	loc: fs.Chain_Location,
	r: Byte_Range,
) -> fs.FS_Error {
	if byte_range_len(r) == 0 { return .None }

	// Cached resolve: both callers hold the write lock, so the borrowed
	// slice stays valid for the call — nothing below invalidates the
	// extent cache (write_range_to_runs only does sector I/O). No delete:
	// the slice is cache-owned.
	runs, ext_err := resolve_extents_cached(fsys, loc)
	if ext_err != .None { return ext_err }

	zero_src := Zero_Source {
		fsys      = fsys,
		remaining = byte_range_len(r),
	}
	bytes_src := Buf_Source {
		user      = &zero_src,
		copy      = _zero_copy,
		bulk      = _zero_bulk,
		remaining = _zero_remaining,
	}

	written := write_range_to_runs(fsys, runs, r.start, &bytes_src)
	if written != byte_range_len(r) {
		return .Sector_Write_Error
	}
	return .None
}

// fused_fallocate pre-allocates space for a file (supports PUNCH_HOLE and
// KEEP_SIZE).
fused_fallocate :: proc "c" (
	path: cstring,
	mode: c.int,
	off: posix.off_t,
	length: posix.off_t,
	fi: ^fuse3.File_Info,
) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)
	// Parse the ABI word once; downstream switches on set membership.
	fmode := transmute(fuse3.Falloc_Flags)(mode) // TRANSMUTE: c.int ABI word bit-view as flag set
	if .Collapse_Range in fmode || .Insert_Range in fmode {
		return fuse3.nix(.EOPNOTSUPP)
	}

	// ABI inputs validate before any fs work (kernel-parity order).
	span_start, sok1 := checked_offset(off)
	span_len, sok2 := checked_offset(length)
	if !sok1 || !sok2 {
		return fuse3.nix(.EINVAL)
	}

	entry, data_cluster, data_offset, rerr := read_entry_from_fh(fsys, fi.fh)
	if rerr != .None {
		return fs_error_to_errno(rerr)
	}
	if .Directory in entry.flags {
		return fuse3.nix(.EISDIR)
	}

	span_end, aok := _checked_add(span_start, span_len)
	if !aok {
		return fuse3.nix(.EOVERFLOW)
	}
	span := Byte_Range{span_start, span_end}
	if .Punch_Hole in fmode {
		zerr := zero_file_range(fsys, &entry, fs.Chain_Location{data_cluster, data_offset}, span)
		if zerr != .None {
			return fs_error_to_errno(zerr)
		}
		// Update file_size if needed (PUNCH_HOLE implies KEEP_SIZE)
		if werr := write_entry_at(fsys, fh_parts(fi.fh), &entry); werr != .None {
			return fs_error_to_errno(werr)
		}

		path_cache_invalidate_all(fsys)
		return 0
	}

	total_sectors, sok := _span_sectors(span.start, byte_range_len(span))
	if !sok {
		return fuse3.nix(.EOVERFLOW)
	}

	extended: bool
	cerr: fs.FS_Error
	data_cluster, data_offset, _, extended, cerr = ensure_chain_covers(
		fsys,
		&entry,
		fs.Chain_Location{data_cluster, data_offset},
		total_sectors,
	)
	if cerr != .None {
		if cerr == .No_Space {
			return fuse3.nix(.ENOSPC)
		}
		return fuse3.nix(.ENOENT)
	}
	if extended {
		zero_start := u64(entry.file_size)
		zero_end := max(span.end, zero_start)
		if zero_end > zero_start {
			zerr := zero_file_range(fsys, &entry, fs.Chain_Location{data_cluster, data_offset}, Byte_Range{zero_start, zero_end})
			if zerr != .None {
				return fs_error_to_errno(zerr)
			}
		}
	}
	if .Keep_Size not_in fmode {
		new_size := max(u64(entry.file_size), span.end)
		if new_size != u64(entry.file_size) {
			set_entry_time_to_now(&entry)
			entry.file_size = new_size
		}
	}
	if werr := write_entry_at(fsys, fh_parts(fi.fh), &entry); werr != .None {
		return fs_error_to_errno(werr)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("fallocate: %s off=%d len=%d mode=%d", path, off, length, mode)
	return 0
}

// fused_copy_file_range copies data between two files (FUSE copy_file_range
// callback).
fused_copy_file_range :: proc "c" (
	path_in: cstring,
	fi_in: ^fuse3.File_Info,
	off_in: posix.off_t,
	path_out: cstring,
	fi_out: ^fuse3.File_Info,
	off_out: posix.off_t,
	size: c.size_t,
	flags: c.int,
) -> c.ssize_t {
	context = runtime.default_context()
	fsys := begin_op()
	log.debugf(
		"copy_file_range: path_in=%s size=%d off_in=%d off_out=%d",
		path_in,
		size,
		off_in,
		off_out,
	)
	defer end_op(fsys)

	src_off, sok1 := checked_offset(off_in)
	dst_off, sok2 := checked_offset(off_out)
	if !sok1 || !sok2 {
		return c.ssize_t(fuse3.nix(.EINVAL))
	}

	_, src_cluster, src_offset, src_rerr := read_entry_from_fh(fsys, fi_in.fh)
	if src_rerr != .None {
		return c.ssize_t(fs_error_to_errno(src_rerr))
	}

	dst_entry, dst_cluster, dst_offset, dst_err := read_entry_from_fh(fsys, fi_out.fh)
	if dst_err != .None {
		return c.ssize_t(fs_error_to_errno(dst_err))
	}

	src_runs, src_xerr := resolve_extents_cached(fsys, fs.Chain_Location{src_cluster, src_offset})
	if src_xerr != .None {
		return c.ssize_t(fuse3.nix(.ENOENT))
	}

	dst_total_sectors, sok := _span_sectors(dst_off, u64(size))
	if !sok {
		return c.ssize_t(fuse3.nix(.EOVERFLOW))
	}

	// Invalidate only the dst chain so the borrowed src_runs stay valid.
	dst_runs: []fs.Extent_Run
	derr: fs.FS_Error
	dst_cluster, dst_offset, dst_runs, _, derr = ensure_chain_covers(
		fsys,
		&dst_entry,
		fs.Chain_Location{dst_cluster, dst_offset},
		dst_total_sectors,
	)
	if derr != .None {
		return c.ssize_t(fs_error_to_errno(derr))
	}

	read_sector: [fs.SECTOR_SIZE]u8
	bytes_copied: u64 = 0
	remaining := u64(size)
	src_cur := run_cursor_init(src_runs, src_off)
	dst_cur := run_cursor_init(dst_runs, dst_off)
	for remaining > 0 && src_cur.ok && dst_cur.ok {
		take := min(
			remaining,
			fs.SECTOR_SIZE - src_cur.off_in_sec,
			fs.SECTOR_SIZE - dst_cur.off_in_sec,
		)
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
			if fs.sector_write(&fsys.vol, dst_cur.sec, read_sector[src_cur.off_in_sec:][:take]) !=
			   .None {
				break
			}
		}

		bytes_copied += take
		remaining -= take
		run_cursor_advance(&src_cur, take)
		run_cursor_advance(&dst_cur, take)
	}

	// Safe: dst_off + size did not overflow above and bytes_copied <= size.
	new_size := max(u64(dst_entry.file_size), u64(off_out) + bytes_copied)
	if new_size != u64(dst_entry.file_size) {
		set_entry_time_to_now(&dst_entry)
		dst_entry.file_size = new_size
		if werr := write_entry_at(fsys, fh_parts(fi_out.fh), &dst_entry); werr != .None {
			return c.ssize_t(fs_error_to_errno(werr))
		}
	}

	path_cache_invalidate_all(fsys)
	log.debugf("copy_file_range: %s → %s  %d bytes", path_in, path_out, bytes_copied)
	return c.ssize_t(bytes_copied)
}
