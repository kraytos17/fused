// clustermap.odin — ClusterMapEntry and ClusterEntry table readers.
#+build linux
package fs

import "core:os"

read_cluster_map_entry :: proc(
	disk: ^os.File,
	master: ^Master_Record,
	cluster: Cluster,
) -> (entry: Cluster_Map_Entry, ok: bool) {
	if u64(cluster) >= master.cluster_map_size {return {}, false}
	entry_sector := Sector(master.cluster_map_offset + u64(cluster) / CLUSTER_ENTRIES_PER_SECTOR)
	entry_index  := u64(cluster) % CLUSTER_ENTRIES_PER_SECTOR

	buf: [SECTOR_SIZE]u8
	if !sector_read(disk, entry_sector, buf[:]) {return {}, false}
	entries := (^[CLUSTER_ENTRIES_PER_SECTOR]Cluster_Map_Entry)(raw_data(buf[:]))
	return entries[entry_index], true
}

read_cluster_entry_table :: proc(
	disk: ^os.File,
	master: ^Master_Record,
	cluster: Cluster,
	table: ^[CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry,
) -> bool {
	cme := read_cluster_map_entry(disk, master, cluster) or_return
	if .Allocated not_in cme.flags {return false}
	if u64(cme.sector_index) >= master.cluster_size {return false}

	table_sector := Sector(u64(cme.stored_cluster) * master.cluster_size + u64(cme.sector_index))

	buf: [SECTOR_SIZE]u8
	if !sector_read(disk, table_sector, buf[:]) {return false}
	raw := (^[CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry)(raw_data(buf[:]))
	for i in 0 ..< CLUSTER_ENTRIES_PER_SECTOR {table[i] = raw[i]}
	return true
}

find_cluster_entry :: proc(
	disk: ^os.File,
	master: ^Master_Record,
	cluster: Cluster,
	sector_offset: Sector_Offset,
) -> (entry: Cluster_Entry, ok: bool) {
	table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
	if !read_cluster_entry_table(disk, master, cluster, &table) {return {}, false}
	for t in table {
		if t.sector_start == u16(sector_offset) && .Allocated in t.state {
			return t, true
		}
	}
	return {}, false
}
