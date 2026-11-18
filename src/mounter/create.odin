// create.odin — FUSE create/mkdir/symlink/unlink/rmdir/rename callbacks for fused.
#+build linux
package mounter

import "base:runtime"
import "core:c"
import "core:log"
import "core:os"
import "core:strings"
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
	Not_A_Directory, // parent exists but is not a directory
	Io_Error, // parent resolution hit I/O trouble (not a missing parent)
	Name_Too_Long, // final component exceeds NAME_MAX (255)
	Invalid_Name, // empty, ".", NUL, or "/" in final component
}

// NAME_MAX is the Linux VFS filename limit; the statvfs-facing claim.
NAME_MAX :: 255

// prepare_parent_slot resolves a path's parent directory and finds a free
// entry slot in it, sharing the preamble of create/mkdir/symlink.  The
// returned name is the final path component. It validates the final
// component: empty, "."/"..", embedded NUL or "/" are Invalid_Name
// (callers map to EINVAL, except "."/".." which already exist →
// Name_Exists/EEXIST); longer than NAME_MAX (255) is Name_Too_Long.
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
	// "." and ".." can never be created: the kernel's "." / ".." already
	// exist as virtual entries in every directory listing.
	if base_name == "." || base_name == ".." {
		return .Name_Exists, {}, 0, 0, ""
	}
	if len(base_name) == 0 {
		return .Invalid_Name, {}, 0, 0, ""
	}
	if len(base_name) > NAME_MAX {
		return .Name_Too_Long, {}, 0, 0, ""
	}
	if strings.index_byte(base_name, 0) >= 0 {
		return .Invalid_Name, {}, 0, 0, ""
	}
	if strings.index_byte(base_name, '/') >= 0 {
		return .Invalid_Name, {}, 0, 0, ""
	}

	parent_entry, _, _, _, perr := resolve_path_cached(fsys, parent, context.temp_allocator)
	if perr == .Entry_Not_Found {
		return .Parent_Not_Found, {}, 0, 0, ""
	}
	if perr != .None {
		return .Io_Error, {}, 0, 0, ""
	}
	if .Directory not_in parent_entry.flags {
		return .Not_A_Directory, {}, 0, 0, ""
	}

	dir_cluster := fs.Cluster(parent_entry.stored_cluster)
	dir_offset := fs.Sector_Offset(parent_entry.sector_index)
	name_found, name_err := check_name_exists(
		fsys,
		fs.Chain_Location{dir_cluster, dir_offset},
		base_name,
	)
	if name_err != .None {
		return .Io_Error, {}, 0, 0, ""
	}
	if name_found {
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
	case .Not_A_Directory:
		log.debugf("create: %s → parent ENOTDIR", path)
		return fuse3.nix(.ENOTDIR)
	case .Name_Too_Long:
		log.debugf("create: %s → ENAMETOOLONG", path)
		return fuse3.nix(.ENAMETOOLONG)
	case .Invalid_Name:
		log.debugf("create: %s → EINVAL (bad name)", path)
		return fuse3.nix(.EINVAL)
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
	new_reclaim, werr := write_entry_with_lfn(fsys, &new_entry, name)
	if werr != .None {
		return fs_error_to_errno(werr)
	}
	if write_entry_at(fsys, fs.File_Identity{dcluster, dsec, didx}, &new_entry) != .None {
		free_entry_lfn(fsys, &new_entry)
		return fuse3.nix(.EIO)
	}
	if new_reclaim.cluster != 0 {
		if derr := fs.deallocate_sectors(
			&fsys.vol,
			fs.Chain_Location {
				fs.Cluster(new_reclaim.cluster),
				fs.Sector_Offset(new_reclaim.sector),
			},
		); derr != .None {
			return fs_error_to_errno(derr)
		}
		reinit_free_sectors(fsys)
	}

	fi.fh = open_handle_insert(fsys, fs.File_Identity{dcluster, dsec, didx})
	path_cache_invalidate_all(fsys)
	fsys.used_entries += 1
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
	case .Not_A_Directory:
		return fuse3.nix(.ENOTDIR)
	case .Name_Too_Long:
		return fuse3.nix(.ENAMETOOLONG)
	case .Invalid_Name:
		return fuse3.nix(.EINVAL)
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
		if rerr := fs.deallocate_sectors(&fsys.vol, fs.Chain_Location{new_cluster, new_offset});
		   rerr == .None {
			reinit_free_sectors(fsys)
		}
		return fuse3.nix(.EIO)
	}

	zero: [fs.SECTOR_SIZE]u8
	if fs.sector_write(&fsys.vol, dir_runs[0].sector, zero[:]) != .None {
		if rerr := fs.deallocate_sectors(&fsys.vol, fs.Chain_Location{new_cluster, new_offset});
		   rerr == .None {
			reinit_free_sectors(fsys)
		}
		return fuse3.nix(.EIO)
	}

	new_entry: fs.Directory_Entry
	new_entry.flags = fs.Dir_Flags{.Allocated, .Directory, .Exists}
	new_entry.sector_index = u16(new_offset)
	new_entry.stored_cluster = u64(new_cluster)
	ctx := fuse3.fuse_get_context()
	new_entry.uid = u32(ctx.uid)
	new_entry.gid = u32(ctx.gid)

	// Long names go through the LFN path like create/symlink:
	// write_entry_with_lfn sets timestamps and allocates an LFN sector
	// when the name exceeds the 16-byte inline field.
	new_reclaim, werr := write_entry_with_lfn(fsys, &new_entry, name)
	if werr != .None {
		if rerr := fs.deallocate_sectors(&fsys.vol, fs.Chain_Location{new_cluster, new_offset});
		   rerr == .None {
			reinit_free_sectors(fsys)
		}
		return fs_error_to_errno(werr)
	}
	if write_entry_at(fsys, fs.File_Identity{dcluster, dsec, didx}, &new_entry) != .None {
		free_entry_lfn(fsys, &new_entry)
		if rerr := fs.deallocate_sectors(&fsys.vol, fs.Chain_Location{new_cluster, new_offset});
		   rerr == .None {
			reinit_free_sectors(fsys)
		}
		return fuse3.nix(.EIO)
	}
	if new_reclaim.cluster != 0 {
		if reclaim_err := fs.deallocate_sectors(
			&fsys.vol,
			fs.Chain_Location {
				fs.Cluster(new_reclaim.cluster),
				fs.Sector_Offset(new_reclaim.sector),
			},
		); reclaim_err != .None {
			return fs_error_to_errno(reclaim_err)
		}
		reinit_free_sectors(fsys)
	}

	path_cache_invalidate_all(fsys)
	fsys.used_entries += 1
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
	case .Not_A_Directory:
		return fuse3.nix(.ENOTDIR)
	case .Name_Too_Long:
		return fuse3.nix(.ENAMETOOLONG)
	case .Invalid_Name:
		return fuse3.nix(.EINVAL)
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
			if derr := fs.deallocate_sectors(&fsys.vol, fs.Chain_Location{new_c, new_o});
			   derr == .None {
				fsys.free_sectors += sectors_needed
			}
			return fuse3.nix(.EIO)
		}

		// Write the whole target across every run (a multi-sector target
		// does not fit the old single-sector buffer).
		tbytes := transmute([]u8)target_str
		mem_src := Mem_Source {
			fsys      = fsys,
			buf       = raw_data(tbytes),
			size      = u64(len(tbytes)),
			remaining = u64(len(tbytes)),
		}
		bytes_src := Buf_Source {
			user      = &mem_src,
			copy      = _mem_copy,
			bulk      = _mem_bulk,
			remaining = _mem_remaining,
		}
		if written := write_range_to_runs(fsys, runs[:], 0, &bytes_src);
		   written != u64(len(tbytes)) {
			if derr := fs.deallocate_sectors(&fsys.vol, fs.Chain_Location{new_c, new_o});
			   derr == .None {
				fsys.free_sectors += sectors_needed
			}
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
	new_reclaim, werr := write_entry_with_lfn(fsys, &new_entry, name)
	if werr != .None {
		if derr := fs.deallocate_sectors(&fsys.vol, fs.Chain_Location{new_c, new_o});
		   derr == .None {
			fsys.free_sectors += sectors_needed
		}
		return fs_error_to_errno(werr)
	}
	if write_entry_at(fsys, fs.File_Identity{dcluster, dsec, didx}, &new_entry) != .None {
		free_entry_lfn(fsys, &new_entry)
		if derr := fs.deallocate_sectors(&fsys.vol, fs.Chain_Location{new_c, new_o});
		   derr == .None {
			fsys.free_sectors += sectors_needed
		}
		return fuse3.nix(.EIO)
	}
	if new_reclaim.cluster != 0 {
		if derr := fs.deallocate_sectors(
			&fsys.vol,
			fs.Chain_Location {
				fs.Cluster(new_reclaim.cluster),
				fs.Sector_Offset(new_reclaim.sector),
			},
		); derr != .None {
			return fs_error_to_errno(derr)
		}
		reinit_free_sectors(fsys)
	}

	path_cache_invalidate_all(fsys)
	fsys.used_entries += 1
	log.debugf("symlink: %s → %s ok", linkpath, target)
	return 0
}

