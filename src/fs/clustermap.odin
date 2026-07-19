// clustermap.odin — ClusterMapEntry and ClusterEntry table readers.
#+build linux
package fs

// read_cluster_map_entry reads the Cluster_Map_Entry for the given cluster
// from the cluster map table on disk. Returns the entry or an error if the
// cluster index is out of range or a sector read fails.
read_cluster_map_entry :: proc(vol: ^Volume, cluster: Cluster) -> (entry: Cluster_Map_Entry, err: FS_Error) {
	if u64(cluster) >= vol.master.cluster_map_size {
		return {}, .Entry_Not_Found
	}

	entry_sector := Sector(vol.master.cluster_map_offset + u64(cluster) / CLUSTER_MAP_ENTRIES_PER_SECTOR)
	entry_index  := u64(cluster) % CLUSTER_MAP_ENTRIES_PER_SECTOR
	buf: [SECTOR_SIZE]u8
	if !sector_read(vol, entry_sector, buf[:]) {
		return {}, .Sector_Read_Error
	}
	entries := (^[CLUSTER_MAP_ENTRIES_PER_SECTOR]Cluster_Map_Entry)(&buf[0])
	return entries[entry_index], .None
}

// read_cluster_entry_table reads the full 32-entry Cluster_Entry table for the
// given cluster from disk. Returns an error if the cluster map entry is not
// allocated, the sector index is out of range, or a sector read fails.
read_cluster_entry_table :: proc(vol: ^Volume, cluster: Cluster, table: ^[CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry) -> FS_Error {
	cme := read_cluster_map_entry(vol, cluster) or_return
	if .Allocated not_in cme.flags {
		return .Entry_Not_Found
	}
	if u64(cme.sector_index) >= vol.master.cluster_size {
		return .Entry_Not_Found
	}

	table_sector := Sector(u64(cluster) * vol.master.cluster_size + u64(cme.sector_index))
	buf: [SECTOR_SIZE]u8
	if !sector_read(vol, table_sector, buf[:]) {
		return .Sector_Read_Error
	}

	raw := (^[CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry)(&buf[0])
	#unroll for i in 0 ..< CLUSTER_ENTRIES_PER_SECTOR {
		table[i] = raw[i]
	}
	return .None
}

// find_cluster_entry searches the cluster entry table for an entry whose
// sector_start matches the given sector_offset. Optionally returns the
// full table and the matching index via out parameters. Returns
// Entry_Not_Found if no match is found.
find_cluster_entry :: proc(
	vol: ^Volume, cluster: Cluster, sector_offset: Sector_Offset,
	table: ^[CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry = nil,
	index: ^int = nil,
) -> (entry: Cluster_Entry, err: FS_Error) {
	t: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
	tp := table if table != nil else &t
	read_cluster_entry_table(vol, cluster, tp) or_return
	for &e, i in tp[:] {
		if e.sector_start == u16(sector_offset) && .Allocated in e.state {
			if index != nil {
				index^ = i
			}
			return e, .None
		}
	}
	return {}, .Entry_Not_Found
}

// write_cluster_map_entry writes a Cluster_Map_Entry to the cluster map table
// on disk and invalidates the allocation cache for the given cluster. Returns
// an error if the cluster index is out of range or a sector read/write fails.
write_cluster_map_entry :: proc(vol: ^Volume, cluster: Cluster, entry: ^Cluster_Map_Entry) -> FS_Error {
	if u64(cluster) >= vol.master.cluster_map_size {
		return .Entry_Not_Found
	}

	entry_sector := Sector(vol.master.cluster_map_offset + u64(cluster) / CLUSTER_MAP_ENTRIES_PER_SECTOR)
	entry_index  := u64(cluster) % CLUSTER_MAP_ENTRIES_PER_SECTOR
	buf: [SECTOR_SIZE]u8
	if !sector_read(vol, entry_sector, buf[:]) {
		return .Sector_Read_Error
	}

	entries := (^[CLUSTER_MAP_ENTRIES_PER_SECTOR]Cluster_Map_Entry)(&buf[0])
	entries[entry_index] = entry^
	if !sector_write(vol, entry_sector, buf[:]) {
		return .Sector_Write_Error
	}
	alloc_cache_invalidate(&vol.cache, u64(cluster))
	return .None
}

// write_cluster_entry_table writes the full Cluster_Entry table for the given
// cluster to disk and invalidates the allocation cache. Returns an error if
// the cluster map entry is not allocated or a sector write fails.
write_cluster_entry_table :: proc(vol: ^Volume, cluster: Cluster, table: ^[CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry) -> FS_Error {
	cme := read_cluster_map_entry(vol, cluster) or_return
	if .Allocated not_in cme.flags {
		return .Entry_Not_Found
	}

	table_sector := Sector(u64(cluster) * vol.master.cluster_size + u64(cme.sector_index))
	buf: [SECTOR_SIZE]u8
	dst := (^[CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry)(&buf[0])
	#unroll for i in 0 ..< CLUSTER_ENTRIES_PER_SECTOR {
		dst[i] = table[i]
	}
	if !sector_write(vol, table_sector, buf[:]) {
		return .Sector_Write_Error
	}
	alloc_cache_invalidate(&vol.cache, u64(cluster))
	return .None
}

// write_cluster_entry_at updates a single Cluster_Entry at the given index in
// the cluster entry table, then writes the full table back to disk. Returns
// an error if reading or writing the table fails.
write_cluster_entry_at :: proc(vol: ^Volume, cluster: Cluster, entry_index: int, entry: ^Cluster_Entry) -> FS_Error {
	table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
	read_cluster_entry_table(vol, cluster, &table) or_return
	table[entry_index] = entry^
	return write_cluster_entry_table(vol, cluster, &table)
}

// Chain_Cursor holds the current position while walking a linked chain of
// cluster entries. It tracks the current cluster and sector offset.
@private
Chain_Cursor :: struct {
	cluster: Cluster,
	offset:  Sector_Offset,
}

// Chain_Step indicates the result of advancing a Chain_Cursor: Advance means
// the cursor moved to the next link, At_End means the chain terminated
// normally, and Corrupted means the chain exceeded the guard limit.
@private
Chain_Step :: enum {
	Advance,
	At_End,
	Corrupted,
}

// _chain_step advances a Chain_Cursor one link forward by looking up the
// cluster entry at the cursor's current position and following the
// next_cluster / next_sector_index pointers. Returns the current cluster
// entry, the cluster it was found in, and a Chain_Step status. Returns
// Corrupted if the guard limit is reached or the entry is invalid.
@private
_chain_step :: proc(vol: ^Volume, cursor: ^Chain_Cursor, guard: int, max_guards: int) -> (ce: Cluster_Entry, entry_cluster: Cluster, step: Chain_Step) {
	if guard >= max_guards {
		return {}, {}, .Corrupted
	}

	found_ce, found_err := find_cluster_entry(vol, cursor.cluster, cursor.offset)
	if found_err != .None || found_ce.allocation_size == 0 {
		return {}, {}, .Corrupted
	}

	ce = found_ce
	entry_cluster = cursor.cluster
	if ce.next_cluster == 0 {
		step = .At_End
		return
	}

	cursor.cluster = Cluster(ce.next_cluster)
	cursor.offset  = Sector_Offset(ce.next_sector_index)
	step = .Advance
	return
}
