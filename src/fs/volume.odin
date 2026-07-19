// volume.odin — Volume is the central filesystem handle for fused.
// Bundles disk, master record, alloc cache, and per-volume state
// into one struct so callers pass a single parameter instead of
// threading (disk, master, cache) through every procedure.
#+build linux
package fs

import "core:os"

// LFN_Bump is a bump allocator for long filename data sectors.
// LFNs are append-only (filenames never change) and never freed
// individually, so a bump allocator avoids the fragmentation that
// a general-purpose per-sector allocation would incur — each sector
// packs ~25 names sequentially instead of one name per sector.
LFN_Bump_State :: struct {
	cluster:   Cluster,
	offset:    Sector_Offset,
	sector:    Sector,
	next_byte: u16,
}

LFN_Bump :: struct {
	state: Maybe(LFN_Bump_State),
}

// Volume bundles the open disk, the validated master record, and
// the alloc cache into one named thing.  Every procedure in package
// fs that previously took (disk, master) or (disk, master, cache)
// as positional parameters now takes ^Volume as its first parameter.
Volume :: struct {
	disk:       ^os.File,
	master:     Master_Record,
	cache:      Cluster_Bitmap_Cache,
	image_size: Byte_Offset,
	lfn_bump:   LFN_Bump,
}

// volume_open opens a fused disk image, reads and validates the
// MasterRecord, runs journal recovery, and initialises the alloc
// cache.  Returns an FS_Error on failure (the caller should check
// before using vol).
volume_open :: proc(path: string) -> (vol: Volume, err: FS_Error) {
	fd, open_err := os.open(path, {.Read, .Write})
	if open_err != nil {
		return {}, .Sector_Read_Error
	}

	vol.disk = fd
	master, ok := read_master_record(fd)
	if !ok {
		os.close(fd)
		return {}, .Corrupt_Master_Record
	}

	fi, stat_err := os.stat(path, context.temp_allocator)
	if stat_err == nil {
		vol.image_size = Byte_Offset(u64(fi.size))
	}
	if verr := validate_master(&master, vol.image_size); verr != .None {
		os.close(fd)
		return {}, verr
	}
	
	vol.master = master
	alloc_cache_init(&vol.cache, &vol.master)
	if .Journal_V2 in master.features {
		journal_v2_recover(&vol)
	} else {
		intent_log_recover(&vol)
	}
	return vol, .None
}

// volume_close destroys the alloc cache and closes the disk file.
volume_close :: proc(vol: ^Volume) {
	alloc_cache_destroy(&vol.cache)
	os.close(vol.disk)
	vol^ = {}
}

// File_Handle packs the parent-directory location and entry index
// into the 64-bit opaque FUSE file handle using a bit_field.
File_Handle :: bit_field u64 {
	dir_cluster: u64  | 32,
	dir_offset:  u16  | 16,
	entry_index: u16  | 16,
}

// Convenience constructor so callers pass Cluster/Sector_Offset directly.
make_file_handle :: proc(cluster: Cluster, offset: Sector_Offset, idx: int) -> File_Handle {
	return {dir_cluster = u64(cluster), dir_offset = u16(offset), entry_index = u16(idx)}
}

// lfn_bump_write allocates space for a long file name using the bump
// allocator embedded in Volume.  If the current bump sector is full (or
// no sector has been allocated yet) a new .LFN sector is allocated and
// the bump is reset.  Returns a packed LFN_Pointer referencing the
// on-disk copy, or (!ok) on I/O / space failure.
	lfn_bump_write :: proc(vol: ^Volume, bump: ^LFN_Bump, name: string) -> (ptr: LFN_Pointer, ok: bool) {
	needed := u16(len(name))
	s, has_state := bump.state.?
	if !has_state || s.next_byte + needed > SECTOR_SIZE {
		new_c, new_o, lerr := allocate_sectors(vol, 0, 0, 1, .LFN)
		if lerr != .None { return {}, false }

		runs, rok := resolve_extents(vol, new_c, new_o)
		defer delete(runs)
		if !rok || len(runs) == 0 { return {}, false }

		new_state := LFN_Bump_State{cluster = new_c, offset = new_o, sector = runs[0].sector, next_byte = 0}
		bump.state = new_state
		s = new_state
	}

	buf: [SECTOR_SIZE]u8
	if !sector_read(vol, s.sector, buf[:]) { return {}, false }
	copy(buf[s.next_byte:], transmute([]u8)name)
	if !sector_write(vol, s.sector, buf[:]) { return {}, false }

	ptr = {
		cluster = u64(s.cluster),
		size    = u32(len(name)),
		sector  = u16(s.offset),
		_pad    = s.next_byte,
	}
	new_state := LFN_Bump_State{cluster = s.cluster, offset = s.offset, sector = s.sector, next_byte = s.next_byte + needed}
	bump.state = new_state
	return ptr, true
}
