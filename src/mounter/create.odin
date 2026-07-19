// create.odin — FUSE create/mkdir/symlink/unlink/rmdir/rename callbacks for fused.
#+build linux
package mounter

import "base:runtime"
import "core:c"
import "core:log"
import "core:os"
import "core:sys/posix"
import "src:fuse3"
import "src:fs"

// fused_create creates a new file (FUSE create callback).
fused_create :: proc "c" (path: cstring, mode: posix.mode_t, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)

	parent, name := os.split_path(string(path))
	parent_entry, _, _, _, ok := resolve_path_cached(fsys, parent, context.temp_allocator)
	if !ok {
		log.debugf("create: %s → parent ENOENT", path)
		return fuse3.nix(.ENOENT)
	}

	dir_cluster := fs.Cluster(parent_entry.stored_cluster)
	dir_offset := fs.Sector_Offset(parent_entry.sector_index)
	if check_name_exists(fsys, dir_cluster, dir_offset, name) {
		log.debugf("create: %s → EEXIST", path)
		return fuse3.nix(.EEXIST)
	}

	dcluster, dsec, didx, slot_ok := find_or_extend_dir(fsys, dir_cluster, dir_offset)
	if !slot_ok {
		log.debugf("create: %s → ENOSPC (dir full)", path)
		return fuse3.nix(.ENOSPC)
	}

	flags := fs.Dir_Flags{.Allocated, .Exists}
	if .IFDIR in mode {
		flags += {.Directory}
	}

	ctx := fuse3.fuse_get_context()
	new_entry: fs.Directory_Entry
	new_entry.flags = flags
	new_entry.uid = u32(ctx.uid)
	new_entry.gid = u32(ctx.gid)
	if !write_entry_with_lfn(fsys, &new_entry, name) {
		return fuse3.nix(.ENOSPC)
	}
	if !fs.write_directory_entry_at(&fsys.vol, dcluster, dsec, didx, &new_entry) {
		return fuse3.nix(.EIO)
	}

	fi.fh = transmute(u64)(fs.File_Handle{dir_cluster = u64(dcluster), dir_offset = u16(dsec), entry_index = u16(didx)})
	path_cache_invalidate_all(fsys)
	log.debugf("create: %s → ok", path)
	return 0
}

// fused_mkdir creates a new directory (FUSE mkdir callback).
fused_mkdir :: proc "c" (path: cstring, mode: posix.mode_t) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)

	parent, name := os.split_path(string(path))
	parent_entry, _, _, _, ok := resolve_path_cached(fsys, parent, context.temp_allocator)
	if !ok {
		return fuse3.nix(.ENOENT)
	}

	dir_cluster := fs.Cluster(parent_entry.stored_cluster)
	dir_offset := fs.Sector_Offset(parent_entry.sector_index)
	if check_name_exists(fsys, dir_cluster, dir_offset, name) {
		return fuse3.nix(.EEXIST)
	}

	dcluster, dsec, didx, slot_ok := find_or_extend_dir(fsys, dir_cluster, dir_offset)
	if !slot_ok {
		return fuse3.nix(.ENOSPC)
	}

	new_cluster, new_offset, derr := fs.allocate_sectors(&fsys.vol, 0, 0, 1, .Directory)
	if derr != .None {
		return fuse3.nix(.ENOSPC)
	}

	dir_runs, dr_err := fs.resolve_extents(&fsys.vol, new_cluster, new_offset)
	defer delete(dir_runs)
	if dr_err != .None || len(dir_runs) == 0 {
		return fuse3.nix(.EIO)
	}

	zero: [fs.SECTOR_SIZE]u8
	if !fs.sector_write(&fsys.vol, dir_runs[0].sector, zero[:]) {
		return fuse3.nix(.EIO)
	}

	new_entry: fs.Directory_Entry
	new_entry.flags = fs.Dir_Flags{.Allocated, .Directory, .Exists}
	new_entry.sector_index = u16(new_offset)
	new_entry.stored_cluster = u64(new_cluster)
	ctx := fuse3.fuse_get_context()
	new_entry.uid = u32(ctx.uid)
	new_entry.gid = u32(ctx.gid)

	set_entry_time_to_now(&new_entry)
	copy(new_entry.file_name[:], name)
	if len(name) < 16 {
		new_entry.file_name[len(name)] = 0
	}
	if !fs.write_directory_entry_at(&fsys.vol, dcluster, dsec, didx, &new_entry) {
		return fuse3.nix(.EIO)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("mkdir: %s → ok", path)
	return 0
}

