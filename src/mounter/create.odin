// create.odin — FUSE create/mkdir/symlink/unlink/rmdir/rename callbacks for fused.
#+build linux
package mounter

import "base:runtime"
import "core:c"
import "core:log"
import "core:os"
import "core:sys/posix"
import "src:fs"
import "src:fuse3"

// Prepare_Slot_Result distinguishes why prepare_parent_slot failed so
// callers map it to the correct errno.
Prepare_Slot_Result :: enum {
	Ok,
	Parent_Not_Found,
	Name_Exists,
	Dir_Full,
	Io_Error, // parent resolution hit I/O trouble (not a missing parent)
}

// prepare_parent_slot resolves a path's parent directory and finds a free
// entry slot in it, sharing the preamble of create/mkdir/symlink.  The
// returned name is the final path component.
prepare_parent_slot :: proc(
	fsys: ^FS,
	path: string,
) -> (
	res: Prepare_Slot_Result,
	dcluster: fs.Cluster,
	dsec: fs.Sector_Offset,
	didx: int,
	name: string,
) {
	parent, base_name := os.split_path(path)
	parent_entry, _, _, _, perr := resolve_path_cached(fsys, parent, context.temp_allocator)
	if perr == .Entry_Not_Found {
		return .Parent_Not_Found, {}, 0, 0, ""
	}
	if perr != .None {
		return .Io_Error, {}, 0, 0, ""
	}

	dir_cluster := fs.Cluster(parent_entry.stored_cluster)
	dir_offset := fs.Sector_Offset(parent_entry.sector_index)
	if check_name_exists(fsys, fs.Chain_Location{dir_cluster, dir_offset}, base_name) {
		return .Name_Exists, {}, 0, 0, ""
	}

	slot, slot_err := find_or_extend_dir(fsys, fs.Chain_Location{dir_cluster, dir_offset})
	if slot_err == .Entry_Not_Found {
		return .Dir_Full, {}, 0, 0, ""
	}
	if slot_err != .None {
		return .Io_Error, {}, 0, 0, ""
	}
	return .Ok, slot.dir_cluster, slot.dir_offset, slot.entry_index, base_name
}

// fused_create creates a new file (FUSE create callback).
fused_create :: proc "c" (path: cstring, mode: posix.mode_t, fi: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	context.logger = fsys.logger
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
	case .Io_Error:
		log.debugf("create: %s → EIO", path)
		return fuse3.nix(.EIO)
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
	if werr := write_entry_with_lfn(fsys, &new_entry, name); werr != .None {
		return fs_error_to_errno(werr)
	}
	if write_entry_at(fsys, fs.File_Identity{dcluster, dsec, didx}, &new_entry) != .None {
		return fuse3.nix(.EIO)
	}

	fi.fh = fh_pack(fs.File_Identity{dcluster, dsec, didx})
	path_cache_invalidate_all(fsys)
	log.debugf("create: %s → ok", path)
	return 0
}

