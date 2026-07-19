// write.odin — write-related FUSE callbacks for the fused filesystem.
#+build linux
package mounter

import "base:runtime"
import "core:c"
import "core:container/lru"
import "core:log"
import "core:mem"
import "core:os"
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
	runs, ext_err := fs.resolve_extents(&fsys.vol,data_cluster, data_offset)
	defer delete(runs)

	total_sectors := (u64(off) + u64(size) + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE
	current_sectors: u64
	if ext_err == .None {
		for r in runs {
			current_sectors += u64(r.count)
		}
	}
	if total_sectors > current_sectors {
		new_c, new_o, aerr := fs.allocate_sectors(&fsys.vol,
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
		delete(runs)
		runs, ext_err = fs.resolve_extents(&fsys.vol, data_cluster, data_offset)
	}
	if ext_err != .None {
		log.errorf("write: %s → extents failed", path)
		return fuse3.nix(.ENOENT)
	}

	// fsync after metadata allocation — ensures CE table and chain are durable.
	os.sync(fsys.vol.disk)
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
			if !fs.sector_read(&fsys.vol, fs.Sector(start_sec), sector_rw[:]) {break}

			avail := u64(len(sector_rw[byte_off:]))
			take := min(avail, remaining)
			mem.copy(raw_data(sector_rw[byte_off:]), rawptr(buf[bytes_written:]), int(take))
			if !fs.sector_write(&fsys.vol, fs.Sector(start_sec), sector_rw[:]) {break}

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
				if !fs.sector_write_bulk(&fsys.vol, fs.Sector(start_sec), bulk_buf) {
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
			if !fs.sector_read(&fsys.vol, fs.Sector(start_sec), sector_rw[:]) {break}
			mem.copy(raw_data(sector_rw[:]), rawptr(buf[bytes_written:]), int(remaining))
			if !fs.sector_write(&fsys.vol, fs.Sector(start_sec), sector_rw[:]) {break}

			last := remaining
			pos_in_file += last
			bytes_written += last
			remaining = 0
		}
		if remaining == 0 {break}
		pos_in_file = u64(run.sector + fs.Sector(run.count)) * fs.SECTOR_SIZE
	}
	if new_size != u64(entry.file_size) {
		os.sync(fsys.vol.disk)
	}

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
	runs, ext_err := fs.resolve_extents(&fsys.vol,data_cluster, data_offset)
	defer delete(runs)

	total_sectors := (u64(off) + total_size + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE
	current_sectors: u64
	if ext_err == .None {
		for r in runs {
			current_sectors += u64(r.count)
		}
	}
	if total_sectors > current_sectors {
		new_c, new_o, aerr := fs.allocate_sectors(&fsys.vol,
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
		delete(runs)
		runs, ext_err = fs.resolve_extents(&fsys.vol, data_cluster, data_offset)
	}
	if ext_err != .None {
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
				if !fs.sector_read(&fsys.vol, fs.Sector(start_sec), sector_rw[:]) {break}

				avail := u64(len(sector_rw[byte_off:]))
				take := min(avail, buf_remaining)
				if b.flags & fuse3.FUSE_BUF_IS_FD != 0 {
					panic("write_buf: fd-backed buf at unaligned offset not supported")
				} else {
					src := ([^]u8)(b.mem)[:b.size]
					mem.copy(raw_data(sector_rw[byte_off:]), raw_data(src), int(take))
				}
				if !fs.sector_write(&fsys.vol, fs.Sector(start_sec), sector_rw[:]) {
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
					if !fs.sector_write_bulk(&fsys.vol, fs.Sector(start_sec), src) {break}
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
				if !fs.sector_read(&fsys.vol, fs.Sector(start_sec), sector_rw[:]) {break}
				if b.flags & fuse3.FUSE_BUF_IS_FD != 0 {
					panic("write_buf: fd-backed buf at partial sector tail not supported")
				} else {
					src := ([^]u8)(b.mem)[:buf_remaining]
					mem.copy(raw_data(sector_rw[:]), raw_data(src), int(buf_remaining))
				}
				if !fs.sector_write(&fsys.vol, fs.Sector(start_sec), sector_rw[:]) {break}

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
		os.sync(fsys.vol.disk)
	}
	
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
	current_sectors: u64
	runs, ext_err := fs.resolve_extents(&fsys.vol, data_cluster, data_offset)
	defer delete(runs)
	if ext_err == .None {
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
	} else if new_sectors > current_sectors {
		_, _, aerr := fs.allocate_sectors(&fsys.vol, fs.Cluster(entry.stored_cluster), fs.Sector_Offset(entry.sector_index), new_sectors, .File_Content)
		if aerr != .None {
			return fuse3.nix(.ENOSPC)
		}
		os.sync(fsys.vol.disk)
	}

	set_entry_time_to_now(&entry)
	entry.file_size = u64(size)
	if !write_entry_back(fsys, &entry, entry_cluster, entry_offset, entry_idx) {
		return fuse3.nix(.EIO)
	}

	os.sync(fsys.vol.disk)
	lru.remove(&fsys.path_cache, string(path))
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
				if !fs.sector_write(&fsys.vol, sec, zero_sector[:]) {
					return false
				}
			} else {
				if !fs.sector_read(&fsys.vol, sec, sector_buf[:]) {
					return false
				}

				zero_begin := max(sector_start, start) - sector_start
				zero_end := min(sector_end, end) - sector_start
				mem.zero_slice(sector_buf[zero_begin:zero_end])
				if !fs.sector_write(&fsys.vol, sec, sector_buf[:]) {
					return false
				}
			}
			file_pos += fs.SECTOR_SIZE
		}
	}
	return true
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

	fh := transmute(fs.File_Handle)(fi.fh)
	if .Directory in entry.flags {
		return fuse3.nix(.EISDIR)
	}

	alloc_start := u64(off)
	alloc_len := u64(length)
	total_sectors := (alloc_start + alloc_len + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE
	current_sectors: u64
	runs, ext_err := fs.resolve_extents(&fsys.vol, data_cluster, data_offset)
	defer delete(runs)
	if ext_err == .None {
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
		if !write_entry_back(fsys, &entry, fs.Cluster(fh.dir_cluster), fs.Sector_Offset(fh.dir_offset), int(fh.entry_index)) {
			return fuse3.nix(.EIO)
		}
		path_cache_invalidate_all(fsys)
		return 0
	}
	if total_sectors > current_sectors {
		new_c, new_o, aerr := fs.allocate_sectors(&fsys.vol,
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
			os.sync(fsys.vol.disk)
		}
	}
	if mode & fuse3.FALLOC_FL_KEEP_SIZE == 0 {
		new_size := max(u64(entry.file_size), alloc_start + alloc_len)
		if new_size != u64(entry.file_size) {
			set_entry_time_to_now(&entry)
			entry.file_size = new_size
		}
	}
	if !write_entry_back(fsys, &entry, fs.Cluster(fh.dir_cluster), fs.Sector_Offset(fh.dir_offset), int(fh.entry_index)) {
		return fuse3.nix(.EIO)
	}
	
	os.sync(fsys.vol.disk)
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

	dst_fh := transmute(fs.File_Handle)(fi_out.fh)
	src_runs, src_err := fs.resolve_extents(&fsys.vol,src_cluster, src_offset)
	defer delete(src_runs)
	if src_err != .None {
		return c.ssize_t(-int(fuse3.nix(.ENOENT)))
	}

	dst_runs, dst_err := fs.resolve_extents(&fsys.vol, dst_cluster, dst_offset)
	defer delete(dst_runs)
	if dst_err != .None {dst_runs = {}}

	src_off := u64(off_in)
	dst_off := u64(off_out)
	dst_total_sectors := (dst_off + u64(size) + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE
	dst_current: u64
	for r in dst_runs {dst_current += u64(r.count)}
	if dst_total_sectors > dst_current {
		new_c, new_o, aerr := fs.allocate_sectors(&fsys.vol,
			dst_cluster, dst_offset, dst_total_sectors, .File_Content)
		if aerr != .None {return c.ssize_t(-int(fuse3.nix(.ENOSPC)))}
		if dst_cluster == 0 {
			dst_entry.stored_cluster = u64(new_c)
			dst_entry.sector_index = u16(new_o)
			dst_cluster = new_c
			dst_offset = new_o
		}

		delete(dst_runs)
		dst_runs, dst_err = fs.resolve_extents(&fsys.vol, dst_cluster, dst_offset)
		if dst_err != .None {return c.ssize_t(-int(fuse3.nix(.ENOENT)))}
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
		if !write_entry_back(fsys, &dst_entry, fs.Cluster(dst_fh.dir_cluster), fs.Sector_Offset(dst_fh.dir_offset), int(dst_fh.entry_index)) {
			return c.ssize_t(-int(fuse3.nix(.EIO)))
		}
	}

	path_cache_invalidate_all(fsys)
	log.debugf("copy_file_range: %s → %s  %d bytes", path_in, path_out, bytes_copied)
	return c.ssize_t(bytes_copied)
}
