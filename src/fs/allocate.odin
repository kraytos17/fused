// allocate.odin — Sector allocator.
//
// allocate_sectors scans the cluster map for free space, creates
// ClusterEntry runs, chains them, and writes everything back to disk.
// deallocate_sectors walks a chain and frees every entry.
//
// Uses an explicit Cluster_Bitmap_Cache to avoid re-reading cluster
// entry tables from disk on every scan. Pass nil to use a stack-local
// fallback (no caching).
#+build linux
package fs

import "core:container/bit_array"
import "core:os"
import "core:log"

@private
find_contiguous_free :: proc(bitmap: ^bit_array.Bit_Array, total_sectors: u64, needed: u16) -> (start: u16, available: u16, ok: bool) {
	run_start: u16 = 0xFFFF
	run_len: u16 = 0
	max_s := int(min(total_sectors, 65535))
	for s in 0 ..< max_s {
		if bit_array.unsafe_get(bitmap, s) {
			if run_len > 0 && run_len >= needed {
				return run_start, run_len, true
			}
			run_start = 0xFFFF
			run_len = 0
		} else {
			if run_start == 0xFFFF {
				run_start = u16(s)
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
is_cluster_full :: proc(bitmap: ^bit_array.Bit_Array, total_sectors: u64) -> bool {
	max_s := int(min(total_sectors, 65535))
	for s in 0 ..< max_s {
		if !bit_array.unsafe_get(bitmap, s) {
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

@private
get_bitmap_fallback :: proc(bitmap: ^bit_array.Bit_Array, master: ^Master_Record, disk: ^os.File, cluster: Cluster, cme: ^Cluster_Map_Entry) {
	bit_array.clear(bitmap)
	bit_array.unsafe_set(bitmap, int(cme.sector_index))
	table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
	if read_cluster_entry_table(disk, master, cluster, &table) {
		for &e in table {
			if .Allocated in e.state {
				for off in 0 ..< e.allocation_size {
					bit_array.unsafe_set(bitmap, int(e.sector_start + off))
				}
			}
		}
	}
}

allocate_sectors :: proc(
	master:         ^Master_Record,
	disk:           ^os.File,
	cache:          ^Cluster_Bitmap_Cache,
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
		defer delete(existing)
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

	// Journal: determine which journaling path to use.
	is_v2 := .Journal_V2 in transmute(Features)master.features

	jrnl_entries_v6: [MAX_JOURNAL_ENTRIES_v6]Intent_Log_Entry
	jrnl_count := 0
	jrnl_ok := false
	jrnl_v2_txn: Journal_Txn

	if is_v2 {
		journal_v2_begin(master, &jrnl_v2_txn)
	} else {
		if !intent_log_begin(disk, master) {
			return 0, 0, .Sector_Write_Error
		}
	}
	defer if !jrnl_ok {
		if is_v2 {
			journal_v2_commit(disk, master, &jrnl_v2_txn)
			journal_v2_finish(disk, master, jrnl_v2_txn.seq)
		} else {
			intent_log_commit(disk, master, nil)
		}
	}

	// Track a CE-table write in the journal.
	journal_add_ce_v6 :: proc(entries: ^[MAX_JOURNAL_ENTRIES_v6]Intent_Log_Entry, count: ^int, cluster_idx: u64, free_idx: int, take: u16, state: u8) {
		if count^ >= MAX_JOURNAL_ENTRIES_v6 { return }
		entries[count^] = Intent_Log_Entry{
			cluster       = cluster_idx,
			ce_index      = u8(free_idx),
			alloc_size    = take,
			state         = state,
		}
		count^ += 1
	}
	journal_add_ce_v2 :: proc(txn: ^Journal_Txn, cluster_idx: u64, free_idx: int, take: u16, sector_start: u16, state: u8, next_cluster: u64, next_si: u16) {
		journal_v2_add_entry(txn, Journal_Entry{
			cluster           = cluster_idx,
			ce_index          = u8(free_idx),
			state             = state,
			sector_start      = sector_start,
			alloc_size        = take,
			next_cluster      = next_cluster,
			next_sector_index = next_si,
		})
	}

	cache_init := cache != nil
	start_hint := cache.hint if cache_init else 0
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
			cme.sector_index   = 0
			if !write_cluster_map_entry(disk, master, Cluster(cluster_idx), &cme, cache) {
				return 0, 0, .Sector_Write_Error
			}

			zero_buf: [SECTOR_SIZE]u8
			table_sector := Sector(cluster_idx * master.cluster_size + u64(cme.sector_index))
			if !sector_write(disk, table_sector, zero_buf[:]) {
				return 0, 0, .Sector_Write_Error
			}
		}

		bitmap: bit_array.Bit_Array
		used: u16 = 0
		if cache_init {
			var_bitmap, var_used, var_ok := alloc_cache_ensure(cache, master, disk, cluster_idx)
			if !var_ok {
				continue
			}
			bitmap = var_bitmap
			used = var_used
		} else {
			bit_array.init(&bitmap, int(master.cluster_size), 0, context.temp_allocator)
			get_bitmap_fallback(&bitmap, master, disk, Cluster(cluster_idx), &cme)
		}

		free_start, free_avail, free_ok := find_contiguous_free(&bitmap, master.cluster_size, u16(min(remaining, 65535)))
		if !free_ok {
			if .Full not_in cme.flags {
				cme.flags += {.Full}
				if !write_cluster_map_entry(disk, master, Cluster(cluster_idx), &cme, cache) {
					return 0, 0, .Sector_Write_Error
				}
			}
			continue
		}

		take := u16(min(u64(free_avail), remaining))
		if take == 0 {
			continue
		}

		table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
		if !read_cluster_entry_table(disk, master, Cluster(cluster_idx), &table) {
			continue
		}
		if !cache_init {
			used = 0
			for &e in table {
				if .Allocated in e.state {
					used += e.allocation_size
				}
			}
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
		if !write_cluster_entry_table(disk, master, Cluster(cluster_idx), &table, cache) {
			return 0, 0, .Sector_Write_Error
		}

		if is_v2 {
			journal_add_ce_v2(&jrnl_v2_txn, cluster_idx, free_idx, take, free_start, transmute(u8)new_entry.state, new_entry.next_cluster, new_entry.next_sector_index)
		} else {
			journal_add_ce_v6(&jrnl_entries_v6, &jrnl_count, cluster_idx, free_idx, take, transmute(u8)new_entry.state)
		}
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
				if !write_cluster_entry_table(disk, master, prev_cluster, &prev_table, cache) {
					return 0, 0, .Sector_Write_Error
				}
				if is_v2 {
					journal_add_ce_v2(&jrnl_v2_txn, u64(prev_cluster), int(prev_offset), prev_entry.allocation_size, prev_entry.sector_start, transmute(u8)prev_entry.state, prev_entry.next_cluster, prev_entry.next_sector_index)
				} else {
					journal_add_ce_v6(&jrnl_entries_v6, &jrnl_count, u64(prev_cluster), int(prev_offset), prev_entry.allocation_size, transmute(u8)prev_entry.state)
				}
			}
		}

		prev_cluster = Cluster(cluster_idx)
		prev_offset = Sector_Offset(free_start)
		prev_entry = new_entry
		prev_has_prev = true
		remaining -= u64(take)
		if used + take >= u16(master.cluster_size) {
			if .Full not_in cme.flags {
				cme.flags += {.Full}
				if !write_cluster_map_entry(disk, master, Cluster(cluster_idx), &cme, cache) {
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
		cursor := Chain_Cursor{start_cluster, start_offset}
		max_steps := int(master.cluster_map_size) + 1
		for guard in 0 ..< max_steps {
			tail, tc, step := chain_step(disk, master, &cursor, guard, max_steps)
			if step == .Corrupted {
				log.errorf("allocate: tail chain too long (corrupted)")
				return 0, 0, .Entry_Not_Found
			}
			if tail.next_cluster == 0 {
				tail.next_cluster = u64(first_cluster)
				tail.next_sector_index = u16(first_offset)
				tail_table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
				if read_cluster_entry_table(disk, master, tc, &tail_table) {
					for &e in tail_table {
						if e.sector_start == u16(cursor.offset) && .Allocated in e.state {
							e = tail
							break
						}
					}
					if !write_cluster_entry_table(disk, master, tc, &tail_table, cache) {
						return 0, 0, .Sector_Write_Error
					}
				}
				break
			}
		}
		if cache_init {
			cache.hint = (u64(first_cluster) + 1) % master.cluster_map_size
		}

		jrnl_ok = true
		if is_v2 {
			journal_v2_commit(disk, master, &jrnl_v2_txn)
			journal_v2_finish(disk, master, jrnl_v2_txn.seq)
		} else {
			intent_log_commit(disk, master, jrnl_entries_v6[:jrnl_count])
		}
		return start_cluster, start_offset, .None
	}

	log.debugf("allocate: ok — %d sectors across %d clusters", sectors_needed, first_cluster)
	if cache_init {
		cache.hint = (u64(first_cluster) + 1) % master.cluster_map_size
	}

	jrnl_ok = true
	if is_v2 {
		journal_v2_commit(disk, master, &jrnl_v2_txn)
		journal_v2_finish(disk, master, jrnl_v2_txn.seq)
	} else {
		intent_log_commit(disk, master, jrnl_entries_v6[:jrnl_count])
	}
	return first_cluster, first_offset, .None
}

deallocate_sectors :: proc(
	master:        ^Master_Record,
	disk:          ^os.File,
	cache:         ^Cluster_Bitmap_Cache,
	start_cluster: Cluster,
	start_offset:  Sector_Offset,
) -> FS_Error {
	if start_cluster == 0 {
		return .None
	}

	dj_entries: [MAX_JOURNAL_ENTRIES_v6]Intent_Log_Entry
	dj_count := 0
	if !intent_log_begin(disk, master) {
		return .Sector_Write_Error
	}
	defer intent_log_commit(disk, master, dj_entries[:dj_count])

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
			if !write_cluster_map_entry(disk, master, current_cluster, &cme, cache) {
				return .Sector_Write_Error
			}
		}

		table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
		if !read_cluster_entry_table(disk, master, current_cluster, &table) {
			return .Sector_Read_Error
		}

		freed_idx: int = -1
		for &e, ei in table {
			if e.sector_start == u16(current_offset) {
				e = entry
				freed_idx = ei
				break
			}
		}
		if freed_idx < 0 {
			return .Entry_Not_Found
		}
		if !write_cluster_entry_table(disk, master, current_cluster, &table, cache) {
			return .Sector_Write_Error
		}
		if dj_count < MAX_JOURNAL_ENTRIES_v6 {
			dj_entries[dj_count] = Intent_Log_Entry{
				cluster    = u64(current_cluster),
				ce_index   = u8(freed_idx),
				alloc_size = 0,
				state      = 0,
			}
			dj_count += 1
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
