// write.odin — write-related FUSE callbacks for the fused filesystem.
#+build linux
package mounter

import "base:runtime"
import "core:c"
import "core:log"
import "core:mem"
import "core:slice"
import "core:sys/linux"
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

// ensure_chain_covers resolves a file's extent chain and extends it (via
// allocate_sectors) when it is shorter than total_sectors. When the chain was
// created fresh (data_cluster == 0), entry's stored_cluster/sector_index are
// updated. Only the given chain's cache entry is invalidated, so borrowed
// runs of other chains stay valid. extended reports whether allocation ran.
// err: .No_Space on allocation failure, .Entry_Not_Found when extents cannot
// be resolved after an extension.
ensure_chain_covers :: proc(
	fsys:         ^FS,
	entry:        ^fs.Directory_Entry,
	data_cluster: fs.Cluster,
	data_offset:  fs.Sector_Offset,
	total_sectors: u64,
) -> (cluster: fs.Cluster, offset: fs.Sector_Offset, runs: []fs.Extent_Run, extended: bool, err: fs.FS_Error) {
	ext_ok: bool
	runs, ext_ok = resolve_extents_cached(fsys, data_cluster, data_offset)
	current := fs.chain_sector_count(runs) if ext_ok else 0
	if total_sectors <= current {
		return data_cluster, data_offset, runs, false, .None
	}

	new_c, new_o, aerr := fs.allocate_sectors(&fsys.vol, data_cluster, data_offset, total_sectors, .File_Content)
	if aerr != .None {
		return {}, 0, {}, false, aerr
	}
	if data_cluster == 0 {
		entry.stored_cluster = u64(new_c)
		entry.sector_index = u16(new_o)
	}

	// The chain changed; drop only its cached extents and re-resolve.
	extent_cache_invalidate(fsys, new_c, new_o)
	runs, ext_ok = resolve_extents_cached(fsys, new_c, new_o)
	if !ext_ok {
		return {}, 0, {}, true, .Entry_Not_Found
	}
	return new_c, new_o, runs, true, .None
}

// Buf_Source supplies bytes to write_range_to_runs.  copy fills a partial
// sector (the caller does the RMW read/write around it), bulk writes whole
// sectors (the provider owns the write, including splice), and remaining
// reports the unconsumed source bytes.  A copy/bulk that consumes nothing
// stops the write.  A partial sector never spans source segments: copy and
// bulk clamp to the current segment's boundary.
Buf_Source :: struct {
	user:      rawptr,
	copy:      proc(user: rawptr, dst: []u8, dst_byte_off: u64, take: u64) -> u64,
	bulk:      proc(user: rawptr, sec: fs.Sector, sectors: u64) -> u64,
	remaining: proc(user: rawptr) -> u64,
}

// write_range_to_runs writes a byte range across an extent run list starting
// at file offset write_off, consuming from src.  Runs before write_off are
// skipped; each run is handled as partial head (RMW), whole sectors (bulk),
// and a partial tail (RMW).  Returns the bytes written (fewer than requested
// when the source is exhausted or an I/O error stops the write).
write_range_to_runs :: proc(fsys: ^FS, runs: []fs.Extent_Run, write_off: u64, src: ^Buf_Source) -> (bytes_written: u64) {
	pos_in_file: u64
	sector_rw: [fs.SECTOR_SIZE]u8
	for run in runs {
		run_start := pos_in_file
		run_bytes := u64(run.count) * fs.SECTOR_SIZE
		if pos_in_file + run_bytes <= write_off {
			pos_in_file += run_bytes
			continue
		}

		skip := (write_off + bytes_written) - pos_in_file
		start_sec := u64(run.sector) + skip / fs.SECTOR_SIZE
		byte_off := skip % fs.SECTOR_SIZE
		remaining_in_run := u64(run.sector) + u64(run.count) - start_sec
		for (byte_off > 0 || remaining_in_run > 0) && src.remaining(src.user) > 0 {
			if byte_off > 0 {
				// Partial head: RMW the first sector of the range.
				take := min(u64(len(sector_rw[byte_off:])), src.remaining(src.user))
				if !fs.sector_read(&fsys.vol, fs.Sector(start_sec), sector_rw[:]) {
					return bytes_written
				}

				n := src.copy(src.user, sector_rw[:], byte_off, take)
				if n == 0 {
					return bytes_written
				}
				if !fs.sector_write(&fsys.vol, fs.Sector(start_sec), sector_rw[:]) {
					return bytes_written
				}

				bytes_written += n
				pos_in_file += u64(byte_off) + n
				start_sec += 1
				remaining_in_run -= 1
				byte_off = 0
				continue
			}
			if remaining_in_run > 0 {
				full := min(src.remaining(src.user) / fs.SECTOR_SIZE, u64(remaining_in_run))
				if full > 0 {
					n := src.bulk(src.user, fs.Sector(start_sec), full)
					if n == 0 {
						return bytes_written
					}

					bytes_written += n * fs.SECTOR_SIZE
					pos_in_file += n * fs.SECTOR_SIZE
					start_sec += n
					remaining_in_run -= n
					continue
				}

				// Partial tail: RMW the final sector of the range.
				take := min(src.remaining(src.user), fs.SECTOR_SIZE)
				if !fs.sector_read(&fsys.vol, fs.Sector(start_sec), sector_rw[:]) {
					return bytes_written
				}

				n := src.copy(src.user, sector_rw[:], 0, take)
				if n == 0 {
					return bytes_written
				}
				if !fs.sector_write(&fsys.vol, fs.Sector(start_sec), sector_rw[:]) {
					return bytes_written
				}

				bytes_written += n
				pos_in_file += n
				remaining_in_run = 0
				continue
			}
			break
		}
		if src.remaining(src.user) == 0 {
			return bytes_written
		}
		// Advance to the next run's file-offset start.
		pos_in_file = run_start + run_bytes
	}
	return bytes_written
}

