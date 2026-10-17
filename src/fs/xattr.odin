// xattr.odin — Extended-attribute storage
//
// Xattrs are serialized into a self-describing blob stored in a dedicated
// .XAttr cluster chain referenced by Directory_Entry.xattr_cluster.  The
// chain head is located by scanning the owning cluster's CE table for an
// entry whose state carries .XAttr (mirrors LFN pointer resolution).
#+build linux
package fs

import "core:strings"

// XAttr is an in-memory extended attribute (name + value bytes).
XAttr :: struct {
	name:  string,
	value: []u8,
}

// _xattr_chain_locate finds the xattr data chain for an entry. Returns the
// cluster and the sector offset (from the CE table's sector_start).
@(private = "file")
_xattr_chain_locate :: proc(
	vol: ^Volume,
	entry: ^Directory_Entry,
) -> (
	cluster: Cluster,
	offset: Sector_Offset,
	ok: bool,
) {
	if entry.xattr_cluster == 0 {
		return {}, 0, false
	}

	ce_buf: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
	if read_cluster_entry_table(vol, Cluster(entry.xattr_cluster), &ce_buf) != .None {
		return {}, 0, false
	}
	if idx, found := ce_find_by_state(ce_buf, {.XAttr, .Allocated}); found {
		return Cluster(entry.xattr_cluster), Sector_Offset(ce_buf[idx].sector_start), true
	}
	return {}, 0, false
}

// xattr_free_chain deallocates the xattr chain rooted at the given cluster.
// It is called after the entry update that dereferences the chain has
// persisted: freeing earlier would leave a crash window where the on-disk
// entry points at freed (and reusable) sectors.
xattr_free_chain :: proc(vol: ^Volume, cluster: u64) -> FS_Error {
	if cluster == 0 {
		return .None
	}

	ce_buf: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
	if read_cluster_entry_table(vol, Cluster(cluster), &ce_buf) != .None {
		return .Entry_Not_Found
	}
	if idx, found := ce_find_by_state(ce_buf, {.XAttr, .Allocated}); found {
		return deallocate_sectors(
			vol,
			Chain_Location{Cluster(cluster), Sector_Offset(ce_buf[idx].sector_start)},
		)
	}
	return .Entry_Not_Found
}

// xattr_load reads all extended attributes for an entry into a dynamic
// array of cloned name/value pairs. The caller is responsible for deleting
// each element's name/value and the array itself. Returns an empty list
// when the entry has no xattrs.
xattr_load :: proc(
	vol: ^Volume,
	entry: ^Directory_Entry,
	allocator := context.allocator,
) -> (
	attrs: [dynamic]XAttr,
	err: FS_Error,
) {
	attrs = make([dynamic]XAttr, 0, 4, allocator)
	if entry.xattr_cluster == 0 {
		return attrs, .None
	}

	cluster, offset, ok := _xattr_chain_locate(vol, entry)
	if !ok {
		return attrs, .Entry_Not_Found
	}

	data, rerr := read_chain(vol, Chain_Location{cluster, offset}, allocator)
	defer delete(data, allocator)
	if rerr != .None {
		return attrs, rerr
	}

	// A malformed blob is corruption, not an empty set: fail closed so a
	// torn xattr chain can never surface as silently missing attributes.
	// Partial appends are freed and the array cleared (the caller still
	// owns and deletes it).
	if derr := _xattr_deserialize_into(&attrs, data[:], allocator); derr != .None {
		for &a in attrs {
			delete(a.name, allocator)
			delete(a.value, allocator)
		}
		clear(&attrs)
		return attrs, derr
	}
	return attrs, .None
}

// xattr_get returns a heap-allocated copy of the value for a named
// attribute. The caller deletes the returned slice. found=false when the
// attribute does not exist; err reports load/parse failure separately so
// corruption is never mistaken for absence.
xattr_get :: proc(
	vol: ^Volume,
	entry: ^Directory_Entry,
	name: string,
	allocator := context.allocator,
) -> (
	value: []u8,
	found: bool,
	err: FS_Error,
) {
	attrs, lerr := xattr_load(vol, entry, allocator)
	defer {
		for &a in attrs {
			delete(a.name, allocator)
			delete(a.value, allocator)
		}
		delete(attrs)
	}
	if lerr != .None {
		return {}, false, lerr
	}
	for &a in attrs {
		if a.name == name {
			value = make([]u8, len(a.value), allocator)
			copy(value, a.value)
			return value, true, .None
		}
	}
	return {}, false, .None
}

// xattr_store replaces the full attribute set for an entry. It serializes
// the blob, allocates a fresh .XAttr chain, writes it, and updates
// entry.xattr_cluster, returning the previous chain for reclamation. The
// old chain is deliberately NOT freed here: the caller must persist the
// updated entry first and free the old chain after, so no crash window
// leaves the on-disk entry pointing at freed sectors. On any failure the
// entry is untouched and the old chain stays live.
xattr_store :: proc(
	vol: ^Volume,
	entry: ^Directory_Entry,
	attrs: []XAttr,
) -> (
	reclaim: u64,
	err: FS_Error,
) {
	data := _xattr_serialize(attrs)
	defer delete(data)

	old_cluster := entry.xattr_cluster
	if len(data) == 0 {
		entry.xattr_cluster = 0
		return old_cluster, .None
	}

	sectors := (u64(len(data)) + SECTOR_SIZE - 1) / SECTOR_SIZE
	new_c, new_o, aerr := allocate_sectors(vol, {}, sectors, .XAttr)
	if aerr != .None {
		return 0, aerr
	}
	if werr := write_chain(vol, Chain_Location{new_c, new_o}, data); werr != .None {
		// Best-effort reclaim of the unpublished chain; the old chain
		// and the entry are untouched. A double fault here leaks the
		// new chain for the checker.
		_ = deallocate_sectors(vol, Chain_Location{new_c, new_o})
		return 0, werr
	}

	entry.xattr_cluster = u64(new_c)
	return old_cluster, .None
}

