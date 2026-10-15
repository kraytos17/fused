// dir.odin — directory-entry helpers for the fused filesystem.
#+build linux
package mounter

import "core:mem"
import "src:fs"

@(private = "file")
// Dir_Scan_Ctx is the shared state for single-sector directory scan
// visitors: the FS, entries-per-sector, and the scratch sector buffer.
// Per-scan result fields (found slots, names, errors) stay on the specific
// context.
Dir_Scan_Ctx :: struct {
	fsys:     ^FS,
	depc:     int,
	scan_buf: [fs.SECTOR_SIZE]u8,
}

@(private = "file")
Find_Slot_Ctx :: struct {
	using scan: Dir_Scan_Ctx,
	dcluster:   fs.Cluster,
	dsec:       fs.Sector_Offset,
	didx:       int,
	found:      bool,
	err:        fs.FS_Error,
}

@(private = "file")
Check_Name_Ctx :: struct {
	using scan: Dir_Scan_Ctx,
	name:       string,
	found:      bool,
}

// write_entry_at writes a Directory_Entry back to its location on disk,
// propagating the underlying error instead of collapsing it to bool.
write_entry_at :: proc(fsys: ^FS, loc: fs.File_Identity, entry: ^fs.Directory_Entry) -> fs.FS_Error {
	return fs.write_entry_at_index(&fsys.vol, loc, entry)
}

// find_free_slot_in_extent scans a directory's extent chain for the first free
// entry slot. Returns Entry_Not_Found when no free slot exists; sector and
// walk errors propagate instead of stopping the walk silently.
find_free_slot_in_extent :: proc(
	fsys: ^FS,
	dir: fs.Chain_Location,
) -> (
	loc: fs.File_Identity,
	err: fs.FS_Error,
) {
	depc := dir_entries_per_buf(fsys.vol.master.features)
	visit := proc(sec: fs.Sector, user: rawptr) -> bool {
		ctx := (^Find_Slot_Ctx)(user)
		if fs.sector_read(&ctx.fsys.vol, sec, ctx.scan_buf[:]) != .None {
			ctx.err = .Sector_Read_Error
			return false
		}
		for i in 0 ..< ctx.depc {
			zero_flags: fs.Dir_Flags
			if get_dir_entry(ctx.scan_buf[:], i, ctx.fsys.vol.master.features).flags ==
			   zero_flags {
				cluster := u64(sec) / ctx.fsys.vol.master.cluster_size
				ctx.dcluster = fs.Cluster(cluster)
				ctx.dsec = fs.Sector_Offset(u64(sec) - cluster * ctx.fsys.vol.master.cluster_size)
				ctx.didx = i
				ctx.found = true
				return false
			}
		}
		return true
	}

	ctx := Find_Slot_Ctx {
		fsys = fsys,
		depc = depc,
	}

	werr := fs.walk_chain_sectors(&fsys.vol, dir, visit, &ctx)
	if ctx.err != .None {
		return {}, ctx.err
	}
	if werr != .None {
		return {}, werr
	}
	if !ctx.found {
		return {}, .Entry_Not_Found
	}
	return fs.File_Identity{ctx.dcluster, ctx.dsec, ctx.didx}, .None
}