// remove_directory_entry deletes a directory entry: clears its flags,
// persists the cleared entry, then frees its content, LFN, and xattr
// chains. Shared by unlink, rmdir, and rename-overwrite so the removal
// sequence has a single implementation.
// _release_entry_resources frees what a destroyed directory entry owned:
// its locks, open handles, inode count, data chain, LFN storage, and
// xattr chain. The caller has already cleared or overwritten the slot —
// destruction-last orderings (rename overwrite) separate the slot write
// from the resource release so no crash window leaves a live entry
// pointing at freed chains.
@(private = "file")
_release_entry_resources :: proc(
	fsys: ^FS,
	dead: ^fs.Directory_Entry,
	loc: fs.File_Identity,
) -> fs.FS_Error {
	reclaim := fs.xattr_clear(dead)
	locks_remove_identity(fsys, loc)
	open_handle_sweep(fsys, loc)
	if fsys.used_entries > 0 {
		fsys.used_entries -= 1
	}
	if dead.stored_cluster != 0 {
		if derr := fs.deallocate_sectors(&fsys.vol, fs.data_chain_of(dead^)); derr != .None {
			return derr
		}
	}
	if ferr := free_entry_lfn(fsys, dead); ferr != .None {
		return ferr
	}
	if reclaim != 0 {
		if xerr := fs.xattr_free_chain(&fsys.vol, reclaim); xerr != .None {
			return xerr
		}
	}

	reinit_free_sectors(fsys)
	return .None
}

