// misc.odin — auxiliary FUSE callbacks for the fused filesystem.
#+build linux
package mounter

import "base:runtime"
import "core:c"
import "core:log"
import "core:os"
import "core:sys/posix"
import "src:fs"
import "src:fuse3"

// fused_utimens sets access and modification times on a file or directory.
fused_utimens :: proc "c" (path: cstring, tv: [^]posix.timespec, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)
	return mutate_entry_at(fsys, path, fi, proc(entry: ^fs.Directory_Entry, user: rawptr) -> bool {
			tv := ([^]posix.timespec)(user)
			if tv == nil {
				set_entry_time_to_now(entry)
			} else {
				nsec1 := int(tv[1].tv_nsec)
				if nsec1 == UTIME_OMIT {
				} else if nsec1 == UTIME_NOW {
					set_entry_mtime_to_now(entry)
				} else {
					set_entry_mtime_from_unix(entry, i64(tv[1].tv_sec))
				}

				nsec0 := int(tv[0].tv_nsec)
				if nsec0 == UTIME_OMIT {
				} else if nsec0 == UTIME_NOW {
					set_entry_atime_to_now(entry)
				} else {
					set_entry_atime_from_unix(entry, i64(tv[0].tv_sec))
				}
			}
			return true
		}, rawptr(tv), false)
}

// fused_access checks file access permissions.
fused_access :: proc "c" (path: cstring, mask: c.int) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)

	entry, _, _, _, rerr := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if rerr != .None {
		return fs_error_to_errno(rerr)
	}

	m := transmute(posix.Mode_Flags)(mask) // TRANSMUTE: c.int ABI word bit-view as flag set
	if (posix.Mode_Flag_Bits.R_OK in m) && .No_Read in entry.flags {
		return fuse3.nix(.EACCES)
	}
	if (posix.Mode_Flag_Bits.W_OK in m) &&
	   (.No_Write in entry.flags || .Read_Only in entry.flags) {
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

	Chmod_Ctx :: struct {
		mode: posix.mode_t,
	}

	ctx := Chmod_Ctx {
		mode = mode,
	}

	rc := mutate_entry_at(fsys, path, fi, proc(entry: ^fs.Directory_Entry, user: rawptr) -> bool {
			m := (^Chmod_Ctx)(user).mode
			mr := posix.mode_t{.IRUSR, .IRGRP, .IROTH} & m
			has_read := mr != {}
			mw := posix.mode_t{.IWUSR, .IWGRP, .IWOTH} & m
			has_write := mw != {}
			mx := posix.mode_t{.IXUSR, .IXGRP, .IXOTH} & m
			has_exec := mx != {}

			if has_read { entry.flags -= {.No_Read} } else { entry.flags += {.No_Read} }
			if has_write { entry.flags -= {.No_Write, .Read_Only} } else { entry.flags += {.No_Write, .Read_Only} }
			if has_exec { entry.flags -= {.No_Execute} } else { entry.flags += {.No_Execute} }
			return true
		}, &ctx)
	if rc == 0 {
		log.debugf("chmod: %s → mode=%v", path, mode)
	}
	return rc
}

// fused_chown changes file ownership. No-op aside from storing uid/gid.
fused_chown :: proc "c" (
	path: cstring,
	uid: posix.uid_t,
	gid: posix.gid_t,
	fi: ^fuse3.File_Info,
) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)

	Chown_Ctx :: struct {
		uid: posix.uid_t,
		gid: posix.gid_t,
	}

	ctx := Chown_Ctx {
		uid = uid,
		gid = gid,
	}

	rc := mutate_entry_at(fsys, path, fi, proc(entry: ^fs.Directory_Entry, user: rawptr) -> bool {
			c := (^Chown_Ctx)(user)
			uid_t_max :: posix.uid_t(0xFFFFFFFF)
			gid_t_max :: posix.gid_t(0xFFFFFFFF)
			if c.uid != uid_t_max { entry.uid = u32(c.uid) }
			if c.gid != gid_t_max { entry.gid = u32(c.gid) }
			return true
		}, &ctx)
	if rc == 0 {
		log.debugf("chown: %s → uid=%d gid=%d", path, uid, gid)
	}
	return rc
}

// fused_flush flushes a file by syncing the underlying disk.
// UNLOCKED: fd-level os.sync only; touches no shared state.
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
	fsys := begin_op()
	defer end_op(fsys)
	// Drop this owner's locks when the fd closes (kernel releases a
	// process's locks when its last fd to the file closes). Takes the write
	// lock: the lock tables are shared mutable state.
	locks_remove_owner(fsys, fh_parts(fi.fh), fi.lock_owner)
	log.debugf("release: %s → ok", path)
	return 0
}

// fused_opendir opens a directory (no-op).
// UNLOCKED: no-op; touches no shared state.
fused_opendir :: proc "c" (path: cstring, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	return 0
}

