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
	dir_cache:  Dir_Entry_Cache,
	image_size: Byte_Offset,
	lfn_bump:   LFN_Bump,
}

// volume_open opens a fused disk image, reads and validates the
// MasterRecord, runs journal recovery, and initialises the alloc
// cache.  Returns an FS_Error on failure (the caller should check
// before using vol).
volume_open :: proc(path: string, cache := DEFAULT_CACHE_CONFIG) -> (vol: Volume, err: FS_Error) {
	fd, open_err := os.open(path, {.Read, .Write})
	if open_err != nil {
		return {}, .Sector_Read_Error
	}

	vol.disk = fd
	master, merr := read_master_record(fd)
	if merr != .None {
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
	alloc_cap := cache.alloc_cap if cache.alloc_cap > 0 else DEFAULT_CACHE_CONFIG.alloc_cap
	alloc_cache_init(&vol.cache, &vol.master, alloc_cap)

	dir_cap := cache.dir_cap if cache.dir_cap > 0 else DEFAULT_CACHE_CONFIG.dir_cap
	dir_cache_init(&vol.dir_cache, dir_cap)
	JOURNAL_BACKEND.recover(&vol)
	return vol, .None
}

// volume_close destroys the alloc cache and closes the disk file.
volume_close :: proc(vol: ^Volume) {
	alloc_cache_destroy(&vol.cache)
	dir_cache_destroy(&vol.dir_cache)
	os.close(vol.disk)
	vol^ = {}
}

// File_Handle packs the parent-directory location and entry index
// into the 64-bit opaque FUSE file handle using a bit_field.
File_Handle :: bit_field u64 {
	dir_cluster: u64 | 32,
	dir_offset:  u16 | 16,
	entry_index: u16 | 16,
}

// Convenience constructor so callers pass Cluster/Sector_Offset directly.
// The u16 narrowings are lossless by domain (Sector_Offset is u16-based;
// entry indices are < entries-per-sector); this is the single site where
// identity triples are packed, so the invariant has one home.
make_file_handle :: proc "contextless" (
	cluster: Cluster,
	offset: Sector_Offset,
	idx: int,
) -> File_Handle {
	return {dir_cluster = u64(cluster), dir_offset = u16(offset), entry_index = u16(idx)}
}

// lfn_bump_write stores one long file name in a freshly allocated .LFN
// sector and returns a packed LFN_Pointer to it. Each name takes its
// own sector (no bump packing): an entry freed by rename or unlink owns
// its storage exclusively, so freeing one name can never invalidate
// another. The bump state is retained but no longer accumulates multiple
// names per sector. Returns (!ok) on I/O / space failure.
lfn_bump_write :: proc(
	vol: ^Volume,
	bump: ^LFN_Bump,
	name: string,
) -> (
	ptr: LFN_Pointer,
	err: FS_Error,
) {
	_ = bump
	new_c, new_o, lerr := allocate_sectors(vol, {}, 1, .LFN)
	if lerr != .None { return {}, lerr }

	runs, rok := resolve_extents(vol, Chain_Location{new_c, new_o})
	defer delete(runs)
	if rok != .None { return {}, rok }
	if len(runs) == 0 { return {}, .Entry_Not_Found }

	// The buffer starts zeroed and readers honor size, so no
	// read-modify-write of stale sector bytes is needed.
	buf: [SECTOR_SIZE]u8
	copy(buf[:], transmute([]u8)name)
	if sector_write(vol, runs[0].sector, buf[:]) != .None { return {}, .Sector_Write_Error }

	ptr = {
		cluster = u64(new_c),
		size    = u32(len(name)),
		sector  = u16(new_o),
		_pad    = 0,
	}
	return ptr, .None
}