// Mem_Source writes from one contiguous memory buffer (fused_write).
Mem_Source :: struct {
	fsys:      ^FS,
	buf:       [^]u8,
	size:      u64,
	remaining: u64,
}

_mem_remaining :: proc(user: rawptr) -> u64 {
	return (^Mem_Source)(user).remaining
}

_mem_copy :: proc(user: rawptr, dst: []u8, byte_off: u64, take: u64) -> u64 {
	s := (^Mem_Source)(user)
	n := min(take, s.remaining, u64(len(dst[byte_off:])))
	if n == 0 {
		return 0
	}

	src_off := s.size - s.remaining
	mem.copy(raw_data(dst[byte_off:]), rawptr(uintptr(s.buf) + uintptr(src_off)), int(n))
	s.remaining -= n
	return n
}

_mem_bulk :: proc(user: rawptr, sec: fs.Sector, sectors: u64) -> u64 {
	s := (^Mem_Source)(user)
	n := sectors * fs.SECTOR_SIZE
	src_off := s.size - s.remaining
	if !fs.sector_write_bulk(&s.fsys.vol, sec, ([^]u8)(rawptr(uintptr(s.buf) + uintptr(src_off)))[:n]) {
		return 0
	}
	s.remaining -= n
	return sectors
}

// Bufvec_Source writes from a FUSE bufvec (fused_write_buf), consuming one
// buf at a time with splice support for fd-backed bufs.
Bufvec_Source :: struct {
	fsys:    ^FS,
	bufs:    []fuse3.Buf,
	count:   u32,
	buf_idx: int,
}

_bufvec_remaining :: proc(user: rawptr) -> u64 {
	s := (^Bufvec_Source)(user)
	n: u64
	for i in s.buf_idx ..< int(s.count) {
		n += u64(s.bufs[i].size)
	}
	return n
}

_bufvec_copy :: proc(user: rawptr, dst: []u8, byte_off: u64, take: u64) -> u64 {
	s := (^Bufvec_Source)(user)
	if s.buf_idx >= int(s.count) {
		return 0
	}

	b := &s.bufs[s.buf_idx]
	n := min(take, u64(b.size), u64(len(dst[byte_off:])))
	if n == 0 {
		return 0
	}
	if b.flags & fuse3.FUSE_BUF_IS_FD != 0 {
		panic("write_buf: fd-backed buf at unaligned offset not supported")
	}

	src := ([^]u8)(b.mem)[:b.size]
	mem.copy(raw_data(dst[byte_off:]), raw_data(src), int(n))
	b.size -= c.size_t(n)
	b.mem = rawptr(uintptr(b.mem) + uintptr(n))
	if b.size == 0 {
		s.buf_idx += 1
	}
	return n
}

_bufvec_bulk :: proc(user: rawptr, sec: fs.Sector, sectors: u64) -> u64 {
	s := (^Bufvec_Source)(user)
	if s.buf_idx >= int(s.count) {
		return 0
	}

	b := &s.bufs[s.buf_idx]
	bulk_len := sectors * fs.SECTOR_SIZE
	if b.flags & fuse3.FUSE_BUF_IS_FD != 0 {
		phys_off := i64(u64(sec) * fs.SECTOR_SIZE)
		written: u64
		for written < bulk_len {
			n, err := linux.splice(
				linux.Fd(b.fd), nil,
				linux.Fd(s.fsys.disk_raw_fd), &phys_off,
				uint(bulk_len - written), {})
			if err != .NONE || n == 0 {
				return 0
			}
			written += u64(n)
		}
	} else {
		src := ([^]u8)(b.mem)[:bulk_len]
		if !fs.sector_write_bulk(&s.fsys.vol, sec, src) {
			return 0
		}
	}

	b.size -= c.size_t(bulk_len)
	if b.flags & fuse3.FUSE_BUF_IS_FD == 0 {
		b.mem = rawptr(uintptr(b.mem) + uintptr(bulk_len))
	}
	if b.size == 0 {
		s.buf_idx += 1
	}
	return sectors
}

