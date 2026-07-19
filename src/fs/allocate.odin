// allocate.odin — Sector allocator.
#+build linux
package fs

import "core:container/bit_array"
import "core:log"

// _find_contiguous_free scans a bitmap for `needed` consecutive free bits.
// Returns the start index, the run length, and whether enough space was found.
@private
_find_contiguous_free :: proc(bitmap: ^bit_array.Bit_Array, total_sectors: u64, needed: u16) -> (start: u16, available: u16, ok: bool) {
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

// _is_cluster_full checks whether every sector in the cluster bitmap is allocated.
@private
_is_cluster_full :: proc(bitmap: ^bit_array.Bit_Array, total_sectors: u64) -> bool {
	max_s := int(min(total_sectors, 65535))
	for s in 0 ..< max_s {
		if !bit_array.unsafe_get(bitmap, s) {
			return false
		}
	}
	return true
}

// _cluster_entry_state_for returns the Cluster_Entry_State corresponding to the
// given Allocation_Kind (e.g. Directory, File_Content, Cluster_Map, LFN).
@private
_cluster_entry_state_for :: proc(kind: Allocation_Kind) -> Cluster_Entry_State {
	switch kind {
	case .Directory:    return {.Directory}
	case .File_Content: return {.File_Content}
	case .Cluster_Map:  return {.Cluster_Map}
	case .LFN:          return {.LFN}
	}
	return {}
}

// allocate_sectors allocates contiguous sectors on a volume.
// 
// Extension logic: if start_cluster != 0, existing extents are resolved and
// their sector count is subtracted from sectors_needed to compute additional_needed.
// If the existing chain already covers the request, (start_cluster, start_offset) is
// returned immediately.
// 
// Cluster-map scan: starting from vol.cache.hint, each cluster-map entry is examined.
// Fresh (unallocated) clusters are initialised and zeroed. A per-cluster bitmap is
// consulted via _find_contiguous_free; if no run is found the CME is marked Full and
// skipped. An unused slot in the cluster-entry table is located and filled with a new
// Cluster_Entry carrying the allocation size, sector start, and state derived from kind.
// 
// Journal branching: v2 journals batch entries via journal_v2_add_entry; v6/v7 uses
// intent_txn_add. Both paths are finalised with a commit/finish once allocation succeeds
// (or rolled back via the deferred cleanup on error).
// 
// Tail-chain linking: when extending an existing chain (start_cluster != 0),
// link_tail_to_new walks the old chain and appends the first newly allocated cluster,
// persisting the updated predecessor entry.
// 
// Error returns: .Sector_Write_Error on I/O failure, .Entry_Not_Found if the tail
// cannot be located, or .No_Space when the cluster map is exhausted.
allocate_sectors :: proc(
	vol:            ^Volume,
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
		existing := resolve_extents(vol, start_cluster, start_offset) or_return
		defer delete(existing)

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

	is_v2 := .Journal_V2 in vol.master.features
	jrnl_txn_v6: Intent_Txn
	jrnl_ok := false
	jrnl_v2_txn: Journal_Txn

	if is_v2 {
		journal_v2_begin(&vol.master, &jrnl_v2_txn)
	} else {
		if !intent_log_begin(vol) {
			return 0, 0, .Sector_Write_Error
		}
	}
	defer if !jrnl_ok {
		if is_v2 {
			journal_v2_commit(vol, &jrnl_v2_txn)
			journal_v2_finish(vol, jrnl_v2_txn.seq)
		} else {
			intent_log_commit(vol, nil)
		}
	}

	start_hint := vol.cache.hint
	for iter in 0 ..< vol.master.cluster_map_size {
		cluster_idx := (start_hint + iter) % vol.master.cluster_map_size
		cme := read_cluster_map_entry(vol, Cluster(cluster_idx)) or_continue
		if .Reserved in cme.flags || .Full in cme.flags {
			continue
		}

		is_fresh := .Allocated not_in cme.flags
		if is_fresh {
			cme.flags += {.Allocated}
			cme.sector_index   = 0
			write_cluster_map_entry(vol, Cluster(cluster_idx), &cme) or_return

			zero_buf: [SECTOR_SIZE]u8
			table_sector := Sector(cluster_idx * vol.master.cluster_size + u64(cme.sector_index))
			if !sector_write(vol, table_sector, zero_buf[:]) {
				return 0, 0, .Sector_Write_Error
			}
		}

		bitmap, used, var_ok := alloc_cache_ensure(&vol.cache, vol, cluster_idx)
		if !var_ok {
			continue
		}

		free_start, free_avail, free_ok := _find_contiguous_free(&bitmap, vol.master.cluster_size, u16(min(remaining, 65535)))
		if !free_ok {
			if .Full not_in cme.flags {
				cme.flags += {.Full}
				write_cluster_map_entry(vol, Cluster(cluster_idx), &cme) or_return
			}
			continue
		}

		take := u16(min(u64(free_avail), remaining))
		if take == 0 {
			continue
		}

		table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
		read_cluster_entry_table(vol, Cluster(cluster_idx), &table) or_continue
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
			state             = _cluster_entry_state_for(kind) | {.Allocated},
			allocation_size   = take,
			sector_start      = free_start,
			next_cluster      = 0,
			next_sector_index = 0,
		}

		table[free_idx] = new_entry
		write_cluster_entry_table(vol, Cluster(cluster_idx), &table) or_return
		if is_v2 {
			journal_v2_add_entry(&jrnl_v2_txn, Journal_Entry{
				cluster           = cluster_idx,
				ce_index          = u8(free_idx),
				state             = transmute(u8)new_entry.state,
				sector_start      = free_start,
				alloc_size        = take,
				next_cluster      = new_entry.next_cluster,
				next_sector_index = new_entry.next_sector_index,
			})
		} else {
			intent_txn_add(&jrnl_txn_v6, cluster_idx, free_idx, take, transmute(u8)new_entry.state)
		}
		if is_first {
			first_cluster = Cluster(cluster_idx)
			first_offset  = Sector_Offset(free_start)
			is_first = false
		} else if prev_has_prev {
			prev_entry.next_cluster       = u64(cluster_idx)
			prev_entry.next_sector_index  = u16(free_start)
			prev_table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
			if read_cluster_entry_table(vol, prev_cluster, &prev_table) == .None {
				for &e in prev_table {
					if e.sector_start == u16(prev_offset) && .Allocated in e.state {
						e = prev_entry
						break
					}
				}

				write_cluster_entry_table(vol, prev_cluster, &prev_table) or_return
				if is_v2 {
					journal_v2_add_entry(&jrnl_v2_txn, Journal_Entry{
						cluster           = u64(prev_cluster),
						ce_index          = u8(prev_offset),
						state             = transmute(u8)prev_entry.state,
						sector_start      = prev_entry.sector_start,
						alloc_size        = prev_entry.allocation_size,
						next_cluster      = prev_entry.next_cluster,
						next_sector_index = prev_entry.next_sector_index,
					})
				} else {
					intent_txn_add(&jrnl_txn_v6, u64(prev_cluster), int(prev_offset), prev_entry.allocation_size, transmute(u8)prev_entry.state)
				}
			}
		}

		prev_cluster = Cluster(cluster_idx)
		prev_offset = Sector_Offset(free_start)
		prev_entry = new_entry
		prev_has_prev = true
		remaining -= u64(take)
		if used + take >= u16(vol.master.cluster_size) {
			if .Full not_in cme.flags {
				cme.flags += {.Full}
				write_cluster_map_entry(vol, Cluster(cluster_idx), &cme) or_return
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
		if !link_tail_to_new(vol, start_cluster, start_offset, first_cluster, first_offset) {
			return 0, 0, .Entry_Not_Found
		}

		vol.cache.hint = (u64(first_cluster) + 1) % vol.master.cluster_map_size
		jrnl_ok = true
		if is_v2 {
			journal_v2_commit(vol, &jrnl_v2_txn)
			journal_v2_finish(vol, jrnl_v2_txn.seq)
		} else {
			intent_log_commit(vol, jrnl_txn_v6.entries[:jrnl_txn_v6.count])
		}
		return start_cluster, start_offset, .None
	}

	log.debugf("allocate: ok — %d sectors across %d clusters", sectors_needed, first_cluster)
	vol.cache.hint = (u64(first_cluster) + 1) % vol.master.cluster_map_size
	jrnl_ok = true
	if is_v2 {
		journal_v2_commit(vol, &jrnl_v2_txn)
		journal_v2_finish(vol, jrnl_v2_txn.seq)
	} else {
		intent_log_commit(vol, jrnl_txn_v6.entries[:jrnl_txn_v6.count])
	}
	return first_cluster, first_offset, .None
}

// deallocate_sectors frees a chain of cluster entries starting at
// (start_cluster, start_offset). Each entry has its Allocated flag cleared;
// if the owning CME was marked Full, that flag is also removed. Deallocations
// are recorded in a v6 intent log for crash-consistency.
deallocate_sectors :: proc(
	vol:           ^Volume,
	start_cluster: Cluster,
	start_offset:  Sector_Offset,
) -> FS_Error {
	if start_cluster == 0 {
		return .None
	}

	dj_entries: [MAX_JOURNAL_ENTRIES_v6]Intent_Log_Entry
	dj_count := 0
	if !intent_log_begin(vol) {
		return .Sector_Write_Error
	}
	defer intent_log_commit(vol, dj_entries[:dj_count])

	current_cluster := start_cluster
	current_offset  := start_offset
	for guard in 0 ..< int(vol.master.cluster_map_size) + 1 {
		if guard == int(vol.master.cluster_map_size) {
			log.errorf("deallocate: chain too long (corrupted)")
			return .Entry_Not_Found
		}

		entry := find_cluster_entry(vol, current_cluster, current_offset) or_return
		entry.state -= {.Allocated}
		cme, cme_err := read_cluster_map_entry(vol, current_cluster)
		if cme_err == .None && .Full in cme.flags {
			cme.flags -= {.Full}
			write_cluster_map_entry(vol, current_cluster, &cme) or_return
		}

		table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
		read_cluster_entry_table(vol, current_cluster, &table) or_return
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

		write_cluster_entry_table(vol, current_cluster, &table) or_return
		if dj_count < MAX_JOURNAL_ENTRIES_v6 {
			dj_entries[dj_count] = Intent_Log_Entry{
				cluster    = u64(current_cluster),
				sector_offset = 0,
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

// link_tail_to_new walks the existing chain from (start_cluster, start_offset) to
// its final entry and sets its next_cluster / next_sector_index to point at
// (first_cluster, first_offset), effectively appending the newly allocated cluster(s).
link_tail_to_new :: proc(vol: ^Volume, start_cluster: Cluster, start_offset: Sector_Offset, first_cluster: Cluster, first_offset: Sector_Offset) -> bool {
	cursor := Chain_Cursor{start_cluster, start_offset}
	max_steps := int(vol.master.cluster_map_size) + 1
	for guard in 0 ..< max_steps {
		tail, tc, step := _chain_step(vol, &cursor, guard, max_steps)
		if step == .Corrupted {
			log.errorf("allocate: tail chain too long (corrupted)")
			return false
		}
		if tail.next_cluster == 0 {
			tail.next_cluster = u64(first_cluster)
			tail.next_sector_index = u16(first_offset)
			tail_table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
			if read_cluster_entry_table(vol, tc, &tail_table) == .None {
				for &e in tail_table {
					if e.sector_start == u16(cursor.offset) && .Allocated in e.state {
						e = tail
						break
					}
				}
				if write_cluster_entry_table(vol, tc, &tail_table) != .None {
					return false
				}
			}
			break
		}
	}
	return true
}