// fused_mkdir creates a new directory (FUSE mkdir callback).
fused_mkdir :: proc "c" (path: cstring, mode: posix.mode_t) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	context.logger = fsys.logger
	defer end_op(fsys)

	res, dcluster, dsec, didx, name := prepare_parent_slot(fsys, string(path))
	switch res {
	case .Parent_Not_Found:
		return fuse3.nix(.ENOENT)
	case .Name_Exists:
		return fuse3.nix(.EEXIST)
	case .Dir_Full:
		return fuse3.nix(.ENOSPC)
	case .Io_Error:
		return fuse3.nix(.EIO)
	case .Ok:
	}

	new_cluster, new_offset, derr := fs.allocate_sectors(&fsys.vol, {}, 1, .Directory)
	if derr != .None {
		return fuse3.nix(.ENOSPC)
	}

	fsys.free_sectors -= 1
	dir_runs, dr_err := fs.resolve_extents(&fsys.vol, fs.Chain_Location{new_cluster, new_offset})
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
	if len(name) < len(new_entry.file_name) {
		new_entry.file_name[len(name)] = 0
	}
	if write_entry_at(fsys, fs.File_Identity{dcluster, dsec, didx}, &new_entry) != .None {
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
	context.logger = fsys.logger
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
	case .Io_Error:
		return fuse3.nix(.EIO)
	case .Ok:
	}

	sectors_needed := (u64(len(target_str)) + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE
	new_c, new_o, aerr := fs.allocate_sectors(&fsys.vol, {}, sectors_needed, .File_Content)
	if aerr != .None {
		return fuse3.nix(.ENOSPC)
	}

	fsys.free_sectors -= sectors_needed
	{
		runs, r_err := fs.resolve_extents(&fsys.vol, fs.Chain_Location{new_c, new_o})
		defer delete(runs)
		if r_err != .None || len(runs) == 0 {
			return fuse3.nix(.EIO)
		}

		buf: [fs.SECTOR_SIZE]u8
		copy(buf[:], transmute([]u8)(target_str)) // TRANSMUTE: string->bytes alias, no copy
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
	if werr := write_entry_with_lfn(fsys, &new_entry, name); werr != .None {
		return fs_error_to_errno(werr)
	}
	if write_entry_at(fsys, fs.File_Identity{dcluster, dsec, didx}, &new_entry) != .None {
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
	fsys: ^FS,
	entry: ^fs.Directory_Entry,
	loc: fs.File_Identity,
) -> fs.FS_Error {
	if entry.stored_cluster != 0 {
		if derr := fs.deallocate_sectors(&fsys.vol, fs.data_chain_of(entry^)); derr != .None {
			return derr
		}
	}
	if xerr := fs.xattr_clear(&fsys.vol, entry); xerr != .None {
		return xerr
	}

	locks_remove_identity(fsys, loc)
	entry.flags = {}
	if werr := write_entry_at(fsys, loc, entry); werr != .None {
		return werr
	}

	reinit_free_sectors(fsys)
	return .None
}

// fused_unlink removes a file (FUSE unlink callback).
fused_unlink :: proc "c" (path: cstring) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	context.logger = fsys.logger
	defer end_op(fsys)

	entry, cluster, offset, idx, rerr := resolve_path_cached(
		fsys,
		string(path),
		context.temp_allocator,
	)
	if rerr != .None {
		log.debugf("unlink: %s → %v", path, rerr)
		return fs_error_to_errno(rerr)
	}
	if .Directory in entry.flags {
		log.debugf("unlink: %s → EISDIR", path)
		return fuse3.nix(.EISDIR)
	}

	log.debugf("unlink: %s xattr_cluster=%d", path, entry.xattr_cluster)
	if err := remove_directory_entry(fsys, &entry, fs.File_Identity{cluster, offset, idx});
	   err != .None {
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
	context.logger = fsys.logger
	defer end_op(fsys)

	entry, cluster, offset, idx, rerr := resolve_path_cached(
		fsys,
		string(path),
		context.temp_allocator,
	)
	if rerr != .None {
		return fs_error_to_errno(rerr)
	}
	if .Directory not_in entry.flags {
		log.debugf("rmdir: %s → ENOTDIR", path)
		return fuse3.nix(.ENOTDIR)
	}

	dirs, dir_err := fs.read_directory_entries(
		&fsys.vol,
		fs.Cluster(entry.stored_cluster),
		fs.Sector_Offset(entry.sector_index),
	)

	defer delete(dirs)
	if dir_err != .None {  }
	for &w in dirs {
		if .Exists in w.entry.flags {
			log.debugf("rmdir: %s → ENOTEMPTY", path)
			return fuse3.nix(.ENOTEMPTY)
		}
	}
	if err := remove_directory_entry(fsys, &entry, fs.File_Identity{cluster, offset, idx});
	   err != .None {
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
	context.logger = fsys.logger
	defer end_op(fsys)

	// Parse the ABI word once; downstream switches on set membership.
	rflags := transmute(fuse3.Rename_Flags)(flags) // TRANSMUTE: c.uint ABI word bit-view as flag set
	if .No_Replace in rflags {
		log.debugf("rename: RENAME_NOREPLACE not supported")
		return fuse3.nix(.ENOSYS)
	}
	if .Exchange in rflags {
		log.debugf("rename: RENAME_EXCHANGE not supported")
		return fuse3.nix(.ENOSYS)
	}

	entry, old_cluster, old_offset, old_idx, rerr := resolve_path_cached(
		fsys,
		string(oldpath),
		context.temp_allocator,
	)
	if rerr != .None {
		log.debugf("rename: %s → %v", oldpath, rerr)
		return fs_error_to_errno(rerr)
	}

	new_parent_path, new_name := os.split_path(string(newpath))
	new_parent_entry, _, _, _, np_err := resolve_path_cached(
		fsys,
		new_parent_path,
		context.temp_allocator,
	)
	if np_err != .None {
		log.debugf("rename: %s → parent %v", newpath, np_err)
		return fs_error_to_errno(np_err)
	}

	new_parent_c := fs.Cluster(new_parent_entry.stored_cluster)
	new_parent_o := fs.Sector_Offset(new_parent_entry.sector_index)
	if old_cluster == new_parent_c && old_offset == new_parent_o {
		dst_entry, _, _, dst_idx, dst_err := resolve_path_cached(
			fsys,
			string(newpath),
			context.temp_allocator,
		)
		if dst_err != .None && dst_err != .Entry_Not_Found {
			return fs_error_to_errno(dst_err)
		}
		if dst_err == .None {
			if .Directory not_in dst_entry.flags {
				if err := remove_directory_entry(
					fsys,
					&dst_entry,
					fs.File_Identity{new_parent_c, new_parent_o, dst_idx},
				); err != .None {
					return fs_error_to_errno(err)
				}
			} else {
				log.debugf("rename: %s → %s → EISDIR (destination is dir)", oldpath, newpath)
				return fuse3.nix(.EISDIR)
			}
		}
		if nerr := set_entry_name(fsys, &entry, new_name); nerr != .None {
			return fs_error_to_errno(nerr)
		}
		if werr := write_entry_at(fsys, fs.File_Identity{old_cluster, old_offset, old_idx}, &entry);
		   werr != .None {
			return fs_error_to_errno(werr)
		}

		path_cache_invalidate_all(fsys)
		log.debugf("rename: %s → %s ok", oldpath, newpath)
		return 0
	}
	if .Directory in entry.flags {
		check_path := new_parent_path
		for check_path != "/" {
			check_entry, _, _, _, check_err := resolve_path_cached(
				fsys,
				check_path,
				context.temp_allocator,
			)
			if check_err == .Entry_Not_Found {
				break
			}
			if check_err != .None {
				return fs_error_to_errno(check_err)
			}
			if fs.Cluster(check_entry.stored_cluster) == old_cluster &&
			   fs.Sector_Offset(check_entry.sector_index) == old_offset {
				log.debugf("rename: %s → %s → EINVAL (circular)", oldpath, newpath)
				return fuse3.nix(.EINVAL)
			}

			parent_of_check, _ := os.split_path(check_path)
			check_path = parent_of_check
		}
	}

	dst_idx := -1
	dst_entry, _, _, dst_idx_resolved, dst_err := resolve_path_cached(
		fsys,
		string(newpath),
		context.temp_allocator,
	)
	if dst_err != .None && dst_err != .Entry_Not_Found {
		return fs_error_to_errno(dst_err)
	}
	if dst_err == .None {
		dst_idx = dst_idx_resolved
		if .Directory not_in dst_entry.flags {
			if err := remove_directory_entry(
				fsys,
				&dst_entry,
				fs.File_Identity{new_parent_c, new_parent_o, dst_idx},
			); err != .None {
				return fs_error_to_errno(err)
			}
		} else {
			log.debugf("rename: %s → %s → EISDIR (destination is dir)", oldpath, newpath)
			return fuse3.nix(.EISDIR)
		}
	}

	dst_slot, slot_err := find_or_extend_dir(fsys, fs.Chain_Location{new_parent_c, new_parent_o})
	if slot_err == .Entry_Not_Found {
		return fuse3.nix(.ENOSPC)
	}
	if slot_err != .None {
		return fs_error_to_errno(slot_err)
	}

	dst_cluster, dst_sec, dst_slot_idx :=
		dst_slot.dir_cluster, dst_slot.dir_offset, dst_slot.entry_index
	if nerr := set_entry_name(fsys, &entry, new_name); nerr != .None {
		return fs_error_to_errno(nerr)
	}
	if write_entry_at(fsys, fs.File_Identity{dst_cluster, dst_sec, dst_slot_idx}, &entry) != .None {
		return fuse3.nix(.EIO)
	}

	entry.flags = {}
	if werr := write_entry_at(fsys, fs.File_Identity{old_cluster, old_offset, old_idx}, &entry);
	   werr != .None {
		return fs_error_to_errno(werr)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("rename: %s → %s ok (cross-directory)", oldpath, newpath)
	return 0
}