// Zero_Source fills a byte range with zeros (zero_file_range).
Zero_Source :: struct {
	fsys:      ^FS,
	remaining: u64,
}

_zero_remaining :: proc(user: rawptr) -> u64 {
	return (^Zero_Source)(user).remaining
}

_zero_copy :: proc(user: rawptr, dst: []u8, byte_off: u64, take: u64) -> u64 {
	s := (^Zero_Source)(user)
	n := min(take, s.remaining, u64(len(dst[byte_off:])))
	if n == 0 {
		return 0
	}

	mem.zero_slice(dst[byte_off:byte_off + n])
	s.remaining -= n
	return n
}

_zero_bulk :: proc(user: rawptr, sec: fs.Sector, sectors: u64) -> u64 {
	s := (^Zero_Source)(user)
	zero_sector: [fs.SECTOR_SIZE]u8
	for i: u64; i < sectors; i += 1 {
		if !fs.sector_write(&s.fsys.vol, fs.Sector(u64(sec) + i), zero_sector[:]) {
			return i
		}
	}
	s.remaining -= sectors * fs.SECTOR_SIZE
	return sectors
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
		cntr := u64(0)
		current_c := fs.Cluster(entry.stored_cluster)
		current_o := fs.Sector_Offset(entry.sector_index)
		for {
			ce_idx: int
			ce, ce_err := fs.find_cluster_entry(&fsys.vol, current_c, current_o, nil, &ce_idx)
			if ce_err != .None {
				break
			}

			before := cntr
			cntr += u64(ce.allocation_size)
			if cntr > new_sectors {
				needed := new_sectors - before
				if needed == 0 {
					nc := fs.Cluster(ce.next_cluster)
					no := fs.Sector_Offset(ce.next_sector_index)
					if derr := fs.deallocate_sectors(&fsys.vol, current_c, current_o); derr != .None {
						return fs_error_to_errno(derr)
					}
					if nc != 0 {
						if derr := fs.deallocate_sectors(&fsys.vol, nc, no); derr != .None {
							return fuse3.nix(.EIO)
						}
					}
				} else {
					if ce.next_cluster != 0 {
						nc := fs.Cluster(ce.next_cluster)
						no := fs.Sector_Offset(ce.next_sector_index)
						if derr := fs.deallocate_sectors(&fsys.vol, nc, no); derr != .None {
							return fuse3.nix(.EIO)
						}
						ce.next_cluster = 0
						ce.next_sector_index = 0
					}

					ce.allocation_size = u16(needed)
					if fs.write_cluster_entry_at(&fsys.vol,current_c, ce_idx, &ce) != .None {
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

// find_sector_at_offset finds the sector containing a given file offset within
// an extent run list.
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
	for remaining > 0 {
		src_sec, src_sec_off, src_found := find_sector_at_offset(src_runs[:], src_off)
		if !src_found {break}
		if !fs.sector_read(&fsys.vol, src_sec, read_sector[:]) {break}

		take := min(remaining, fs.SECTOR_SIZE - src_sec_off)
		dst_sec, dst_sec_off, dst_found := find_sector_at_offset(dst_runs[:], dst_off)
		if !dst_found {break}
		if dst_sec_off != 0 || take < fs.SECTOR_SIZE {
			dst_buf: [fs.SECTOR_SIZE]u8
			if !fs.sector_read(&fsys.vol, dst_sec, dst_buf[:]) {break}
			copy(dst_buf[dst_sec_off:], read_sector[src_sec_off:][:take])
			if !fs.sector_write(&fsys.vol, dst_sec, dst_buf[:]) {break}
		} else {
			if !fs.sector_write(&fsys.vol, dst_sec, read_sector[src_sec_off:][:take]) {break}
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
		dir_cluster, dir_offset, entry_index := fh_parts(fi_out.fh)
		if !write_entry_back(fsys, &dst_entry, dir_cluster, dir_offset, entry_index) {
			return c.ssize_t(-int(fuse3.nix(.EIO)))
		}
	}

	path_cache_invalidate_all(fsys)
	log.debugf("copy_file_range: %s → %s  %d bytes", path_in, path_out, bytes_copied)
	return c.ssize_t(bytes_copied)
}
