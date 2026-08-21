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
@private
_xattr_chain_locate :: proc(vol: ^Volume, entry: ^Directory_Entry) -> (cluster: Cluster, offset: Sector_Offset, ok: bool) {
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

// _xattr_chain_free deallocates the xattr chain rooted at the given cluster.
@private
_xattr_chain_free :: proc(vol: ^Volume, cluster: u64) -> FS_Error {
	if cluster == 0 {
		return .None
	}

	ce_buf: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
	if read_cluster_entry_table(vol, Cluster(cluster), &ce_buf) != .None {
		return .Entry_Not_Found
	}
	if idx, found := ce_find_by_state(ce_buf, {.XAttr, .Allocated}); found {
		return deallocate_sectors(vol, Cluster(cluster), Sector_Offset(ce_buf[idx].sector_start))
	}
	return .Entry_Not_Found
}

// xattr_load reads all extended attributes for an entry into a dynamic
// array of cloned name/value pairs. The caller is responsible for deleting
// each element's name/value and the array itself. Returns an empty list
// when the entry has no xattrs.
xattr_load :: proc(vol: ^Volume, entry: ^Directory_Entry, allocator := context.allocator) -> (attrs: [dynamic]XAttr, err: FS_Error) {
	attrs = make([dynamic]XAttr, 0, 4, allocator)
	if entry.xattr_cluster == 0 {
		return attrs, .None
	}

	cluster, offset, ok := _xattr_chain_locate(vol, entry)
	if !ok {
		return attrs, .Entry_Not_Found
	}

	data, rerr := read_chain(vol, cluster, offset, allocator)
	defer delete(data, allocator)
	if rerr != .None {
		return attrs, rerr
	}

	_xattr_deserialize_into(&attrs, data[:], allocator)
	return attrs, .None
}

// xattr_get returns a heap-allocated copy of the value for a named
// attribute. The caller deletes the returned slice. found=false when the
// attribute does not exist.
xattr_get :: proc(vol: ^Volume, entry: ^Directory_Entry, name: string, allocator := context.allocator) -> (value: []u8, found: bool) {
	attrs, err := xattr_load(vol, entry, allocator)
	defer {
		for &a in attrs {
			delete(a.name, allocator)
			delete(a.value, allocator)
		}
		delete(attrs)
	}
	if err != .None {
		return {}, false
	}
	for &a in attrs {
		if a.name == name {
			value = make([]u8, len(a.value), allocator)
			copy(value, a.value)
			return value, true
		}
	}
	return {}, false
}

// xattr_store replaces the full attribute set for an entry. It serializes
// the blob, allocates a fresh .XAttr chain, writes it, updates
// entry.xattr_cluster, and frees the previous chain (if any). The caller
// persists the updated entry to disk.
xattr_store :: proc(vol: ^Volume, entry: ^Directory_Entry, attrs: []XAttr) -> FS_Error {
	data := _xattr_serialize(attrs)
	defer delete(data)

	old_cluster := entry.xattr_cluster
	if len(data) == 0 {
		if old_cluster != 0 {
			if cerr := _xattr_chain_free(vol, old_cluster); cerr != .None {
				return cerr
			}
		}
		entry.xattr_cluster = 0
		return .None
	}

	sectors := (u64(len(data)) + SECTOR_SIZE - 1) / SECTOR_SIZE
	new_c, new_o, aerr := allocate_sectors(vol, 0, 0, sectors, .XAttr)
	if aerr != .None {
		return aerr
	}
	if werr := write_chain(vol, new_c, new_o, data); werr != .None {
		return werr
	}
	if old_cluster != 0 {
		if cerr := _xattr_chain_free(vol, old_cluster); cerr != .None {
			return cerr
		}
	}
	entry.xattr_cluster = u64(new_c)
	return .None
}

// xattr_remove deletes a single named attribute. Returns removed=true when
// the attribute existed. The caller persists the updated entry to disk.
xattr_remove :: proc(vol: ^Volume, entry: ^Directory_Entry, name: string, allocator := context.allocator) -> (removed: bool, err: FS_Error) {
	attrs, lerr := xattr_load(vol, entry, allocator)
	if lerr != .None {
		return false, lerr
	}
	defer delete(attrs)

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
		return false, .None
	}
	if serr := xattr_store(vol, entry, attrs[:]); serr != .None {
		for &a in attrs {
			delete(a.name, allocator)
			delete(a.value, allocator)
		}
		return false, serr
	}
	for &a in attrs {
		delete(a.name, allocator)
		delete(a.value, allocator)
	}
	return true, .None
}

// xattr_clear frees the xattr chain for an entry and zeroes
// xattr_cluster. The caller persists the updated entry to disk.
xattr_clear :: proc(vol: ^Volume, entry: ^Directory_Entry) -> FS_Error {
	if entry.xattr_cluster == 0 {
		return .None
	}
	err := _xattr_chain_free(vol, entry.xattr_cluster)
	entry.xattr_cluster = 0
	return err
}

// _xattr_serialize packs attributes into a blob buffer.
@private
_xattr_serialize :: proc(attrs: []XAttr) -> (data: []u8) {
	total := 0
	for a in attrs {
		total += size_of(XAttr_Record_Header) + len(a.name) + len(a.value)
	}

	data = make([]u8, size_of(XAttr_Blob_Header) + total)
	hdr := (^XAttr_Blob_Header)(raw_data(data))^
	hdr.magic = XATTR_MAGIC
	hdr.count = u16(len(attrs))
	hdr.total = u32(total)
	(^XAttr_Blob_Header)(raw_data(data))^ = hdr

	pos := size_of(XAttr_Blob_Header)
	for a in attrs {
		rh := (^XAttr_Record_Header)(raw_data(data[pos:]))^
		rh.name_len = u16(len(a.name))
		rh.value_len = u32(len(a.value))
		(^XAttr_Record_Header)(raw_data(data[pos:]))^ = rh
		pos += size_of(XAttr_Record_Header)

		copy(data[pos:], a.name)
		pos += len(a.name)
		copy(data[pos:], a.value)
		pos += len(a.value)
	}
	return data
}

// _xattr_deserialize_into parses a blob buffer into an existing dynamic
// array of cloned attributes.
@private
_xattr_deserialize_into :: proc(attrs: ^[dynamic]XAttr, data: []u8, allocator := context.allocator) {
	if len(data) < size_of(XAttr_Blob_Header) {
		return
	}

	hdr := (^XAttr_Blob_Header)(raw_data(data))^
	if hdr.magic != XATTR_MAGIC {
		return
	}

	pos := size_of(XAttr_Blob_Header)
	for _ in 0 ..< int(hdr.count) {
		if pos + size_of(XAttr_Record_Header) > len(data) {
			break
		}

		rh := (^XAttr_Record_Header)(raw_data(data[pos:]))^
		pos += size_of(XAttr_Record_Header)
		name_len := int(rh.name_len)
		value_len := int(rh.value_len)
		if pos + name_len + value_len > len(data) {
			break
		}

		name := strings.clone(string(data[pos:pos + name_len]), allocator)
		pos += name_len
		value := make([]u8, value_len, allocator)
		copy(value, data[pos:pos + value_len])
		pos += value_len
		append(attrs, XAttr{name = name, value = value})
	}
}
