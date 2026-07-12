// allocate.odin — Sector allocator.
//
// allocate_sectors scans the cluster map for free space, creates
// ClusterEntry runs, chains them, and writes everything back to disk.
// deallocate_sectors walks a chain and frees every entry.
//
// Uses an in-memory bitmap cache (g_alloc_cache) to avoid re-reading
// cluster entry tables from disk on every scan.
#+build linux
package fs

import "core:mem"
import "core:os"
import "core:log"

g_alloc_cache: Cluster_Bitmap_Cache

@private
bit_mark :: #force_inline proc(bitmap: []u8, sector: u16) {
	bitmap[sector / 8] |= 1 << (sector % 8)
}

@private
bit_isset :: #force_inline proc(bitmap: []u8, sector: u16) -> bool {
	return (bitmap[sector / 8] & (1 << (sector % 8))) != 0
}

@private
bit_clear :: #force_inline proc(bitmap: []u8, sector: u16) {
	bitmap[sector / 8] &= ~(1 << (sector % 8))
}

@private
find_contiguous_free :: proc(bitmap: []u8, total_sectors: u64, needed: u16) -> (start: u16, available: u16, ok: bool) {
	run_start: u16 = 0xFFFF
	run_len: u16 = 0
	for s in 0 ..< u16(total_sectors) {
		if bit_isset(bitmap, s) {
			if run_len > 0 && run_len >= needed {
				return run_start, run_len, true
			}
			run_start = 0xFFFF
			run_len = 0
		} else {
			if run_start == 0xFFFF {
				run_start = s
			}
			run_len += 1
			if run_len >= needed {
				return run_start, run_len, true
			}
		}
	}
	if run_len > 0 {
		return run_start, run_len, true
	}
	return 0, 0, false
}

@private
is_cluster_full :: proc(bitmap: []u8, total_sectors: u64) -> bool {
	for s in 0 ..< u16(total_sectors) {
		if !bit_isset(bitmap, s) {
			return false
		}
	}
	return true
}

@private
cluster_entry_state_for :: proc(kind: Allocation_Kind) -> Cluster_Entry_State {
	switch kind {
	case .Directory:    return {.Directory}
	case .File_Content: return {.File_Content}
	case .Cluster_Map:  return {.Cluster_Map}
	case .LFN:          return {.LFN}
	}
	return {}
}

