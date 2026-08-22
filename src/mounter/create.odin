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

// Prepare_Slot_Result distinguishes why prepare_parent_slot failed so
// callers map it to the correct errno.
Prepare_Slot_Result :: enum {
	Ok,
	Parent_Not_Found,
	Name_Exists,
	Dir_Full,
}

// prepare_parent_slot resolves a path's parent directory and finds a free
// entry slot in it, sharing the preamble of create/mkdir/symlink.  The
// returned name is the final path component.
prepare_parent_slot :: proc(fsys: ^FS, path: string) -> (res: Prepare_Slot_Result, dcluster: fs.Cluster, dsec: fs.Sector_Offset, didx: int, name: string) {
	parent, base_name := os.split_path(path)
	parent_entry, _, _, _, pok := resolve_path_cached(fsys, parent, context.temp_allocator)
	if !pok {
		return .Parent_Not_Found, {}, 0, 0, ""
	}

	dir_cluster := fs.Cluster(parent_entry.stored_cluster)
	dir_offset := fs.Sector_Offset(parent_entry.sector_index)
	if check_name_exists(fsys, dir_cluster, dir_offset, base_name) {
		return .Name_Exists, {}, 0, 0, ""
	}

	slot_c, slot_o, slot_i, slot_ok := find_or_extend_dir(fsys, dir_cluster, dir_offset)
	if !slot_ok {
		return .Dir_Full, {}, 0, 0, ""
	}
	return .Ok, slot_c, slot_o, slot_i, base_name
}

// fused_create creates a new file (FUSE create callback).
fused_create :: proc "c" (path: cstring, mode: posix.mode_t, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)

	res, dcluster, dsec, didx, name := prepare_parent_slot(fsys, string(path))
	switch res {
	case .Parent_Not_Found:
		log.debugf("create: %s → parent ENOENT", path)
		return fuse3.nix(.ENOENT)
	case .Name_Exists:
		log.debugf("create: %s → EEXIST", path)
		return fuse3.nix(.EEXIST)
	case .Dir_Full:
		log.debugf("create: %s → ENOSPC (dir full)", path)
		return fuse3.nix(.ENOSPC)
	case .Ok:
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
	if fs.write_directory_entry_at(&fsys.vol, dcluster, dsec, didx, &new_entry) != .None {
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

	res, dcluster, dsec, didx, name := prepare_parent_slot(fsys, string(path))
	switch res {
	case .Parent_Not_Found:
		return fuse3.nix(.ENOENT)
	case .Name_Exists:
		return fuse3.nix(.EEXIST)
	case .Dir_Full:
		return fuse3.nix(.ENOSPC)
	case .Ok:
	}

	new_cluster, new_offset, derr := fs.allocate_sectors(&fsys.vol, 0, 0, 1, .Directory)
	if derr != .None {
		return fuse3.nix(.ENOSPC)
	}

	fsys.free_sectors -= 1
	dir_runs, dr_err := fs.resolve_extents(&fsys.vol, new_cluster, new_offset)
	defer delete(dir_runs)
	if dr_err != .None || len(dir_runs) == 0 {
		return fuse3.nix(.EIO)
	}

	zero: [fs.SECTOR_SIZE]u8
	if fs.sector_write(&fsys.vol, dir_runs[0].sector, zero[:]) != .None {
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
	if fs.write_directory_entry_at(&fsys.vol, dcluster, dsec, didx, &new_entry) != .None {
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
	res, dcluster, dsec, didx, name := prepare_parent_slot(fsys, string(linkpath))
	switch res {
	case .Parent_Not_Found:
		return fuse3.nix(.ENOENT)
	case .Name_Exists:
		return fuse3.nix(.EEXIST)
	case .Dir_Full:
		return fuse3.nix(.ENOSPC)
	case .Ok:
	}

	sectors_needed := (u64(len(target_str)) + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE
	new_c, new_o, aerr := fs.allocate_sectors(&fsys.vol, 0, 0, sectors_needed, .File_Content)
	if aerr != .None {
		return fuse3.nix(.ENOSPC)
	}

	fsys.free_sectors -= sectors_needed
	{
		runs, r_err := fs.resolve_extents(&fsys.vol, new_c, new_o)
		defer delete(runs)
		if r_err != .None || len(runs) == 0 {
			return fuse3.nix(.EIO)
		}

		buf: [fs.SECTOR_SIZE]u8
		copy(buf[:], transmute([]u8)(target_str))
		if fs.sector_write(&fsys.vol, runs[0].sector, buf[:]) != .None {
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
	if fs.write_directory_entry_at(&fsys.vol, dcluster, dsec, didx, &new_entry) != .None {
		return fuse3.nix(.EIO)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("symlink: %s → %s ok", linkpath, target)
	return 0
}

// remove_directory_entry deletes a directory entry: deallocates its content
// chain (if any), clears its xattr chain, drops lock state, and clears the
// entry flags. Shared by unlink, rmdir, and rename-overwrite so the removal
// sequence has a single implementation.
remove_directory_entry :: proc(
	fsys:   ^FS,
	entry:  ^fs.Directory_Entry,
	cluster: fs.Cluster,
	offset: fs.Sector_Offset,
	idx:    int,
) -> fs.FS_Error {
	if entry.stored_cluster != 0 {
		if derr := fs.deallocate_sectors(&fsys.vol, fs.Cluster(entry.stored_cluster), fs.Sector_Offset(entry.sector_index)); derr != .None {
			return derr
		}
	}
	if xerr := fs.xattr_clear(&fsys.vol, entry); xerr != .None {
		return xerr
	}

	locks_remove_identity(fsys, file_identity_from_entry(cluster, offset, idx))
	entry.flags = {}
	if !write_entry_back(fsys, entry, cluster, offset, idx) {
		return .Sector_Write_Error
	}
	reinit_free_sectors(fsys)
	return .None
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

	log.debugf("unlink: %s xattr_cluster=%d", path, entry.xattr_cluster)
	if err := remove_directory_entry(fsys, &entry, cluster, offset, idx); err != .None {
		return fs_error_to_errno(err)
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
	if err := remove_directory_entry(fsys, &entry, cluster, offset, idx); err != .None {
		return fs_error_to_errno(err)
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
	new_parent_entry, _, _, _, np_ok := resolve_path_cached(fsys, new_parent_path, context.temp_allocator)
	if !np_ok {
		log.debugf("rename: %s → parent ENOENT", newpath)
		return fuse3.nix(.ENOENT)
	}

	new_parent_c := fs.Cluster(new_parent_entry.stored_cluster)
	new_parent_o := fs.Sector_Offset(new_parent_entry.sector_index)
	if old_cluster == new_parent_c && old_offset == new_parent_o {
		if dst_entry, _, _, dst_idx, dst_ok := resolve_path_cached(fsys, string(newpath), context.temp_allocator); dst_ok {
			if .Directory not_in dst_entry.flags {
				if err := remove_directory_entry(fsys, &dst_entry, new_parent_c, new_parent_o, dst_idx); err != .None {
					return fs_error_to_errno(err)
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
			if err := remove_directory_entry(fsys, &dst_entry, new_parent_c, new_parent_o, dst_idx); err != .None {
				return fs_error_to_errno(err)
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
	if fs.write_directory_entry_at(&fsys.vol, dst_cluster, dst_sec, dst_slot_idx, &entry) != .None {
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
