// extents.odin — Extent chain walker.  Resolves a (cluster, sector_offset)
// pair to the flat list of {absolute_sector, count} runs that comprise
// the file or directory's data on disk.
#+build linux
package fs

import "core:os"

resolve_extents :: proc(
	disk: ^os.File,
	master: ^Master_Record,
	start_cluster: Cluster,
	start_offset: Sector_Offset,
) -> (runs: [dynamic; 32]Extent_Run, ok: bool) {
	if start_cluster == 0 {
		return {}, false
	}

	current_cluster := start_cluster
	current_offset := start_offset
	cluster_size := u64(master.cluster_size)
	max_steps := int(master.cluster_map_size) + 1
	for guard in 0 ..< max_steps {
		if guard == max_steps - 1 {
			return runs, false
		}

		entry, found := find_cluster_entry(disk, master, current_cluster, current_offset)
		if !found {
			return runs, false
		}
		if entry.allocation_size == 0 {
			return runs, false
		}

		absolute_sector := Sector(u64(current_cluster) * cluster_size + u64(entry.sector_start))
		append(&runs, Extent_Run{absolute_sector, entry.allocation_size})
		if entry.next_cluster == 0 {
			break
		}
		current_cluster = Cluster(entry.next_cluster)
		current_offset  = Sector_Offset(entry.next_sector_index)
	}
	return runs, true
}
