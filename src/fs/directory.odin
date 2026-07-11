// directory.odin — Directory entry iteration and LFN resolution.
#+build linux
package fs

import "core:os"

read_directory_entries :: proc(
	disk: ^os.File,
	master: ^Master_Record,
	cluster: Cluster,
	sector_offset: Sector_Offset,
	allocator := context.allocator,
) -> ([]Directory_Entry, bool) {
	buf: [SECTOR_SIZE]u8
	table_sector := Sector(u64(cluster) * master.cluster_size + u64(sector_offset))
	if !sector_read(disk, table_sector, buf[:]) {return nil, false}

	entries := (^[DIR_ENTRIES_PER_SECTOR]Directory_Entry)(raw_data(buf[:]))
	result := make([dynamic]Directory_Entry, 0, DIR_ENTRIES_PER_SECTOR, allocator)
	for i in 0 ..< DIR_ENTRIES_PER_SECTOR {
		if .Exists in entries[i].flags {
			append(&result, entries[i])
		}
	}
	return result[:], true
}

resolve_lfn :: proc(
	disk: ^os.File,
	master: ^Master_Record,
	entry: ^Directory_Entry,
	allocator := context.allocator,
) -> (string, bool) {
	if .LFN not_in entry.flags {
		n := 0
		for n < 16 && entry.file_name[n] != 0 {n += 1}
		return string(entry.file_name[:n]), true
	}

	ptr := (^LFN_Pointer)(raw_data(entry.file_name[:]))
	if ptr.cluster == 0 {return "", false}

	ce_buf: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
	if !read_cluster_entry_table(disk, master, Cluster(ptr.cluster), &ce_buf) {
		return "", false
	}

	target, target_found: Cluster_Entry
	for &t in ce_buf {
		if t.sector_start == ptr.sector && .Allocated in t.state {
			target = t; target_found = t; break
		}
	}
	if target_found.allocation_size == 0 {return "", false}

	data := make([dynamic]u8, 0, int(ptr.size), allocator)
	current_cluster := Cluster(ptr.cluster)
	current_entry  := target
	for {
		run_sector := Sector(u64(current_cluster) * master.cluster_size + u64(current_entry.sector_start))
		bytes_to_read := min(u64(current_entry.allocation_size) * SECTOR_SIZE, u64(ptr.size) - u64(len(data)))
		if bytes_to_read == 0 {break}

		temp := make([]u8, int(bytes_to_read), allocator)
		if !sector_read(disk, run_sector, temp) {return "", false}
		append(&data, ..temp)

		if current_entry.next_cluster == 0 {break}
		next, found_next := find_cluster_entry(
			disk, master,
			Cluster(current_entry.next_cluster),
			Sector_Offset(current_entry.next_sector_index),
		)

		if !found_next {break}
		current_cluster = Cluster(current_entry.next_cluster)
		current_entry  = next
	}
	if len(data) > int(ptr.size) {
		resize(&data, int(ptr.size))
	}
	return string(data[:]), true
}
