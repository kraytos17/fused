// misc.odin — auxiliary FUSE callbacks for the fused filesystem.
#+build linux
package mounter

import "base:runtime"
import "core:c"
import "core:container/lru"
import "core:log"
import "core:os"
import "core:sys/posix"
import "src:fuse3"
import "src:fs"

// fused_utimens sets access and modification times on a file or directory.
fused_utimens :: proc "c" (path: cstring, tv: [^]posix.timespec, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)

	entry, entry_cluster, entry_offset, entry_idx, _, _, resolved := resolve_entry(fsys, path, fi)
	if !resolved {return fuse3.nix(.ENOENT)}
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
	if !write_entry_back(fsys, &entry, entry_cluster, entry_offset, entry_idx) {
		return fuse3.nix(.EIO)
	}
	lru.remove(&fsys.path_cache, string(path))
	return 0
}

// fused_access checks file access permissions.
fused_access :: proc "c" (path: cstring, mask: c.int) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)

	entry, _, _, _, ok := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if !ok {
		return fuse3.nix(.ENOENT)
	}

	m := transmute(posix.Mode_Flags)(mask)
	if (posix.Mode_Flag_Bits.R_OK in m) && .No_Read in entry.flags {
		return fuse3.nix(.EACCES)
	}
	if (posix.Mode_Flag_Bits.W_OK in m) && (.No_Write in entry.flags || .Read_Only in entry.flags) {
		return fuse3.nix(.EACCES)
	}
	if (posix.Mode_Flag_Bits.X_OK in m) && .No_Execute in entry.flags {
		if .Directory not_in entry.flags {
			return fuse3.nix(.EACCES)
		}
	}
	log.debugf("access: %s → mask=%d ok", path, mask)
	return 0
}

// fused_chmod changes file permissions.
fused_chmod :: proc "c" (path: cstring, mode: posix.mode_t, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)

	entry, entry_cluster, entry_offset, entry_idx, _, _, resolved := resolve_entry(fsys, path, fi)
	if !resolved {
		return fuse3.nix(.ENOENT)
	}

	mr := posix.mode_t{.IRUSR, .IRGRP, .IROTH} & mode
	has_read := mr != {}
	mw := posix.mode_t{.IWUSR, .IWGRP, .IWOTH} & mode
	has_write := mw != {}
	mx := posix.mode_t{.IXUSR, .IXGRP, .IXOTH} & mode
	has_exec := mx != {}

	if has_read {entry.flags -= {.No_Read}} else {entry.flags += {.No_Read}}
	if has_write {entry.flags -= {.No_Write, .Read_Only}} else {entry.flags += {.No_Write, .Read_Only}}
	if has_exec {entry.flags -= {.No_Execute}} else {entry.flags += {.No_Execute}}
	if !write_entry_back(fsys, &entry, entry_cluster, entry_offset, entry_idx) {
		return fuse3.nix(.EIO)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("chmod: %s → mode=%v", path, mode)
	return 0
}

// fused_chown changes file ownership. No-op aside from storing uid/gid.
fused_chown :: proc "c" (path: cstring, uid: posix.uid_t, gid: posix.gid_t, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)

	entry, entry_cluster, entry_offset, entry_idx, _, _, resolved := resolve_entry(fsys, path, fi)
	if !resolved {return fuse3.nix(.ENOENT)}

	uid_t_max :: posix.uid_t(0xFFFFFFFF)
	gid_t_max :: posix.gid_t(0xFFFFFFFF)
	if uid != uid_t_max {
		entry.uid = u32(uid)
	}
	if gid != gid_t_max {
		entry.gid = u32(gid)
	}
	if !write_entry_back(fsys, &entry, entry_cluster, entry_offset, entry_idx) {
		return fuse3.nix(.EIO)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("chown: %s → uid=%d gid=%d", path, entry.uid, entry.gid)
	return 0
}

// fused_flush flushes a file by syncing the underlying disk.
fused_flush :: proc "c" (path: cstring, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	os.sync(fsys.vol.disk)
	log.debugf("flush: %s → ok", path)
	return 0
}

// fused_release closes a file handle.
fused_release :: proc "c" (path: cstring, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	log.debugf("release: %s → ok", path)
	return 0
}

// fused_opendir opens a directory (no-op).
fused_opendir :: proc "c" (path: cstring, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	return 0
}

// fused_releasedir closes a directory handle (no-op).
fused_releasedir :: proc "c" (path: cstring, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	return 0
}

// fused_fsync fsyncs a file by syncing the underlying disk.
fused_fsync :: proc "c" (path: cstring, datasync: c.int, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	os.sync(fsys.vol.disk)
	return 0
}