// fused_releasedir closes a directory handle (no-op).
// UNLOCKED: no-op; touches no shared state.
fused_releasedir :: proc "c" (path: cstring, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	return 0
}

// fused_fsync fsyncs a file by syncing the underlying disk.
// UNLOCKED: fd-level os.sync only; touches no shared state.
fused_fsync :: proc "c" (path: cstring, datasync: c.int, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	os.sync(fsys.vol.disk)
	return 0
}

// fused_lseek seeks within a file; supports SEEK_DATA and SEEK_HOLE.
fused_lseek :: proc "c" (
	path: cstring,
	off: posix.off_t,
	whence: c.int,
	fi: ^fuse3.File_Info,
) -> posix.off_t {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)
	// Integer-to-enum conversion is explicit; out-of-range words compare
	// unequal to every variant and fall into ENOSYS below.
	seek_how := fuse3.Seek_Whence(whence)
	if seek_how != .Data && seek_how != .Hole {
		return posix.off_t(fuse3.nix(.ENOSYS))
	}

	entry, data_cluster, data_offset, err := read_entry_from_fh(fsys, fi.fh)
	if err != .None {
		return posix.off_t(fs_error_to_errno(err))
	}

	runs, rerr := resolve_extents_cached(fsys, data_cluster, data_offset)
	if rerr != .None {
		return posix.off_t(fuse3.nix(.ENOENT))
	}

	pos := u64(off)
	file_size := u64(entry.file_size)
	if len(runs) == 0 {
		if seek_how == .Data {
			return posix.off_t(file_size)
		}
		return posix.off_t(pos)
	}

	// Walk extent runs in file-offset space; the two whence values
	// share the run walk, differing only in the hole/data predicate.
	is_data := seek_how == .Data
	offset: u64 = 0
	for run in runs {
		run_end := offset + u64(run.count) * fs.SECTOR_SIZE
		if is_data {
			if pos < run_end {
				return posix.off_t(max(pos, offset))
			}
		} else {
			if pos < offset {
				return posix.off_t(pos)
			}
			if pos >= offset && pos < run_end {
				pos = run_end
			}
		}
		offset = run_end
	}
	if !is_data && pos < file_size {
		return posix.off_t(pos)
	}
	return posix.off_t(file_size)
}

// fused_statfs returns filesystem statistics. Takes the read lock: it reads
// the shared free-sector count (and master record) but mutates nothing.
fused_statfs :: proc "c" (path: cstring, stbuf: ^posix.statvfs_t) -> c.int {
	context = runtime.default_context()
	fsys := begin_read_op()
	defer end_read_op(fsys)

	total_sectors := u64(fsys.vol.image_size) / fs.SECTOR_SIZE
	free_sectors := fsys.free_sectors
	// NAME_MAX is the Linux VFS filename limit (<linux/limits.h>); the
	// statvfs-facing claim, independent of the on-disk LFN capacity.
	NAME_MAX :: 255
	stbuf^ = {
		f_bsize   = c.ulong(fs.SECTOR_SIZE),
		f_frsize  = c.ulong(fs.SECTOR_SIZE),
		f_blocks  = posix.fsblkcnt_t(total_sectors),
		f_bfree   = posix.fsblkcnt_t(free_sectors),
		f_bavail  = posix.fsblkcnt_t(free_sectors),
		f_files   = posix.fsblkcnt_t(
			fsys.vol.master.cluster_map_size * u64(dir_entries_per_buf(fsys.vol.master.features)),
		),
		f_ffree   = posix.fsblkcnt_t(
			fsys.vol.master.cluster_map_size * u64(dir_entries_per_buf(fsys.vol.master.features)),
		),
		f_favail  = posix.fsblkcnt_t(
			fsys.vol.master.cluster_map_size * u64(dir_entries_per_buf(fsys.vol.master.features)),
		),
		f_flag    = posix.VFS_Flags{},
		f_namemax = c.ulong(NAME_MAX),
	}
	return 0
}

// fused_fsyncdir fsyncs a directory by syncing the underlying disk.
// UNLOCKED: fd-level os.sync only; touches no shared state.
fused_fsyncdir :: proc "c" (path: cstring, datasync: c.int, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	os.sync(fsys.vol.disk)
	return 0
}

// fused_mknod is a stub that returns ENOSYS.
// UNLOCKED: stub; touches no shared state (debug log only).
fused_mknod :: proc "c" (path: cstring, mode: posix.mode_t, rdev: posix.dev_t) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	log.debugf("mknod: %s → ENOSYS (not supported)", path)
	return -posix.ENOSYS
}