allocate_sectors :: proc(
	master:         ^Master_Record,
	disk:           ^os.File,
	start_cluster:  Cluster,
	start_offset:   Sector_Offset,
	sectors_needed: u64,
	kind:           Allocation_Kind,
) -> (first_cluster: Cluster, first_offset: Sector_Offset, err: FS_Error) {
	if sectors_needed == 0 {
		return start_cluster, start_offset, .None
	}

	additional_needed: u64 = sectors_needed
	if start_cluster != 0 {
		existing, ext_ok := resolve_extents(disk, master, start_cluster, start_offset)
		if !ext_ok {
			return 0, 0, .Entry_Not_Found
		}

		existing_sectors: u64
		for r in existing {
			existing_sectors += u64(r.count)
		}
		if sectors_needed <= existing_sectors {
			return start_cluster, start_offset, .None
		}
		additional_needed = sectors_needed - existing_sectors
	}

	remaining: u64 = additional_needed
	is_first := true
	prev_cluster: Cluster
	prev_offset:  Sector_Offset
	prev_entry:   Cluster_Entry
	prev_has_prev := false

	cache_init := len(g_alloc_cache.bitmaps) > 0
	start_hint := g_alloc_cache.hint if cache_init else 0
	for iter in 0 ..< master.cluster_map_size {
		cluster_idx := (start_hint + iter) %
		master.cluster_map_size if cache_init else iter

		cme := read_cluster_map_entry(disk, master, Cluster(cluster_idx)) or_continue
		if .Reserved in cme.flags || .Full in cme.flags {
			continue
		}

		is_fresh := .Allocated not_in cme.flags
		if is_fresh {
			cme.flags += {.Allocated}
			cme.stored_cluster = u64(cluster_idx)
			cme.sector_index   = 0
			if !write_cluster_map_entry(disk, master, Cluster(cluster_idx), &cme) {
				return 0, 0, .Sector_Write_Error
			}

			zero_buf: [SECTOR_SIZE]u8
			table_sector := Sector(u64(cme.stored_cluster) * master.cluster_size + u64(cme.sector_index))
			if !sector_write(disk, table_sector, zero_buf[:]) {
				return 0, 0, .Sector_Write_Error
			}
			if cache_init {
				alloc_cache_invalidate(&g_alloc_cache, cluster_idx)
			}
		}

		bitmap: []u8
		if cache_init {
			bitmap = alloc_cache_get(&g_alloc_cache, master, disk, cluster_idx)
			if len(bitmap) == 0 {
				continue
			}
		} else {
			local_bitmap: [DEFAULT_CLUSTER_SIZE]u8
			bitmap_len := max(1, int((master.cluster_size + 7) / 8))
			bitmap = local_bitmap[:bitmap_len]
			mem.zero_slice(bitmap)

			bit_mark(bitmap, cme.sector_index)
			table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
			if read_cluster_entry_table(disk, master, Cluster(cluster_idx), &table) {
				for &e in table {
					if .Allocated in e.state {
						for off in 0 ..< e.allocation_size {
							bit_mark(bitmap, e.sector_start + off)
						}
					}
				}
			}
		}

		used: u16 = 0
		table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
		if read_cluster_entry_table(disk, master, Cluster(cluster_idx), &table) {
			for &e in table {
				if .Allocated in e.state {
					used += e.allocation_size
				}
			}
		}

		free_start, free_avail, free_ok := find_contiguous_free(bitmap, master.cluster_size, u16(min(remaining, 65535)))
		if !free_ok {
			if .Full not_in cme.flags {
				cme.flags += {.Full}
				if !write_cluster_map_entry(disk, master, Cluster(cluster_idx), &cme) {
					return 0, 0, .Sector_Write_Error
				}
			}
			continue
		}

		take := u16(min(u64(free_avail), remaining))
		if take == 0 {
			continue
		}

		free_idx := -1
		#unroll for j in 0 ..< CLUSTER_ENTRIES_PER_SECTOR {
			if free_idx < 0 && .Allocated not_in table[j].state {
				free_idx = j
			}
		}
		if free_idx < 0 {
			continue
		}

		new_entry := Cluster_Entry{
			state             = cluster_entry_state_for(kind) | {.Allocated},
			allocation_size   = take,
			sector_start      = free_start,
			next_cluster      = 0,
			next_sector_index = 0,
		}

		table[free_idx] = new_entry
		if !write_cluster_entry_table(disk, master, Cluster(cluster_idx), &table) {
			return 0, 0, .Sector_Write_Error
		}

		alloc_cache_invalidate(&g_alloc_cache, cluster_idx)
		if is_first {
			first_cluster = Cluster(cluster_idx)
			first_offset  = Sector_Offset(free_start)
			is_first = false
		} else if prev_has_prev {
			prev_entry.next_cluster       = u64(cluster_idx)
			prev_entry.next_sector_index  = u16(free_start)
			prev_table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
			if read_cluster_entry_table(disk, master, prev_cluster, &prev_table) {
				for &e in prev_table {
					if e.sector_start == u16(prev_offset) && .Allocated in e.state {
						e = prev_entry
						break
					}
				}
				if !write_cluster_entry_table(disk, master, prev_cluster, &prev_table) {
					return 0, 0, .Sector_Write_Error
				}
				alloc_cache_invalidate(&g_alloc_cache, u64(prev_cluster))
			}
		}

		prev_cluster = Cluster(cluster_idx)
		prev_offset  = Sector_Offset(free_start)
		prev_entry   = new_entry
		prev_has_prev = true
		remaining   -= u64(take)
		if used + take >= u16(master.cluster_size) {
			if .Full not_in cme.flags {
				cme.flags += {.Full}
				if !write_cluster_map_entry(disk, master, Cluster(cluster_idx), &cme) {
					return 0, 0, .Sector_Write_Error
				}
			}
		}
		if remaining == 0 {
			break
		}
	}
	if remaining > 0 {
		log.errorf("allocate: No_Space — needed %d, %d remaining", sectors_needed, remaining)
		return 0, 0, .No_Space
	}
	if start_cluster != 0 && !is_first {
		tail_cluster := start_cluster
		tail_offset  := start_offset
		for guard in 0 ..< int(master.cluster_map_size) + 1 {
			if guard == int(master.cluster_map_size) {
				log.errorf("allocate: tail chain too long (corrupted)")
				return 0, 0, .Entry_Not_Found
			}

			tail, tail_ok := find_cluster_entry(disk, master, tail_cluster, tail_offset)
			if !tail_ok {
				break
			}
			if tail.next_cluster == 0 {
				tail.next_cluster = u64(first_cluster)
				tail.next_sector_index = u16(first_offset)
				tail_table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
				if read_cluster_entry_table(disk, master, tail_cluster, &tail_table) {
					for &e in tail_table {
						if e.sector_start == u16(tail_offset) && .Allocated in e.state {
							e = tail
							break
						}
					}
					if !write_cluster_entry_table(disk, master, tail_cluster, &tail_table) {
						return 0, 0, .Sector_Write_Error
					}
				}
				break
			}
			tail_cluster = Cluster(tail.next_cluster)
			tail_offset  = Sector_Offset(tail.next_sector_index)
		}
		// Update hint to start scanning past this cluster next time
		if len(g_alloc_cache.bitmaps) > 0 {
			g_alloc_cache.hint = (u64(first_cluster) + 1) % master.cluster_map_size
		}
		return start_cluster, start_offset, .None
	}

	log.debugf("allocate: ok — %d sectors across %d clusters", sectors_needed, first_cluster)
	if len(g_alloc_cache.bitmaps) > 0 {
		g_alloc_cache.hint = (u64(first_cluster) + 1) % master.cluster_map_size
	}
	return first_cluster, first_offset, .None
}