// find_or_extend_dir finds a free slot in a directory, extending the chain if
// needed. A full chain extends; any other lookup error propagates (extending
// over a corrupt chain would mask it).
find_or_extend_dir :: proc(
	fsys: ^FS,
	dir: fs.Chain_Location,
) -> (
	loc: fs.File_Identity,
	err: fs.FS_Error,
) {
	slot, ferr := find_free_slot_in_extent(fsys, dir)
	if ferr == .None {
		return slot, .None
	}
	if ferr != .Entry_Not_Found {
		return {}, ferr
	}

	// Cached resolve: counting only needs the slice read-only, and the
	// caller holds the write lock, so the borrowed slice is valid here.
	current_runs := resolve_extents_cached(fsys, dir) or_return

	current_count: u64
	for r in current_runs {
		current_count += u64(r.count)
	}

	_, _, ext_err := fs.allocate_sectors(
		&fsys.vol,
		dir,
		current_count + 1,
		.Directory,
	)
	if ext_err != .None {
		return {}, ext_err
	}

	// The extension changed the chain on disk: drop the cached runs before
	// re-resolving, or the lookup below would hit the pre-extend chain and
	// name a slot in the wrong sector.
	extent_cache_invalidate(fsys, dir.cluster, dir.offset)

	fsys.free_sectors -= 1
	dir_runs := resolve_extents_cached(fsys, dir) or_return

	last_run := dir_runs[len(dir_runs) - 1]
	last_sec := fs.Sector(u64(last_run.sector) + u64(last_run.count) - 1)
	// The added sector may sit on a reused cluster carrying stale bytes; a
	// stale slot with garbage .Exists bits would surface as a phantom entry
	// and steal a real slot (mkdir zeroes its first sector the same way).
	// Zero it: the sector is owned by this directory and holds no live
	// data. Slot 0 is then free by construction.
	zero: [fs.SECTOR_SIZE]u8
	if fs.sector_write(&fsys.vol, last_sec, zero[:]) != .None {
		return {}, .Sector_Write_Error
	}
	dlc := u64(last_sec) / fsys.vol.master.cluster_size
	return fs.File_Identity {
			fs.Cluster(dlc),
			fs.Sector_Offset(u64(last_sec) - dlc * fsys.vol.master.cluster_size),
			0,
		},
		.None
}

// check_name_exists checks whether a name already exists in the directory.
check_name_exists :: proc(
	fsys: ^FS,
	dir: fs.Chain_Location,
	name: string,
) -> bool {
	depc := dir_entries_per_buf(fsys.vol.master.features)
	visit := proc(sec: fs.Sector, user: rawptr) -> bool {
		ctx := (^Check_Name_Ctx)(user)
		if fs.sector_read(&ctx.fsys.vol, sec, ctx.scan_buf[:]) != .None {
			return false
		}
		for i in 0 ..< ctx.depc {
			e := get_dir_entry(ctx.scan_buf[:], i, ctx.fsys.vol.master.features)
			if .Exists in e.flags {
				if fs.entry_short_name(e) == ctx.name {
					ctx.found = true
					return false
				}
			}
		}
		return true
	}

	ctx := Check_Name_Ctx {
		fsys = fsys,
		depc = depc,
		name = name,
	}

	fs.walk_chain_sectors(&fsys.vol, dir, visit, &ctx)
	return ctx.found
}

// write_entry_with_lfn writes a directory entry and sets its timestamps,
// handling LFN allocation for names longer than the inline file_name field.
write_entry_with_lfn :: proc(fsys: ^FS, entry: ^fs.Directory_Entry, name: string) -> fs.FS_Error {
	set_entry_time_to_now(entry)
	return set_entry_name(fsys, entry, name)
}

// set_entry_name sets the name in a Directory_Entry, handling LFN allocation
// and old LFN deallocation. Does NOT modify timestamps. Allocation and
// deallocation failures propagate as FS_Error instead of collapsing to
// ENOSPC at call sites.
set_entry_name :: proc(fsys: ^FS, entry: ^fs.Directory_Entry, name: string) -> fs.FS_Error {
	if .LFN in entry.flags {
		ptr := (^fs.LFN_Pointer)(&entry.file_name[0])
		if ptr.cluster != 0 {
			if derr := fs.deallocate_sectors(
				&fsys.vol,
				fs.Chain_Location{fs.Cluster(ptr.cluster), fs.Sector_Offset(ptr.sector)},
			); derr != .None {
				return derr
			}
			reinit_free_sectors(fsys)
		}
		entry.flags -= {.LFN}
	}
	if len(name) > len(entry.file_name) {
		ptr, perr := fs.lfn_bump_write(&fsys.vol, &fsys.vol.lfn_bump, name)
		if perr != .None { return perr }

		reinit_free_sectors(fsys)
		(^fs.LFN_Pointer)(&entry.file_name[0])^ = ptr
		entry.flags += {.LFN}
	} else {
		copy(entry.file_name[:], name)
		mem.zero_slice(entry.file_name[len(name):])
	}
	return .None
}