// fused_ioctl is a stub that returns ENOSYS.
// UNLOCKED: stub; touches no shared state (debug log only).
fused_ioctl :: proc "c" (
	path: cstring,
	cmd: c.int,
	arg: rawptr,
	fi: ^fuse3.File_Info,
	flags: c.uint,
	data: rawptr,
) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	log.debugf("ioctl: %s cmd=%d → ENOSYS (not supported)", path, cmd)
	return -posix.ENOSYS
}

// fused_link is a stub that returns ENOSYS.
// UNLOCKED: stub; touches no shared state (debug log only).
fused_link :: proc "c" (oldpath: cstring, newpath: cstring) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	log.debugf("link: %s → %s → ENOSYS (hard links not supported)", oldpath, newpath)
	return -posix.ENOSYS
}

// fused_statx is a stub that returns ENOSYS.
// UNLOCKED: stub; touches no shared state (debug log only).
fused_statx :: proc "c" (
	path: cstring,
	flags: c.int,
	mask: c.int,
	stxbuf: rawptr,
	fi: ^fuse3.File_Info,
) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	log.debugf("statx: %s → ENOSYS (not supported)", path)
	return -posix.ENOSYS
}

// fused_bmap maps a logical block index to a physical sector for a file.
fused_bmap :: proc "c" (path: cstring, blocksize: c.size_t, idx: ^c.uint64_t) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)

	entry, _, _, _, rerr := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if rerr != .None {
		return fs_error_to_errno(rerr)
	}
	if .Directory in entry.flags {
		return fuse3.nix(.EISDIR)
	}

	data_cluster := fs.Cluster(entry.stored_cluster)
	data_offset := fs.Sector_Offset(entry.sector_index)
	runs, xerr := resolve_extents_cached(fsys, data_cluster, data_offset)
	if xerr != .None || len(runs) == 0 {
		return fuse3.nix(.EIO)
	}

	sector_per_block := u64(blocksize) / fs.SECTOR_SIZE
	if sector_per_block == 0 {
		sector_per_block = 1
	}

	logical_sector := u64(idx^) * sector_per_block
	// Walk extent runs to find which run contains this logical sector.
	file_offset: u64
	for run in runs {
		run_sectors := u64(run.count)
		run_end := file_offset + run_sectors * fs.SECTOR_SIZE
		logical_byte := logical_sector * fs.SECTOR_SIZE
		if logical_byte >= file_offset && logical_byte < run_end {
			sector_in_run := (logical_byte - file_offset) / fs.SECTOR_SIZE
			idx^ = c.uint64_t(u64(run.sector) + sector_in_run)
			return 0
		}
		file_offset = run_end
	}
	return fuse3.nix(.EINVAL)
}

// fused_poll returns POLLERR — this filesystem has no special I/O readiness
// semantics; the kernel uses standard page-cache notification for reads and
// writes.
// UNLOCKED: returns a constant; touches no shared state.
fused_poll :: proc "c" (
	path: cstring,
	fi: ^fuse3.File_Info,
	ph: ^fuse3.Pollhandle,
	reventsp: ^c.uint,
) -> c.int {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	if reventsp != nil {
		reventsp^ = c.uint(posix.POLLERR)
	}
	return 0
}

// FUSE INIT handshake tuning.
FUSE_TIME_GRAN :: c.uint32_t(1) // timestamp granularity, nanoseconds
FUSE_MAX_BACKGROUND :: c.uint32_t(16) // max outstanding background requests
FUSE_CONGESTION_THRESHOLD :: c.uint32_t(12) // background queue congestion mark

// fused_init initialises FUSE, configures connection info, and returns the FS
// pointer as private_data.
// UNLOCKED: mount-time handshake, single-threaded; only fills conn fields.
fused_init :: proc "c" (conn_info: ^fuse3.Conn_Info, cfg: ^fuse3.Config) -> rawptr {
	context = runtime.default_context()
	fsys := get_fs()
	context.logger = fsys.logger
	conn_info.time_gran = FUSE_TIME_GRAN
	conn_info.max_background = FUSE_MAX_BACKGROUND
	conn_info.congestion_threshold = FUSE_CONGESTION_THRESHOLD
	// Advertise remote locking support so the kernel forwards FUSE_LOCK and
	// FUSE_FLOCK requests (POSIX locks and BSD flock) to us instead of
	// handling them in-kernel.
	conn_info.want |= FUSE_POSIX_LOCKS | FUSE_FLOCK_LOCKS
	log.debugf(
		"init: fused rev %d, cluster_size=%d",
		fsys.vol.master.rev_max,
		fsys.vol.master.cluster_size,
	)
	return fsys
}

// fused_destroy performs FUSE cleanup on unmount.
// UNLOCKED: unmount-time logging only; event loop already exited, no concurrency.
fused_destroy :: proc "c" (private_data: rawptr) {
	context = runtime.default_context()
	fsys := (^FS)(private_data)
	context.logger = fsys.logger
	log.debugf("destroy: fused unmounting")
}