deallocate_sectors :: proc(
	master:        ^Master_Record,
	disk:          ^os.File,
	start_cluster: Cluster,
	start_offset:  Sector_Offset,
) -> FS_Error {
	if start_cluster == 0 {
		return .None
	}

	current_cluster := start_cluster
	current_offset  := start_offset
	for guard in 0 ..< int(master.cluster_map_size) + 1 {
		if guard == int(master.cluster_map_size) {
			log.errorf("deallocate: chain too long (corrupted)")
			return .Entry_Not_Found
		}

		entry, ok := find_cluster_entry(disk, master, current_cluster, current_offset)
		if !ok {
			return .Entry_Not_Found
		}

		entry.state -= {.Allocated}
		cme, cme_ok := read_cluster_map_entry(disk, master, current_cluster)
		if cme_ok && .Full in cme.flags {
			cme.flags -= {.Full}
			if !write_cluster_map_entry(disk, master, current_cluster, &cme) {
				return .Sector_Write_Error
			}
		}

		table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
		if !read_cluster_entry_table(disk, master, current_cluster, &table) {
			return .Sector_Read_Error
		}
		for &e in table {
			if e.sector_start == u16(current_offset) {
				e = entry; break
			}
		}
		if !write_cluster_entry_table(disk, master, current_cluster, &table) {
			return .Sector_Write_Error
		}
		if len(g_alloc_cache.bitmaps) > 0 {
			alloc_cache_invalidate(&g_alloc_cache, u64(current_cluster))
		}
		if entry.next_cluster == 0 {
			break
		}
		current_cluster = Cluster(entry.next_cluster)
		current_offset  = Sector_Offset(entry.next_sector_index)
	}
	log.debugf("deallocate: ok — cluster=%d offset=%d", start_cluster, start_offset)
	return .None
}
