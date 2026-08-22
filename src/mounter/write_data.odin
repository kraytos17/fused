// write_data.odin — shared write-path engine for the fused filesystem.
//
// The file-data write path (fused_write, fused_write_buf, zero_file_range)
// shares one range engine plus per-source providers, so run-walk bookkeeping
// exists once instead of three near-identical loops.
#+build linux
package mounter

import "core:c"
import "core:mem"
import "core:sys/linux"
import "src:fuse3"
import "src:fs"

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
	fsys.free_sectors -= total_sectors - current

	extent_cache_invalidate(fsys, new_c, new_o)
	runs, ext_ok = resolve_extents_cached(fsys, new_c, new_o)
	if !ext_ok {
		return {}, 0, {}, true, .Entry_Not_Found
	}
	return new_c, new_o, runs, true, .None
}

// Buf_Source supplies bytes to write_range_to_runs.
Buf_Source :: struct {
	user:      rawptr,
	copy:      proc(user: rawptr, dst: []u8, dst_byte_off: u64, take: u64) -> u64,
	bulk:      proc(user: rawptr, sec: fs.Sector, sectors: u64) -> u64,
	remaining: proc(user: rawptr) -> u64,
}

// write_range_to_runs writes a byte range across an extent run list starting
// at file offset write_off, consuming from src.
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
				take := min(u64(len(sector_rw[byte_off:])), src.remaining(src.user))
				if fs.sector_read(&fsys.vol, fs.Sector(start_sec), sector_rw[:]) != .None {
					return bytes_written
				}

				n := src.copy(src.user, sector_rw[:], byte_off, take)
				if n == 0 {
					return bytes_written
				}
				if fs.sector_write(&fsys.vol, fs.Sector(start_sec), sector_rw[:]) != .None {
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

				take := min(src.remaining(src.user), fs.SECTOR_SIZE)
				if fs.sector_read(&fsys.vol, fs.Sector(start_sec), sector_rw[:]) != .None {
					return bytes_written
				}

				n := src.copy(src.user, sector_rw[:], 0, take)
				if n == 0 {
					return bytes_written
				}
				if fs.sector_write(&fsys.vol, fs.Sector(start_sec), sector_rw[:]) != .None {
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
	if fs.sector_write_bulk(&s.fsys.vol, sec, ([^]u8)(rawptr(uintptr(s.buf) + uintptr(src_off)))[:n]) != .None {
		return 0
	}
	s.remaining -= n
	return sectors
}

// Bufvec_Source writes from a FUSE bufvec (fused_write_buf).
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
		if fs.sector_write_bulk(&s.fsys.vol, sec, src) != .None {
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
		if fs.sector_write(&s.fsys.vol, fs.Sector(u64(sec) + i), zero_sector[:]) != .None {
			return i
		}
	}
	s.remaining -= sectors * fs.SECTOR_SIZE
	return sectors
}

// Read_Sink receives bytes from read_range_from_runs.
Read_Sink :: struct {
	user:     rawptr,
	copy_to:  proc(user: rawptr, src: []u8, src_byte_off: u64, dst_off: u64, take: u64) -> u64,
	bulk:     proc(user: rawptr, sec: fs.Sector, sectors: u64, dst_off: u64) -> u64,
	remaining: proc(user: rawptr) -> u64,
}

// read_range_from_runs reads a byte range across an extent run list starting
// at file offset read_off, delivering up to size bytes into sink.
read_range_from_runs :: proc(fsys: ^FS, runs: []fs.Extent_Run, read_off: u64, sink: ^Read_Sink) -> (bytes_read: u64) {
	pos_in_file: u64
	sector_buf: [fs.SECTOR_SIZE]u8
	for run in runs {
		run_start := pos_in_file
		run_bytes := u64(run.count) * fs.SECTOR_SIZE
		if pos_in_file + run_bytes <= read_off {
			pos_in_file += run_bytes
			continue
		}

		skip := (read_off + bytes_read) - pos_in_file
		start_sec := u64(run.sector) + skip / fs.SECTOR_SIZE
		byte_off := skip % fs.SECTOR_SIZE
		remaining_in_run := u64(run.sector) + u64(run.count) - start_sec
		for (byte_off > 0 || remaining_in_run > 0) && sink.remaining(sink.user) > 0 {
			if byte_off > 0 {
				if fs.sector_read(&fsys.vol, fs.Sector(start_sec), sector_buf[:]) != .None {
					return bytes_read
				}

				avail := u64(len(sector_buf[byte_off:]))
				take := min(avail, sink.remaining(sink.user))
				n := sink.copy_to(sink.user, sector_buf[:], byte_off, bytes_read, take)
				if n == 0 {
					return bytes_read
				}

				bytes_read += n
				pos_in_file += u64(byte_off) + n
				start_sec += 1
				remaining_in_run -= 1
				byte_off = 0
				continue
			}
			if remaining_in_run > 0 {
				full := min(sink.remaining(sink.user) / fs.SECTOR_SIZE, u64(remaining_in_run))
				if full > 0 {
					n := sink.bulk(sink.user, fs.Sector(start_sec), full, bytes_read)
					if n == 0 {
						return bytes_read
					}

					bytes_read += n * fs.SECTOR_SIZE
					pos_in_file += n * fs.SECTOR_SIZE
					start_sec += n
					remaining_in_run -= n
					continue
				}

				take := min(sink.remaining(sink.user), fs.SECTOR_SIZE)
				if fs.sector_read(&fsys.vol, fs.Sector(start_sec), sector_buf[:]) != .None {
					return bytes_read
				}

				n := sink.copy_to(sink.user, sector_buf[:], 0, bytes_read, take)
				if n == 0 {
					return bytes_read
				}

				bytes_read += n
				pos_in_file += n
				remaining_in_run = 0
				continue
			}
			break
		}
		if sink.remaining(sink.user) == 0 {
			return bytes_read
		}
		pos_in_file = run_start + run_bytes
	}
	return bytes_read
}

