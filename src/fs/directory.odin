// directory.odin — Directory entry iteration and LFN resolution.
#+build linux
package fs

import "core:os"
import "core:log"

entry_short_name :: proc "contextless" (entry: ^Directory_Entry) -> string {
	n := 0
	for n < 16 && entry.file_name[n] != 0 {
		n += 1
	}
	return string(entry.file_name[:n])
}

read_directory_entries :: proc(
	disk: ^os.File,
	master: ^Master_Record,
	cluster: Cluster,
	sector_offset: Sector_Offset,
) -> (entries: [dynamic; DIR_ENTRIES_PER_SECTOR]Directory_Entry, ok: bool) {
	buf: [SECTOR_SIZE]u8
	table_sector := Sector(u64(cluster) * master.cluster_size + u64(sector_offset))
	if !sector_read(disk, table_sector, buf[:]) {
		return {}, false
	}

	raw := (^[DIR_ENTRIES_PER_SECTOR]Directory_Entry)(raw_data(buf[:]))
	#unroll for i in 0 ..< DIR_ENTRIES_PER_SECTOR {
		if .Exists in raw[i].flags {append(&entries, raw[i])}
	}
	return entries, true
}

resolve_lfn :: proc(
	disk: ^os.File,
	master: ^Master_Record,
	entry: ^Directory_Entry,
	allocator := context.allocator,
) -> (name: string, ok: bool) {
	if .LFN not_in entry.flags {
		return entry_short_name(entry), true
	}

	ptr := (^LFN_Pointer)(raw_data(entry.file_name[:]))
	if ptr.cluster == 0 {
		return "", false
	}

	ce_buf: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
	read_cluster_entry_table(disk, master, Cluster(ptr.cluster), &ce_buf) or_return
	target: Cluster_Entry
	for &t in ce_buf {
		if t.sector_start == ptr.sector && .Allocated in t.state {
			target = t
			break
		}
	}
	if target.allocation_size == 0 {
		return "", false
	}

	data := make([dynamic]u8, 0, int(ptr.size), allocator)
	sector_buf: [SECTOR_SIZE]u8
	current_cluster := Cluster(ptr.cluster)
	current_entry  := target
	byte_offset := u64(ptr._pad)
	max_steps := int(master.cluster_map_size) + 1
	for guard in 0 ..< max_steps {
		if guard == max_steps - 1 {
			log.errorf("resolve_lfn: chain too long (corrupted)")
			return "", false
		}

		run_sector := Sector(u64(current_cluster) * master.cluster_size + u64(current_entry.sector_start))
		bytes_to_read := min(u64(current_entry.allocation_size) * SECTOR_SIZE, u64(ptr.size) - u64(len(data)))
		if bytes_to_read == 0 {
			break
		}

		n_read := min(bytes_to_read, SECTOR_SIZE - byte_offset)
		if !sector_read(disk, run_sector, sector_buf[:]) {
			return "", false
		}

		append(&data, ..sector_buf[byte_offset:][:n_read])
		byte_offset = 0 // only apply on first sector
		if current_entry.next_cluster == 0 {
			break
		}

		next, found_next := find_cluster_entry(
			disk, master,
			Cluster(current_entry.next_cluster),
			Sector_Offset(current_entry.next_sector_index),
		)
		if !found_next {
			break
		}
		current_cluster = Cluster(current_entry.next_cluster)
		current_entry  = next
	}
	if len(data) > int(ptr.size) {
		resize(&data, int(ptr.size))
	}
	return string(data[:]), true
}

write_directory_entry_at :: proc(
	disk: ^os.File, master: ^Master_Record,
	cluster: Cluster, sector_offset: Sector_Offset,
	entry_index: int, entry: ^Directory_Entry,
) -> bool {
	buf: [SECTOR_SIZE]u8
	table_sector := Sector(u64(cluster) * master.cluster_size + u64(sector_offset))
	if !sector_read(disk, table_sector, buf[:]) {
		return false
	}

	raw := (^[DIR_ENTRIES_PER_SECTOR]Directory_Entry)(raw_data(buf[:]))
	raw[entry_index] = entry^
	return sector_write(disk, table_sector, buf[:])
}