// xattr_remove deletes a single named attribute. Returns removed=true when
// the attribute existed. The caller persists the updated entry to disk.
xattr_remove :: proc(
	vol: ^Volume,
	entry: ^Directory_Entry,
	name: string,
	allocator := context.allocator,
) -> (
	removed: bool,
	reclaim: u64,
	err: FS_Error,
) {
	attrs, lerr := xattr_load(vol, entry, allocator)
	defer delete(attrs)
	if lerr != .None {
		return false, 0, lerr
	}

	removed = false
	for a, i in attrs {
		if a.name == name {
			delete(a.name, allocator)
			delete(a.value, allocator)
			ordered_remove(&attrs, i)
			removed = true
			break
		}
	}
	if !removed {
		for &a in attrs {
			delete(a.name, allocator)
			delete(a.value, allocator)
		}
		return false, 0, .None
	}
	old_chain, serr := xattr_store(vol, entry, attrs[:])
	if serr != .None {
		for &a in attrs {
			delete(a.name, allocator)
			delete(a.value, allocator)
		}
		return false, 0, serr
	}
	for &a in attrs {
		delete(a.name, allocator)
		delete(a.value, allocator)
	}
	return true, old_chain, .None
}

// xattr_clear detaches the xattr chain from an entry, returning it for
// reclamation. The chain itself is deliberately NOT freed here: the
// caller must persist the cleared entry first and free the old chain
// after, so no crash window leaves the on-disk entry pointing at freed
// sectors. Infallible: no I/O happens in this procedure.
xattr_clear :: proc(entry: ^Directory_Entry) -> (reclaimed: u64) {
	old := entry.xattr_cluster
	entry.xattr_cluster = 0
	return old
}

// _xattr_serialize packs attributes into a blob buffer.
@(private = "file")
_xattr_serialize :: proc(attrs: []XAttr) -> (data: []u8) {
	total := 0
	for a in attrs {
		total += size_of(XAttr_Record_Header) + len(a.name) + len(a.value)
	}

	data = make([]u8, size_of(XAttr_Blob_Header) + total)
	hdr_ptr := (^XAttr_Blob_Header)(raw_data(data))
	hdr := hdr_ptr^
	hdr.magic = XATTR_MAGIC
	hdr.count = u16(len(attrs))
	hdr.total = u32(total)
	hdr_ptr^ = hdr
	pos := size_of(XAttr_Blob_Header)
	for a in attrs {
		rh_ptr := (^XAttr_Record_Header)(raw_data(data[pos:]))
		rh := rh_ptr^
		rh.name_len = u16(len(a.name))
		rh.value_len = u32(len(a.value))
		rh_ptr^ = rh
		pos += size_of(XAttr_Record_Header)

		copy(data[pos:], a.name)
		pos += len(a.name)
		copy(data[pos:], a.value)
		pos += len(a.value)
	}
	return data
}

// _xattr_deserialize_into parses a blob buffer into an existing dynamic
// array of cloned attributes. Every structural property is validated:
// header size, magic, per-record bounds, recomputed total, exact record
// count and consumption, and duplicate names. Anything else is
// .Corrupt_XAttr_Blob — a torn blob must never surface as a partial or
// empty attribute set. Partial appends stay in the array; the caller
// frees them on error.
@(private = "file")
_xattr_deserialize_into :: proc(
	attrs: ^[dynamic]XAttr,
	data: []u8,
	allocator := context.allocator,
) -> FS_Error {
	if len(data) < size_of(XAttr_Blob_Header) {
		return .Corrupt_XAttr_Blob
	}

	hdr := (^XAttr_Blob_Header)(raw_data(data))^
	if hdr.magic != XATTR_MAGIC {
		return .Corrupt_XAttr_Blob
	}

	pos := size_of(XAttr_Blob_Header)
	accounted := 0
	for _ in 0 ..< int(hdr.count) {
		if pos + size_of(XAttr_Record_Header) > len(data) {
			return .Corrupt_XAttr_Blob
		}

		rh := (^XAttr_Record_Header)(raw_data(data[pos:]))^
		pos += size_of(XAttr_Record_Header)
		name_len := int(rh.name_len)
		value_len := int(rh.value_len)
		if name_len == 0 || pos + name_len + value_len > len(data) {
			return .Corrupt_XAttr_Blob
		}

		for &a in attrs^ {
			if a.name == string(data[pos:pos + name_len]) {
				return .Corrupt_XAttr_Blob
			}
		}

		name := strings.clone(string(data[pos:pos + name_len]), allocator)
		pos += name_len
		value := make([]u8, value_len, allocator)

		copy(value, data[pos:pos + value_len])
		pos += value_len
		append(attrs, XAttr{name = name, value = value})
		accounted += size_of(XAttr_Record_Header) + name_len + value_len
	}
	if accounted != int(hdr.total) {
		return .Corrupt_XAttr_Blob
	}
	// No exact end-of-data check: chains are sector-granular, so a valid
	// blob is always followed by sector padding (zeros or stale bytes)
	// that is never parsed. The record count, recomputed total, and
	// per-record bounds above are the integrity contract.
	return .None
}
