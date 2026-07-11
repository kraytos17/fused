// ops.odin — FUSE callbacks for the fused filesystem.
//
// Reads g_disk and g_master (set by main.odin before fuse3.run) and
// resolves paths against the on-disk format.
#+build linux
package main

import "base:runtime"
import "core:c"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "src:fuse3"
import "src:fs"

g_disk:   ^os.File
g_master: fs.Master_Record

resolve_path :: proc(path: string, allocator := context.allocator) -> (
	entry:   fs.Directory_Entry,
	cluster: fs.Cluster,
	offset:  fs.Sector_Offset,
	ok:      bool,
) {
	if path == "/" || len(path) == 0 {
		entry = fs.Directory_Entry{
			flags = fs.Dir_Flags{.Allocated, .Directory, .Exists},
			sector_index   = g_master.root_sector_index,
			stored_cluster = g_master.root_cluster,
		}
		return entry, fs.Cluster(g_master.root_cluster), fs.Sector_Offset(g_master.root_sector_index), true
	}

	parts := strings.split(path, "/", allocator)
	filtered := make([dynamic]string, 0, len(parts), allocator)
	for p in parts {
		if len(p) > 0 {
			append(&filtered, p)
		}
	}
	if len(filtered) == 0 {
		return resolve_path("/")
	}

	current_cluster := fs.Cluster(g_master.root_cluster)
	current_offset  := fs.Sector_Offset(g_master.root_sector_index)
	for i in 0 ..< len(filtered) {
		target := filtered[i]
		is_last := i == len(filtered) - 1
		dir_ce, dir_ok := fs.find_cluster_entry(g_disk, &g_master, current_cluster, current_offset)
		if !dir_ok {
			return {}, {}, {}, false
		}

		dirs, dirs_ok := fs.read_directory_entries(g_disk, &g_master, current_cluster, fs.Sector_Offset(dir_ce.sector_start))
		if !dirs_ok {
			return {}, {}, {}, false
		}

		found := false
		for &d in dirs {
			if fs.entry_short_name(&d) == target {
				found = true
				if is_last {
					return d, fs.Cluster(d.stored_cluster), fs.Sector_Offset(d.sector_index), true
				}
				if .Directory not_in d.flags {
					return {}, {}, {}, false
				}

				current_cluster = fs.Cluster(d.stored_cluster)
				current_offset  = fs.Sector_Offset(d.sector_index)
				break
			}
		}
		if !found {
			return {}, {}, {}, false
		}
	}
	return {}, {}, {}, false
}

fused_getattr :: proc "c"(path: cstring, stbuf: ^fuse3.Stat, _: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	entry, _, _, ok := resolve_path(string(path), context.temp_allocator)
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
		stbuf.st_size  = posix.off_t(entry.file_size)
	}

	dt := entry.date_time
	ts := posix.time_t(i64(entry.year - 1970) * 365 * 86400 + i64(dt.date) * 86400 + i64(dt.hour) * 3600 + i64(dt.minute) * 60 + i64(dt.second))

	stbuf.st_atim.tv_sec  = ts
	stbuf.st_mtim.tv_sec  = ts
	stbuf.st_ctim.tv_sec  = ts
	log.debugf("getattr: %s → ok size=%d dir=%v", path, entry.file_size, is_dir)
	return 0
}

fused_readdir :: proc "c"(
	path:  cstring,
	buf:   rawptr,
	filler: fuse3.Fill_Dir_Proc,
	off:   posix.off_t,
	_:     ^fuse3.File_Info,
	flags:  c.int,
) -> c.int {
	context = runtime.default_context()
	entry, cluster, offset, ok := resolve_path(string(path), context.temp_allocator)
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

	dir_ce, dir_ok := fs.find_cluster_entry(g_disk, &g_master, cluster, offset)
	if !dir_ok {
		return fuse3.nix(.ENOENT)
	}

	dirs, dirs_ok := fs.read_directory_entries(g_disk, &g_master, cluster, fs.Sector_Offset(dir_ce.sector_start))
	if !dirs_ok {
		return fuse3.nix(.ENOENT)
	}
	for &d in dirs {
		name := fs.entry_short_name(&d)
		if .LFN in d.flags {
			lfn, lfn_ok := fs.resolve_lfn(g_disk, &g_master, &d)
			if lfn_ok {name = lfn}
		}

		name_cstr := strings.clone_to_cstring(name) or_continue
		if rc := fuse3.fill_dir(filler, buf, name_cstr, nil); rc != 0 {
			delete(name_cstr)
			return rc
		}
		delete(name_cstr)
	}
	log.debugf("readdir: %s → ok %d entries", path, len(dirs))
	return 0
}

fused_open :: proc "c"(path: cstring, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	entry, _, _, ok := resolve_path(string(path), context.temp_allocator)
	if !ok {
		log.debugf("open: %s → ENOENT", path)
		return fuse3.nix(.ENOENT)
	}
	if .Directory in entry.flags {
		log.debugf("open: %s → EISDIR", path)
		return fuse3.nix(.EISDIR)
	}

	ph := (u64(entry.stored_cluster) << 16) | u64(entry.sector_index)
	fi.fh = ph
	return 0
}

fused_read :: proc "c"(
	path: cstring,
	buf:  [^]c.char,
	size: c.size_t,
	off:  posix.off_t,
	fi:   ^fuse3.File_Info,
) -> c.int {
	context = runtime.default_context()
	unpacked_cluster := fi.fh >> 16
	unpacked_offset  := fi.fh & 0xFFFF
	runs, runs_ok := fs.resolve_extents(
		g_disk, &g_master,
		fs.Cluster(unpacked_cluster),
		fs.Sector_Offset(u16(unpacked_offset)),
	)
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
		if skip_in_run < 0 {
			skip_in_run = 0
		}

		start_sector := u64(run.sector) + skip_in_run / fs.SECTOR_SIZE
		byte_offset  := skip_in_run % fs.SECTOR_SIZE
		#no_bounds_check {
			for sec in start_sector ..< u64(run.sector) + u64(run.count) {
				if bytes_read >= u64(size) {
					break
				}
				if !fs.sector_read(g_disk, fs.Sector(sec), sector_buf[:]) {
					break
				}

				chunk := sector_buf[byte_offset:]
				available := u64(len(chunk))
				remaining := u64(size) - bytes_read
				n := min(available, remaining)

				mem.copy(rawptr(buf[bytes_read:]), raw_data(chunk), int(n))
				bytes_read += n
				pos_in_file += u64(byte_offset) + n
				byte_offset = 0
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
