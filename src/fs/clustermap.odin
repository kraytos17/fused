// clustermap.odin — ClusterMapEntry and ClusterEntry table readers.
#+build linux
package fs

read_cluster_map_entry :: proc(vol: ^Volume, cluster: Cluster) -> (entry: Cluster_Map_Entry, ok: bool) {
	if u64(cluster) >= vol.master.cluster_map_size {
		return {}, false
	}

	entry_sector := Sector(vol.master.cluster_map_offset + u64(cluster) / CLUSTER_MAP_ENTRIES_PER_SECTOR)
	entry_index  := u64(cluster) % CLUSTER_MAP_ENTRIES_PER_SECTOR
	buf: [SECTOR_SIZE]u8
	if !sector_read(vol, entry_sector, buf[:]) {
		return {}, false
	}
	entries := (^[CLUSTER_MAP_ENTRIES_PER_SECTOR]Cluster_Map_Entry)(&buf[0])
	return entries[entry_index], true
}

read_cluster_entry_table :: proc(vol: ^Volume, cluster: Cluster, table: ^[CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry) -> bool {
	cme := read_cluster_map_entry(vol, cluster) or_return
	if .Allocated not_in cme.flags {
		return false
	}
	if u64(cme.sector_index) >= vol.master.cluster_size {
		return false
	}

	table_sector := Sector(u64(cluster) * vol.master.cluster_size + u64(cme.sector_index))
	buf: [SECTOR_SIZE]u8
	if !sector_read(vol, table_sector, buf[:]) {
		return false
	}

	raw := (^[CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry)(&buf[0])
	#unroll for i in 0 ..< CLUSTER_ENTRIES_PER_SECTOR {
		table[i] = raw[i]
	}
	return true
}

find_cluster_entry :: proc(
	vol: ^Volume, cluster: Cluster, sector_offset: Sector_Offset,
	table: ^[CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry = nil,
	index: ^int = nil,
) -> (entry: Cluster_Entry, ok: bool) {
	t: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
	tp := table if table != nil else &t
	if !read_cluster_entry_table(vol, cluster, tp) {
		return {}, false
	}
	for &e, i in tp[:] {
		if e.sector_start == u16(sector_offset) && .Allocated in e.state {
			if index != nil {
				index^ = i
			}
			return e, true
		}
	}
	return {}, false
}

write_cluster_map_entry :: proc(vol: ^Volume, cluster: Cluster, entry: ^Cluster_Map_Entry) -> bool {
	if u64(cluster) >= vol.master.cluster_map_size {
		return false
	}

	entry_sector := Sector(vol.master.cluster_map_offset + u64(cluster) / CLUSTER_MAP_ENTRIES_PER_SECTOR)
	entry_index  := u64(cluster) % CLUSTER_MAP_ENTRIES_PER_SECTOR
	buf: [SECTOR_SIZE]u8
	if !sector_read(vol, entry_sector, buf[:]) {
		return false
	}

	entries := (^[CLUSTER_MAP_ENTRIES_PER_SECTOR]Cluster_Map_Entry)(&buf[0])
	entries[entry_index] = entry^
	ok := sector_write(vol, entry_sector, buf[:])
	if ok {
		alloc_cache_invalidate(&vol.cache, u64(cluster))
	}
	return ok
}

write_cluster_entry_table :: proc(vol: ^Volume, cluster: Cluster, table: ^[CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry) -> bool {
	cme := read_cluster_map_entry(vol, cluster) or_return
	if .Allocated not_in cme.flags {
		return false
	}

	table_sector := Sector(u64(cluster) * vol.master.cluster_size + u64(cme.sector_index))
	buf: [SECTOR_SIZE]u8
	dst := (^[CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry)(&buf[0])
	#unroll for i in 0 ..< CLUSTER_ENTRIES_PER_SECTOR {
		dst[i] = table[i]
	}

	ok := sector_write(vol, table_sector, buf[:])
	if ok {
		alloc_cache_invalidate(&vol.cache, u64(cluster))
	}
	return ok
}

write_cluster_entry_at :: proc(vol: ^Volume, cluster: Cluster, entry_index: int, entry: ^Cluster_Entry) -> bool {
	table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
	if !read_cluster_entry_table(vol, cluster, &table) {
		return false
	}
	table[entry_index] = entry^
	return write_cluster_entry_table(vol, cluster, &table)
}

@private
Chain_Cursor :: struct {
	cluster: Cluster,
	offset:  Sector_Offset,
}

@private
Chain_Step :: enum {
	Advance,
	At_End,
	Corrupted,
}

@private
chain_step :: proc(vol: ^Volume, cursor: ^Chain_Cursor, guard: int, max_guards: int) -> (ce: Cluster_Entry, entry_cluster: Cluster, step: Chain_Step) {
	if guard >= max_guards {
		return {}, {}, .Corrupted
	}

	found_ce, found_ok := find_cluster_entry(vol, cursor.cluster, cursor.offset)
	if !found_ok || found_ce.allocation_size == 0 {
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
