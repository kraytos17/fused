// dir.odin — directory-entry helpers for the fused filesystem.
#+build linux
package mounter

import "core:mem"
import "src:fs"

// write_entry_back writes a Directory_Entry back to its location on disk
// (identified by cluster, offset, and entry index).
write_entry_back :: proc(fsys: ^FS, entry: ^fs.Directory_Entry, cluster: fs.Cluster, offset: fs.Sector_Offset, index: int) -> bool {
	depc := dir_entries_per_buf(fsys.vol.master.features)
	runs, ext_err := fs.resolve_extents(&fsys.vol,cluster, offset)
	defer delete(runs)
	if ext_err != .None {
		return false
	}

	remaining := index
	for run in runs {
		n := int(run.count)
		for si in 0 ..< n {
			if remaining < depc {
				dsec := fs.Sector_Offset(u64(run.sector) + u64(si) - u64(cluster) * fsys.vol.master.cluster_size)
				return fs.write_directory_entry_at(&fsys.vol,cluster, dsec, remaining, entry)
			}
			remaining -= depc
		}
	}
	return false
}

// find_free_slot_in_extent scans a directory's extent chain for the first free
// entry slot. Returns ok=false when no free slot exists.
find_free_slot_in_extent :: proc(fsys: ^FS, dir_cluster: fs.Cluster, dir_offset: fs.Sector_Offset) -> (dcluster: fs.Cluster, dsec: fs.Sector_Offset, didx: int, ok: bool) {
	depc := dir_entries_per_buf(fsys.vol.master.features)
	dir_runs, dir_err := fs.resolve_extents(&fsys.vol, dir_cluster, dir_offset)
	defer delete(dir_runs)
	if dir_err != .None {
		return {}, 0, 0, false
	}

	scan_buf: [fs.SECTOR_SIZE]u8
	for run in dir_runs {
		n := int(run.count)
		for si in 0 ..< n {
			sec := fs.Sector(u64(run.sector) + u64(si))
			if !fs.sector_read(&fsys.vol, sec, scan_buf[:]) {
				return {}, 0, 0, false
			}
			for i in 0 ..< depc {
				zero_flags: fs.Dir_Flags
				if get_dir_entry(scan_buf[:], i, fsys.vol.master.features).flags == zero_flags {
					cluster := u64(sec) / fsys.vol.master.cluster_size
					dsec = fs.Sector_Offset(u64(sec) - cluster * fsys.vol.master.cluster_size)
					return fs.Cluster(cluster), dsec, i, true
				}
			}
		}
	}
	return {}, 0, 0, false
}

// find_or_extend_dir finds a free slot in a directory, extending the chain if
// needed.
find_or_extend_dir :: proc(fsys: ^FS, dir_cluster: fs.Cluster, dir_offset: fs.Sector_Offset) -> (dcluster: fs.Cluster, dsec: fs.Sector_Offset, didx: int, ok: bool) {
	dcluster, dsec, didx, ok = find_free_slot_in_extent(fsys, dir_cluster, dir_offset)
	if ok {
		return
	}

	current_runs, cr_err := fs.resolve_extents(&fsys.vol, dir_cluster, dir_offset)
	defer delete(current_runs)
	if cr_err != .None {
		return {}, {}, 0, false
	}

	current_count: u64
	for r in current_runs {
		current_count += u64(r.count)
	}

	_, _, ext_err := fs.allocate_sectors(&fsys.vol, dir_cluster, dir_offset, current_count + 1, .Directory)
	if ext_err != .None {
		return {}, {}, 0, false
	}

	dir_runs, dir_err := fs.resolve_extents(&fsys.vol, dir_cluster, dir_offset)
	defer delete(dir_runs)
	if dir_err != .None {
		return {}, {}, 0, false
	}

	depc := dir_entries_per_buf(fsys.vol.master.features)
	last_run := dir_runs[len(dir_runs) - 1]
	last_sec := fs.Sector(u64(last_run.sector) + u64(last_run.count) - 1)
	ext_buf: [fs.SECTOR_SIZE]u8
	if !fs.sector_read(&fsys.vol, last_sec, ext_buf[:]) {
		return {}, {}, 0, false
	}

	zero_flags: fs.Dir_Flags
	for i in 0 ..< depc {
		if get_dir_entry(ext_buf[:], i, fsys.vol.master.features).flags == zero_flags {
			dlc := u64(last_sec) / fsys.vol.master.cluster_size
			dcluster = fs.Cluster(dlc)
			dsec = fs.Sector_Offset(u64(last_sec) - dlc * fsys.vol.master.cluster_size)
			didx = i
			ok = true
			return
		}
	}
	return {}, 0, 0, false
}

// check_name_exists checks whether a name already exists in the directory.
check_name_exists :: proc(fsys: ^FS, dir_cluster: fs.Cluster, dir_offset: fs.Sector_Offset, name: string) -> bool {
	depc := dir_entries_per_buf(fsys.vol.master.features)
	dir_runs, dir_err := fs.resolve_extents(&fsys.vol, dir_cluster, dir_offset)
	defer delete(dir_runs)
	if dir_err != .None {
		return false
	}

	scan_buf: [fs.SECTOR_SIZE]u8
	for run in dir_runs {
		n := int(run.count)
		for si in 0 ..< n {
			sec := fs.Sector(u64(run.sector) + u64(si))
			if !fs.sector_read(&fsys.vol, sec, scan_buf[:]) {
				return false
			}
			for i in 0 ..< depc {
				if .Exists in get_dir_entry(scan_buf[:], i, fsys.vol.master.features).flags {
					if fs.entry_short_name(get_dir_entry(scan_buf[:], i, fsys.vol.master.features)) == name {
						return true
					}
				}
			}
		}
	}
	return false
}

// write_entry_with_lfn writes a directory entry and sets its timestamps,
// handling LFN allocation for names longer than 16 characters.
write_entry_with_lfn :: proc(fsys: ^FS, entry: ^fs.Directory_Entry, name: string) -> bool {
	set_entry_time_to_now(entry)
	return set_entry_name(fsys, entry, name)
}

// set_entry_name sets the name in a Directory_Entry, handling LFN allocation
// and old LFN deallocation. Does NOT modify timestamps.
set_entry_name :: proc(fsys: ^FS, entry: ^fs.Directory_Entry, name: string) -> bool {
	if .LFN in entry.flags {
		ptr := (^fs.LFN_Pointer)(&entry.file_name[0])
		if ptr.cluster != 0 {
			if derr := fs.deallocate_sectors(&fsys.vol,fs.Cluster(ptr.cluster), fs.Sector_Offset(ptr.sector)); derr != .None {
				return false
			}
		}
		entry.flags -= {.LFN}
	}
	if len(name) > 16 {
		ptr, pok := fs.lfn_bump_write(&fsys.vol, &fsys.vol.lfn_bump, name)
		if !pok { return false }
		(^fs.LFN_Pointer)(&entry.file_name[0])^ = ptr
		entry.flags += {.LFN}
	} else {
		copy(entry.file_name[:], name)
		mem.zero_slice(entry.file_name[len(name):])
	}
	return true
}