// fused_symlink creates a symbolic link (FUSE symlink callback).
fused_symlink :: proc "c" (target: cstring, linkpath: cstring) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)

	target_str := string(target)
	parent, name := os.split_path(string(linkpath))
	parent_entry, _, _, _, ok := resolve_path_cached(fsys, parent, context.temp_allocator)
	if !ok {
		return fuse3.nix(.ENOENT)
	}

	dir_cluster := fs.Cluster(parent_entry.stored_cluster)
	dir_offset := fs.Sector_Offset(parent_entry.sector_index)
	if check_name_exists(fsys, dir_cluster, dir_offset, name) {
		return fuse3.nix(.EEXIST)
	}

	dcluster, dsec, didx, slot_ok := find_or_extend_dir(fsys, dir_cluster, dir_offset)
	if !slot_ok {
		return fuse3.nix(.ENOSPC)
	}

	sectors_needed := (u64(len(target_str)) + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE
	new_c, new_o, aerr := fs.allocate_sectors(&fsys.vol, 0, 0, sectors_needed, .File_Content)
	if aerr != .None {
		return fuse3.nix(.ENOSPC)
	}
	
	{
		runs, r_err := fs.resolve_extents(&fsys.vol, new_c, new_o)
		defer delete(runs)
		if r_err != .None || len(runs) == 0 {
			return fuse3.nix(.EIO)
		}

		buf: [fs.SECTOR_SIZE]u8
		copy(buf[:], transmute([]u8)(target_str))
		if !fs.sector_write(&fsys.vol, runs[0].sector, buf[:]) {
			return fuse3.nix(.EIO)
		}
	}

	new_entry: fs.Directory_Entry
	new_entry.flags = fs.Dir_Flags{.Allocated, .Exists, .Link}
	new_entry.stored_cluster = u64(new_c)
	new_entry.sector_index = u16(new_o)
	new_entry.file_size = u64(len(target_str))
	ctx2 := fuse3.fuse_get_context()
	new_entry.uid = u32(ctx2.uid)
	new_entry.gid = u32(ctx2.gid)

	set_entry_time_to_now(&new_entry)
	if !write_entry_with_lfn(fsys, &new_entry, name) {
		return fuse3.nix(.ENOSPC)
	}
	if !fs.write_directory_entry_at(&fsys.vol, dcluster, dsec, didx, &new_entry) {
		return fuse3.nix(.EIO)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("symlink: %s → %s ok", linkpath, target)
	return 0
}

// fused_unlink removes a file (FUSE unlink callback).
fused_unlink :: proc "c" (path: cstring) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)

	entry, cluster, offset, idx, ok := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if !ok {
		log.debugf("unlink: %s → ENOENT", path)
		return fuse3.nix(.ENOENT)
	}
	if .Directory in entry.flags {
		log.debugf("unlink: %s → EISDIR", path)
		return fuse3.nix(.EISDIR)
	}
	if entry.stored_cluster != 0 {
		if derr := fs.deallocate_sectors(&fsys.vol, fs.Cluster(entry.stored_cluster), fs.Sector_Offset(entry.sector_index)); derr != .None {
			return fs_error_to_errno(derr)
		}
	}

	entry.flags = {}
	if !write_entry_back(fsys, &entry, cluster, offset, idx) {
		return fuse3.nix(.EIO)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("unlink: %s → ok", path)
	return 0
}

// fused_rmdir removes a directory (FUSE rmdir callback).
fused_rmdir :: proc "c" (path: cstring) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)

	entry, cluster, offset, idx, ok := resolve_path_cached(fsys, string(path), context.temp_allocator)
	if !ok {
		return fuse3.nix(.ENOENT)
	}
	if .Directory not_in entry.flags {
		log.debugf("rmdir: %s → ENOTDIR", path)
		return fuse3.nix(.ENOTDIR)
	}

	dirs, dir_err := fs.read_directory_entries(&fsys.vol, fs.Cluster(entry.stored_cluster), fs.Sector_Offset(entry.sector_index))
	defer delete(dirs)
	if dir_err != .None {}
	for &d in dirs {
		if .Exists in d.flags {
			log.debugf("rmdir: %s → ENOTEMPTY", path)
			return fuse3.nix(.ENOTEMPTY)
		}
	}
	if entry.stored_cluster != 0 {
		if derr := fs.deallocate_sectors(&fsys.vol, fs.Cluster(entry.stored_cluster), fs.Sector_Offset(entry.sector_index)); derr != .None {
			return fs_error_to_errno(derr)
		}
	}

	entry.flags = {}
	if !write_entry_back(fsys, &entry, cluster, offset, idx) {
		return fuse3.nix(.EIO)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("rmdir: %s → ok", path)
	return 0
}

