// clustermap.odin — ClusterMapEntry and ClusterEntry table readers.
#+build linux
package fs

import "core:os"

read_cluster_map_entry :: proc(
	disk: ^os.File,
	master: ^Master_Record,
	cluster: Cluster,
) -> (entry: Cluster_Map_Entry, ok: bool) {
	if u64(cluster) >= master.cluster_map_size {
		return {}, false
	}

	entry_sector := Sector(master.cluster_map_offset + u64(cluster) / CLUSTER_MAP_ENTRIES_PER_SECTOR)
	entry_index  := u64(cluster) % CLUSTER_MAP_ENTRIES_PER_SECTOR
	buf: [SECTOR_SIZE]u8
	if !sector_read(disk, entry_sector, buf[:]) {
		return {}, false
	}

	entries := (^[CLUSTER_MAP_ENTRIES_PER_SECTOR]Cluster_Map_Entry)(&buf[0])
	return entries[entry_index], true
}

read_cluster_entry_table :: proc(
	disk: ^os.File,
	master: ^Master_Record,
	cluster: Cluster,
	table: ^[CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry,
) -> bool {
	cme := read_cluster_map_entry(disk, master, cluster) or_return
	if .Allocated not_in cme.flags {
		return false
	}
	if u64(cme.sector_index) >= master.cluster_size {
		return false
	}

	table_sector := Sector(u64(cluster) * master.cluster_size + u64(cme.sector_index))
	buf: [SECTOR_SIZE]u8
	if !sector_read(disk, table_sector, buf[:]) {
		return false
	}

	raw := (^[CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry)(&buf[0])
	#unroll for i in 0 ..< CLUSTER_ENTRIES_PER_SECTOR {
		table[i] = raw[i]
	}
	return true
}

find_cluster_entry :: proc(
	disk: ^os.File,
	master: ^Master_Record,
	cluster: Cluster,
	sector_offset: Sector_Offset,
	table: ^[CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry = nil,
	index: ^int = nil,
) -> (entry: Cluster_Entry, ok: bool) {
	t: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
	tp := table if table != nil else &t
	if !read_cluster_entry_table(disk, master, cluster, tp) {
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

write_cluster_map_entry :: proc(
	disk: ^os.File, master: ^Master_Record, cluster: Cluster,
	entry: ^Cluster_Map_Entry,
) -> bool {
	if u64(cluster) >= master.cluster_map_size {
		return false
	}

	entry_sector := Sector(master.cluster_map_offset + u64(cluster) / CLUSTER_MAP_ENTRIES_PER_SECTOR)
	entry_index  := u64(cluster) % CLUSTER_MAP_ENTRIES_PER_SECTOR
	buf: [SECTOR_SIZE]u8
	if !sector_read(disk, entry_sector, buf[:]) {
		return false
	}

	entries := (^[CLUSTER_MAP_ENTRIES_PER_SECTOR]Cluster_Map_Entry)(&buf[0])
	entries[entry_index] = entry^
	return sector_write(disk, entry_sector, buf[:])
}

write_cluster_entry_table :: proc(
	disk: ^os.File, master: ^Master_Record, cluster: Cluster,
	table: ^[CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry,
) -> bool {
	cme := read_cluster_map_entry(disk, master, cluster) or_return
	if .Allocated not_in cme.flags {
		return false
	}

	table_sector := Sector(u64(cluster) * master.cluster_size + u64(cme.sector_index))
	buf: [SECTOR_SIZE]u8
	dst := (^[CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry)(&buf[0])
	#unroll for i in 0 ..< CLUSTER_ENTRIES_PER_SECTOR {
		dst[i] = table[i]
	}
	return sector_write(disk, table_sector, buf[:])
}

write_cluster_entry_at :: proc(
	disk: ^os.File, master: ^Master_Record,
	cluster: Cluster, entry_index: int, entry: ^Cluster_Entry,
) -> bool {
	table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
	if !read_cluster_entry_table(disk, master, cluster, &table) {
		return false
	}
	table[entry_index] = entry^
	return write_cluster_entry_table(disk, master, cluster, &table)
}