// remove_directory_entry clears a directory-entry slot and releases
// everything it owned.
remove_directory_entry :: proc(
	fsys: ^FS,
	entry: ^fs.Directory_Entry,
	loc: fs.File_Identity,
) -> fs.FS_Error {
	saved := entry^
	entry.flags = {}
	_ = fs.xattr_clear(entry)
	if werr := write_entry_at(fsys, loc, entry); werr != .None {
		entry^ = saved
		return werr
	}
	return _release_entry_resources(fsys, &saved, loc)
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

	// The root has no parent entry to remove (resolve synthesizes it
	// from the live master record, so removal would deallocate the real
	// root chain). Linux reports EBUSY.
	if string(path) == "/" {
		log.debugf("rmdir: %s → EBUSY (root)", path)
		return fuse3.nix(.EBUSY)
	}

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
	if dir_err != .None {
		log.debugf("rmdir: %s → %v", path, dir_err)
		return fs_error_to_errno(dir_err)
	}
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

// rename_publish persists a renamed entry, then reclaims the previous
// long-name chain. On persist failure it restores the pre-rename copy
// (the disk was never touched, and nothing was freed); on success the
// old chain is freed. Used by same-dir renames and cross-directory
// moves for the new slot; the old slot write in cross-directory moves
// stays inline (its failure mode is unchanged).
rename_publish :: proc(
	fsys: ^FS,
	entry: ^fs.Directory_Entry,
	saved: fs.Directory_Entry,
	loc: fs.File_Identity,
	reclaim: fs.LFN_Pointer,
) -> c.int {
	if werr := write_entry_at(fsys, loc, entry); werr != .None {
		new_ptr := fs.LFN_Pointer{}
		if .LFN in entry.flags {
			new_ptr = (^fs.LFN_Pointer)(&entry.file_name[0])^
		}

		entry^ = saved
		if new_ptr.cluster != 0 {
			_ = fs.deallocate_sectors(
				&fsys.vol,
				fs.Chain_Location{fs.Cluster(new_ptr.cluster), fs.Sector_Offset(new_ptr.sector)},
			)
			reinit_free_sectors(fsys)
		}
		return fs_error_to_errno(werr)
	}
	if reclaim.cluster != 0 {
		if derr := fs.deallocate_sectors(
			&fsys.vol,
			fs.Chain_Location{fs.Cluster(reclaim.cluster), fs.Sector_Offset(reclaim.sector)},
		); derr != .None {
			return fs_error_to_errno(derr)
		}
		reinit_free_sectors(fsys)
	}
	return 0
}

// fused_exchange_locked implements RENAME_EXCHANGE: atomically
// swap the CONTENTS of two existing directory entries; each path keeps
// its name, each file keeps its chains/attrs. POSIX has no type
// restriction — file↔file, file↔dir, dir↔dir all exchange.
//
// LOCKING: caller holds fsys.mu exclusively (fused_rename's begin_op).
// This helper must NOT begin_op — recursive exclusive acquisition
// self-deadlocks (found by test_rename_exchange hanging at the first
// exchange).
//
// Guards: both must exist (ENOENT); / → EBUSY (same as rename/rmdir);
// same slot → 0 (no-op); exchanging a directory with its own ancestor or
// descendant would strand both subtrees (the child's slot lives inside
// the parent's chain, which the swap orphans), so EINVAL — matching the
// kernel's circular-rename posture.
//
// Crash window: two slot writes are not one transaction. Nothing
// is deallocated here, so the persist-order discipline (s7) is trivially
// satisfied: worst case is one slot exchanged and the other not — a
// structurally sound half-swap whose not-yet-moved content shows up as
// repairable orphans. Pinned by the crash sweep; full atomicity is
// E-03 work (KNOWN_LIMITATIONS, exchange entry).
fused_exchange_locked :: proc(fsys: ^FS, oldpath, newpath: string) -> c.int {
	if oldpath == "/" || newpath == "/" {
		log.debugf("exchange: %s <-> %s → EBUSY (root)", oldpath, newpath)
		return fuse3.nix(.EBUSY)
	}

	a, a_cluster, a_offset, a_idx, a_err := resolve_path_cached(
		fsys,
		oldpath,
		context.temp_allocator,
	)
	if a_err != .None {
		log.debugf("exchange: %s → %v", oldpath, a_err)
		return fs_error_to_errno(a_err)
	}

	b, b_cluster, b_offset, b_idx, b_err := resolve_path_cached(
		fsys,
		newpath,
		context.temp_allocator,
	)
	if b_err != .None {
		log.debugf("exchange: %s → %v", newpath, b_err)
		return fs_error_to_errno(b_err)
	}

	a_id := fs.File_Identity{a_cluster, a_offset, a_idx}
	b_id := fs.File_Identity{b_cluster, b_offset, b_idx}
	if a_id == b_id {
		log.debugf("exchange: %s <-> %s ok (same slot)", oldpath, newpath)
		return 0
	}

	// Cyclic guards, both directions (dir ancestor/descendant swaps
	// strand both subtrees). Files have no descendants, so each walk is
	// conditional on that side being a directory.
	a_is_dir := .Directory in a.flags
	b_is_dir := .Directory in b.flags
	if a_is_dir {
		// Is newpath inside a's subtree? (Same walk as plain rename.)
		check_path := newpath
		for check_path != "/" {
			parent, _ := os.split_path(check_path)
			check_path = parent
			if check_path == "/" { break }
			_, check_c, check_o, check_idx, check_err := resolve_path_cached(
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
			if check_c == a_cluster && check_o == a_offset && check_idx == a_idx {
				log.debugf("exchange: %s <-> %s → EINVAL (newpath inside src)", oldpath, newpath)
				return fuse3.nix(.EINVAL)
			}
		}
	}
	if b_is_dir {
		// Is oldpath inside b's subtree? Walk oldpath's strict ancestors
		// against b's slot.
		check_path := oldpath
		for check_path != "/" {
			parent, _ := os.split_path(check_path)
			check_path = parent
			if check_path == "/" { break }
			_, check_c, check_o, check_idx, check_err := resolve_path_cached(
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
			if check_c == b_cluster && check_o == b_offset && check_idx == b_idx {
				log.debugf("exchange: %s <-> %s → EINVAL (oldpath inside dst)", oldpath, newpath)
				return fuse3.nix(.EINVAL)
			}
		}
	}

	// The swap: each slot keeps its NAME (file_name field, and the .LFN
	// flag that describes it); everything else — flags, chains, attrs,
	// sizes, ownership, times, xattr pointer — exchanges. Build both
	// post-swap entries first, then persist slot A and slot B.
	swapped_a := a
	swapped_b := b
	_swapped_keep_name(&swapped_a, b, a)
	_swapped_keep_name(&swapped_b, a, b)
	if werr := write_entry_at(fsys, a_id, &swapped_a); werr != .None {
		return fs_error_to_errno(werr)
	}
	if werr := write_entry_at(fsys, b_id, &swapped_b); werr != .None {
		return fs_error_to_errno(werr)
	}

	// fds and advisory locks follow the content (it changed slots in
	// both directions — a repoint is order-dependent, this is a swap).
	open_handle_swap(fsys, a_id, b_id)
	path_cache_invalidate_all(fsys)
	log.debugf("exchange: %s <-> %s ok", oldpath, newpath)
	return 0
}

// _swapped_keep_name writes into `dst` the full content of `src` EXCEPT
// the name-bearing state (file_name[16] holds the inline name or the LFN
// pointer, and the .LFN flag describes it): after RENAME_EXCHANGE each
// path still names what it named, the content behind it changed.
@(private = "file")
_swapped_keep_name :: proc(dst: ^fs.Directory_Entry, src, keep: fs.Directory_Entry) {
	dst^ = src
	dst.file_name = keep.file_name
	if .LFN in keep.flags {
		dst.flags += {.LFN}
	} else {
		dst.flags -= {.LFN}
	}
}

// fused_rename renames or moves a file or directory (FUSE rename callback).
fused_rename :: proc "c" (oldpath: cstring, newpath: cstring, flags: c.uint) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	context.logger = fsys.logger
	defer end_op(fsys)

	// Parse the ABI word once; downstream switches on set membership.
	rflags := transmute(fuse3.Rename_Flags)(flags)
	if .Exchange in rflags {
		return fused_exchange_locked(fsys, string(oldpath), string(newpath))
	}
	// Renaming / or to / is EBUSY (same convention as rmdir("/")
	if string(oldpath) == "/" || string(newpath) == "/" {
		log.debugf("rename: %s → %s → EBUSY (root)", oldpath, newpath)
		return fuse3.nix(.EBUSY)
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
	// The dst name follows the same rules prepare_parent_slot enforces
	// for create/mkdir/symlink; rename gets them explicitly.
	if new_name == "" || new_name == "." || new_name == ".." {
		log.debugf("rename: %s → EINVAL (bad dst name)", newpath)
		return fuse3.nix(.EINVAL)
	}
	if len(new_name) > NAME_MAX {
		log.debugf("rename: %s → ENAMETOOLONG", newpath)
		return fuse3.nix(.ENAMETOOLONG)
	}

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
	same_dir := old_cluster == new_parent_c && old_offset == new_parent_o
	// Same-name no-op: POSIX lets `rename a a` succeed without touching
	// anything. Without this, the dst-overwrite path would clear the
	// entry, free its chains, then write the stale copy back — pointing
	// at freed sectors.
	if same_dir {
		if .LFN in entry.flags {
			if cur, ok := fs.resolve_lfn(&fsys.vol, &entry, context.temp_allocator);
			   ok && cur == new_name {
				log.debugf("rename: %s → %s ok (same-name no-op)", oldpath, newpath)
				return 0
			}
		} else if fs.entry_short_name(&entry) == new_name {
			log.debugf("rename: %s → %s ok (same-name no-op)", oldpath, newpath)
			return 0
		}
	}

	// Resolve dst ONCE for both dispatches, then run the matrix BEFORE
	// any mutation. Dir-over-dir needs the dst emptiness scan; every
	// other combination is flags-only.
	dst_exists := false
	dst_entry: fs.Directory_Entry
	dst_idx := -1
	dst_e, _, _, dst_idx_resolved, dst_err := resolve_path_cached(
		fsys,
		string(newpath),
		context.temp_allocator,
	)
	if dst_err == .None {
		dst_exists = true
		dst_entry = dst_e
		dst_idx = dst_idx_resolved
	} else if dst_err != .Entry_Not_Found {
		return fs_error_to_errno(dst_err)
	}

	dst_is_empty_dir := true
	if dst_exists && .Directory in dst_entry.flags && .Directory in entry.flags {
		empty, eerr := dir_is_empty(fsys, dst_entry)
		if eerr != .None {
			log.debugf("rename: %s → %v (dst scan)", newpath, eerr)
			return fs_error_to_errno(eerr)
		}
		dst_is_empty_dir = empty
	}

	dst_flags := dst_entry.flags if dst_exists else fs.Dir_Flags{}
	verdict := rename_validate(entry.flags, dst_exists, dst_flags, dst_is_empty_dir, rflags)
	if verdict != .Ok {
		log.debugf("rename: %s → %s → %v (matrix)", oldpath, newpath, verdict)
		return rename_verdict_rc(verdict)
	}
	if same_dir {
		if dst_exists {
			// Overwrite, destruction-last: the moved entry takes over
			// the dst slot IN PLACE. Until the old source slot clears,
			// both names resolve to the same chain (legal transient);
			// the dst's chains release after the overwrite (orphans in
			// the window, never a dangling reference); the source slot
			// clears last. A crash in any window loses nothing — the
			// old target's data surfaces as repairable orphans at
			// worst, never as a vanished name.
			dst_id := fs.File_Identity{new_parent_c, new_parent_o, dst_idx}
			src_id := fs.File_Identity{old_cluster, old_offset, old_idx}
			dead := dst_entry
			saved := entry
			reclaim, nerr := set_entry_name(fsys, &entry, new_name)
			if nerr != .None {
				return fs_error_to_errno(nerr)
			}
			if rc := rename_publish(fsys, &entry, saved, dst_id, reclaim); rc != 0 {
				return rc
			}
			if err := _release_entry_resources(fsys, &dead, dst_id); err != .None {
				return fs_error_to_errno(err)
			}

			entry.flags = {}
			if werr := write_entry_at(fsys, src_id, &entry); werr != .None {
				return fs_error_to_errno(werr)
			}
			open_handle_repoint(fsys, src_id, dst_id)
		} else {
			saved := entry
			reclaim, nerr := set_entry_name(fsys, &entry, new_name)
			if nerr != .None {
				return fs_error_to_errno(nerr)
			}
			if rc := rename_publish(
				fsys,
				&entry,
				saved,
				fs.File_Identity{old_cluster, old_offset, old_idx},
				reclaim,
			); rc != 0 {
				return rc
			}
		}

		path_cache_invalidate_all(fsys)
		log.debugf("rename: %s → %s ok", oldpath, newpath)
		return 0
	}
	if .Directory in entry.flags {
		check_path := new_parent_path
		for check_path != "/" {
			// Compare slot identities: the walk fires if and only if
			// it reaches the source directory itself. (Comparing
			// data-chain heads here is wrong in both directions: it
			// rejects legal moves under the source's parent and
			// misses circular moves rooted at "/".)
			_, check_c, check_o, check_idx, check_err := resolve_path_cached(
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
			if check_c == old_cluster && check_o == old_offset && check_idx == old_idx {
				log.debugf("rename: %s → %s → EINVAL (circular)", oldpath, newpath)
				return fuse3.nix(.EINVAL)
			}

			parent_of_check, _ := os.split_path(check_path)
			check_path = parent_of_check
		}
	}
	// Cross-directory move. For an overwrite the moved entry takes over
	// the dst slot IN PLACE (destruction-last, same reasoning as the
	// same-dir note: names stay resolvable in every window, the dst's
	// chains release after the overwrite as repairable orphans, and the
	// source slot clears in the shared tail below). Without an
	// overwrite a fresh slot is allocated first.
	dst_id: fs.File_Identity
	if dst_exists {
		dst_id = fs.File_Identity{new_parent_c, new_parent_o, dst_idx}
		dead := dst_entry
		saved := entry
		reclaim, nerr := set_entry_name(fsys, &entry, new_name)
		if nerr != .None {
			return fs_error_to_errno(nerr)
		}
		if rc := rename_publish(fsys, &entry, saved, dst_id, reclaim); rc != 0 {
			return rc
		}
		if err := _release_entry_resources(fsys, &dead, dst_id); err != .None {
			return fs_error_to_errno(err)
		}
	} else {
		dst_slot, slot_err := find_or_extend_dir(
			fsys,
			fs.Chain_Location{new_parent_c, new_parent_o},
		)
		if slot_err == .Entry_Not_Found {
			return fuse3.nix(.ENOSPC)
		}
		if slot_err != .None {
			return fs_error_to_errno(slot_err)
		}

		dst_id = fs.File_Identity{dst_slot.dir_cluster, dst_slot.dir_offset, dst_slot.entry_index}
		saved := entry
		reclaim, nerr := set_entry_name(fsys, &entry, new_name)
		if nerr != .None {
			return fs_error_to_errno(nerr)
		}
		if rc := rename_publish(fsys, &entry, saved, dst_id, reclaim); rc != 0 {
			return rc
		}
	}

	entry.flags = {}
	if werr := write_entry_at(fsys, fs.File_Identity{old_cluster, old_offset, old_idx}, &entry);
	   werr != .None {
		return fs_error_to_errno(werr)
	}

	open_handle_repoint(fsys, fs.File_Identity{old_cluster, old_offset, old_idx}, dst_id)
	path_cache_invalidate_all(fsys)
	log.debugf("rename: %s → %s ok (cross-directory)", oldpath, newpath)
	return 0
}