// fused_rename renames or moves a file or directory (FUSE rename callback).
fused_rename :: proc "c" (oldpath: cstring, newpath: cstring, flags: c.uint) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)

	if u32(flags) & u32(fuse3.RENAME_NOREPLACE) != 0 {
		log.debugf("rename: RENAME_NOREPLACE not supported")
		return fuse3.nix(.ENOSYS)
	}
	if u32(flags) & u32(fuse3.RENAME_EXCHANGE) != 0 {
		log.debugf("rename: RENAME_EXCHANGE not supported")
		return fuse3.nix(.ENOSYS)
	}

	entry, old_cluster, old_offset, old_idx, ok := resolve_path_cached(fsys, string(oldpath), context.temp_allocator)
	if !ok {
		log.debugf("rename: %s → ENOENT", oldpath)
		return fuse3.nix(.ENOENT)
	}

	new_parent_path, new_name := os.split_path(string(newpath))
	_, new_parent_c, new_parent_o, _, np_ok := resolve_path_cached(fsys, new_parent_path, context.temp_allocator)
	if !np_ok {
		log.debugf("rename: %s → parent ENOENT", newpath)
		return fuse3.nix(.ENOENT)
	}
	if old_cluster == new_parent_c && old_offset == new_parent_o {
		if dst_entry, _, _, dst_idx, dst_ok := resolve_path_cached(fsys, string(newpath), context.temp_allocator); dst_ok {
			if .Directory not_in dst_entry.flags {
				if dst_entry.stored_cluster != 0 {
					if derr := fs.deallocate_sectors(&fsys.vol, fs.Cluster(dst_entry.stored_cluster), fs.Sector_Offset(dst_entry.sector_index)); derr != .None {
						return fuse3.nix(.EIO)
					}
				}

				dst_entry.flags = {}
				if !write_entry_back(fsys, &dst_entry, new_parent_c, new_parent_o, dst_idx) {
					return fuse3.nix(.EIO)
				}
			} else {
				log.debugf("rename: %s → %s → EISDIR (destination is dir)", oldpath, newpath)
				return fuse3.nix(.EISDIR)
			}
		}
		if !set_entry_name(fsys, &entry, new_name) {
			return fuse3.nix(.ENOSPC)
		}
		if !write_entry_back(fsys, &entry, old_cluster, old_offset, old_idx) {
			return fuse3.nix(.EIO)
		}

		path_cache_invalidate_all(fsys)
		log.debugf("rename: %s → %s ok", oldpath, newpath)
		return 0
	}
	if .Directory in entry.flags {
		check_path := new_parent_path
		for check_path != "/" {
			check_entry, _, _, _, check_ok := resolve_path_cached(fsys, check_path, context.temp_allocator)
			if !check_ok {
				break
			}
			if fs.Cluster(check_entry.stored_cluster) == old_cluster && fs.Sector_Offset(check_entry.sector_index) == old_offset {
				log.debugf("rename: %s → %s → EINVAL (circular)", oldpath, newpath)
				return fuse3.nix(.EINVAL)
			}

			parent_of_check, _ := os.split_path(check_path)
			check_path = parent_of_check
		}
	}

	dst_idx := -1
	if dst_entry, _, _, dst_idx_resolved, dst_ok := resolve_path_cached(fsys, string(newpath), context.temp_allocator); dst_ok {
		dst_idx = dst_idx_resolved
		if .Directory not_in dst_entry.flags {
			if dst_entry.stored_cluster != 0 {
				if derr := fs.deallocate_sectors(&fsys.vol, fs.Cluster(dst_entry.stored_cluster), fs.Sector_Offset(dst_entry.sector_index)); derr != .None {
					return fuse3.nix(.EIO)
				}
			}

			dst_entry.flags = {}
			if !write_entry_back(fsys, &dst_entry, new_parent_c, new_parent_o, dst_idx) {
				return fuse3.nix(.EIO)
			}
		} else {
			log.debugf("rename: %s → %s → EISDIR (destination is dir)", oldpath, newpath)
			return fuse3.nix(.EISDIR)
		}
	}

	dst_cluster, dst_sec, dst_slot_idx, slot_ok := find_or_extend_dir(fsys, new_parent_c, new_parent_o)
	if !slot_ok {
		return fuse3.nix(.ENOSPC)
	}
	if !set_entry_name(fsys, &entry, new_name) {
		return fuse3.nix(.ENOSPC)
	}
	if !fs.write_directory_entry_at(&fsys.vol, dst_cluster, dst_sec, dst_slot_idx, &entry) {
		return fuse3.nix(.EIO)
	}

	entry.flags = {}
	if !write_entry_back(fsys, &entry, old_cluster, old_offset, old_idx) {
		return fuse3.nix(.EIO)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("rename: %s → %s ok (cross-directory)", oldpath, newpath)
	return 0
}