// ReadSlice describes one contiguous FUSE buffer for zero-copy reads.
ReadSlice :: struct {
	sector: fs.Sector,
	len:    u64,
}

// collect_read_slices walks extent runs and returns the slices covering
// [off, off+size) as a list of {sector,len}. Used by fused_read_buf to
// avoid walking runs twice (count then fill). Caller deletes the returned
// dynamic array.
collect_read_slices :: proc(runs: []fs.Extent_Run, off: u64, size: u64, allocator := context.allocator) -> (slices: [dynamic]ReadSlice, total: u64) {
	slices = make([dynamic]ReadSlice, 0, 8, allocator)
	remaining := size
	req_off := off
	for run in runs {
		run_bytes := u64(run.count) * fs.SECTOR_SIZE
		if req_off >= run_bytes {
			req_off -= run_bytes
			continue
		}

		avail := min(run_bytes - req_off, remaining)
		if avail > 0 {
			append(&slices, ReadSlice{
				sector = fs.Sector(u64(run.sector) + req_off / fs.SECTOR_SIZE),
				len    = avail,
			})

			total += avail
			remaining -= avail
			req_off = 0
		}
		if remaining == 0 {
			break
		}
	}
	return slices, total
}

// Mem_Read_Sink delivers bytes into a flat memory buffer (fused_read).
Mem_Read_Sink :: struct {
	fsys:      ^FS,
	buf:       [^]u8,
	size:      u64,
	remaining: u64,
}

_mem_read_remaining :: proc(user: rawptr) -> u64 {
	return (^Mem_Read_Sink)(user).remaining
}

_mem_read_copy_to :: proc(user: rawptr, src: []u8, src_byte_off: u64, dst_off: u64, take: u64) -> u64 {
	s := (^Mem_Read_Sink)(user)
	n := min(take, s.remaining, u64(len(src[src_byte_off:])))
	if n == 0 {
		return 0
	}

	mem.copy(rawptr(uintptr(s.buf) + uintptr(dst_off)), raw_data(src[src_byte_off:]), int(n))
	s.remaining -= n
	return n
}

_mem_read_bulk :: proc(user: rawptr, sec: fs.Sector, sectors: u64, dst_off: u64) -> u64 {
	s := (^Mem_Read_Sink)(user)
	n := sectors * fs.SECTOR_SIZE
	dst_buf := ([^]u8)(rawptr(uintptr(s.buf) + uintptr(dst_off)))[:n]
	if fs.sector_read(&s.fsys.vol, sec, dst_buf) != .None {
		return 0
	}
	s.remaining -= n
	return sectors
}

// RunCursor walks an extent run list linearly, advancing O(1) amortized
// instead of scanning from the start per sector (as find_sector_at_offset
// did). Used by fused_copy_file_range to make the copy O(k+S) not O(S·k).
RunCursor :: struct {
	runs:       []fs.Extent_Run,
	run_idx:    int,
	pos:        u64, // file offset of runs[run_idx] start
	sec:        fs.Sector,
	off_in_sec: u64,
	ok:         bool,
}

run_cursor_init :: proc(runs: []fs.Extent_Run, file_off: u64) -> RunCursor {
	pos: u64
	for run, i in runs {
		run_bytes := u64(run.count) * fs.SECTOR_SIZE
		if pos + run_bytes > file_off {
			skip := file_off - pos
			return RunCursor{
				runs       = runs,
				run_idx    = i,
				pos        = pos,
				sec        = fs.Sector(u64(run.sector) + skip / fs.SECTOR_SIZE),
				off_in_sec = skip % fs.SECTOR_SIZE,
				ok         = true,
			}
		}
		pos += run_bytes
	}
	return RunCursor{runs = runs, ok = false}
}

run_cursor_advance :: proc(c: ^RunCursor, n: u64) {
	if !c.ok || n == 0 {
		return
	}

	remaining := n
	for remaining > 0 && c.ok {
		avail_in_sec := fs.SECTOR_SIZE - c.off_in_sec
		take := min(remaining, avail_in_sec)
		c.off_in_sec += take
		remaining -= take
		if c.off_in_sec == fs.SECTOR_SIZE {
			c.off_in_sec = 0
			c.sec = fs.Sector(u64(c.sec) + 1)
			// Advance to next run if past current run's end.
			if c.run_idx < len(c.runs) {
				run_end_sec := u64(c.runs[c.run_idx].sector) + u64(c.runs[c.run_idx].count)
				if u64(c.sec) >= run_end_sec {
					c.pos += u64(c.runs[c.run_idx].count) * fs.SECTOR_SIZE
					c.run_idx += 1
					if c.run_idx < len(c.runs) {
						c.sec = c.runs[c.run_idx].sector
					} else {
						c.ok = false
					}
				}
			} else {
				c.ok = false
			}
		}
	}
}