// fused_lseek seeks within a file; supports SEEK_DATA and SEEK_HOLE.
fused_lseek :: proc "c" (path: cstring, off: posix.off_t, whence: c.int, fi: ^fuse3.File_Info) -> posix.off_t {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)

	if whence != fuse3.SEEK_DATA && whence != fuse3.SEEK_HOLE {
		return posix.off_t(-int(fuse3.nix(.ENOSYS)))
	}

	entry, data_cluster, data_offset, ok := read_entry_from_fh(fsys, fi.fh)
	if !ok {
		return posix.off_t(-int(fuse3.nix(.ENOENT)))
	}

	runs, ext_err := fs.resolve_extents(&fsys.vol, data_cluster, data_offset)
	defer delete(runs)
	if ext_err != .None {
		return posix.off_t(-int(fuse3.nix(.ENOENT)))
	}

	pos := u64(off)
	file_size := u64(entry.file_size)
	if len(runs) == 0 {
		if whence == fuse3.SEEK_DATA {
			return posix.off_t(file_size)
		}
		return posix.off_t(pos)
	}

	// Walk extent runs in file-offset space
	offset: u64 = 0
	if whence == fuse3.SEEK_DATA {
		for run in runs {
			run_end := offset + u64(run.count) * fs.SECTOR_SIZE
			if pos < run_end {
				return posix.off_t(max(pos, offset))
			}
			offset = run_end
		}
		return posix.off_t(file_size)
	}
	// SEEK_HOLE
	for run in runs {
		run_end := offset + u64(run.count) * fs.SECTOR_SIZE
		if pos < offset {
			return posix.off_t(pos)
		}
		if pos >= offset && pos < run_end {
			pos = run_end
		}
		offset = run_end
	}
	if pos < file_size {
		return posix.off_t(pos)
	}
	return posix.off_t(file_size)
}

// fused_statfs returns filesystem statistics.
fused_statfs :: proc "c" (path: cstring, stbuf: ^posix.statvfs_t) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	total_sectors := u64(fsys.vol.image_size) / fs.SECTOR_SIZE
	free_sectors := fs.alloc_cache_count_free(&fsys.vol)
	stbuf^ = {
		f_bsize   = c.ulong(fs.SECTOR_SIZE),
		f_frsize  = c.ulong(fs.SECTOR_SIZE),
		f_blocks  = posix.fsblkcnt_t(total_sectors),
		f_bfree   = posix.fsblkcnt_t(free_sectors),
		f_bavail  = posix.fsblkcnt_t(free_sectors),
		f_files   = posix.fsblkcnt_t(fsys.vol.master.cluster_map_size * u64(dir_entries_per_buf(fsys.vol.master.features))),
		f_ffree   = posix.fsblkcnt_t(fsys.vol.master.cluster_map_size * u64(dir_entries_per_buf(fsys.vol.master.features))),
		f_favail  = posix.fsblkcnt_t(fsys.vol.master.cluster_map_size * u64(dir_entries_per_buf(fsys.vol.master.features))),
		f_flag    = posix.VFS_Flags{},
		f_namemax = c.ulong(255),
	}
	return 0
}

// fused_fsyncdir fsyncs a directory by syncing the underlying disk.
fused_fsyncdir :: proc "c" (path: cstring, datasync: c.int, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	os.sync(fsys.vol.disk)
	return 0
}

// fused_mknod is a stub that returns ENOSYS.
fused_mknod :: proc "c" (path: cstring, mode: posix.mode_t, rdev: posix.dev_t) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	return -posix.ENOSYS
}

// fused_ioctl is a stub that returns ENOSYS.
fused_ioctl :: proc "c" (path: cstring, cmd: c.int, arg: rawptr, fi: ^fuse3.File_Info, flags: c.uint, data: rawptr) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	return -posix.ENOSYS
}

// fused_link is a stub that returns ENOSYS.
fused_link :: proc "c" (oldpath: cstring, newpath: cstring) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	return -posix.ENOSYS
}

// fused_statx is a stub that returns ENOSYS.
fused_statx :: proc "c" (path: cstring, flags: c.int, mask: c.int, stxbuf: rawptr, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	return -posix.ENOSYS
}

// fused_init initialises FUSE, configures connection info, and returns the FS
// pointer as private_data.
fused_init :: proc "c" (conn_info: ^fuse3.Conn_Info, cfg: ^fuse3.Config) -> rawptr {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	conn_info.time_gran = 1
	conn_info.max_background = 16
	conn_info.congestion_threshold = 12
	log.debugf("init: fused rev %d, cluster_size=%d", fsys.vol.master.rev_max, fsys.vol.master.cluster_size)
	return fsys
}

// fused_destroy performs FUSE cleanup on unmount.
fused_destroy :: proc "c" (private_data: rawptr) {
	context = runtime.default_context()
	fsys := (^FS)(private_data)
	context.logger = fsys.logger
	log.debugf("destroy: fused unmounting")
}
