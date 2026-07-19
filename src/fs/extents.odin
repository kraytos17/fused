// extents.odin — Extent chain walker.
#+build linux
package fs

// resolve_extents walks a cluster-entry chain and returns a flat list of extent runs.
resolve_extents :: proc(vol: ^Volume, start_cluster: Cluster, start_offset: Sector_Offset) -> (runs: [dynamic]Extent_Run, err: FS_Error) {
	if start_cluster == 0 {
		return {}, .Entry_Not_Found
	}

	stack_buf: [32]Extent_Run
	n := 0
	on_heap := false
	cursor := Chain_Cursor{start_cluster, start_offset}
	cluster_size := u64(vol.master.cluster_size)
	max_steps := int(vol.master.cluster_map_size) + 1
	for guard in 0 ..< max_steps {
		entry, ec, step := _chain_step(vol, &cursor, guard, max_steps)
		if step == .Corrupted {
			if on_heap { delete(runs) }
			return {}, .Entry_Not_Found
		}

		er := Extent_Run{
			Sector(u64(ec) * cluster_size + u64(entry.sector_start)),
			entry.allocation_size,
		}

		if on_heap {
			append(&runs, er)
		} else if n < len(stack_buf) {
			stack_buf[n] = er
			n += 1
		} else {
			runs = make([dynamic]Extent_Run, n, n * 2, context.temp_allocator)
			copy(runs[:], stack_buf[:n])
			on_heap = true
			append(&runs, er)
		}
		if step == .At_End { break }
	}
	if !on_heap {
		runs = make([dynamic]Extent_Run, n, n, context.temp_allocator)
		copy(runs[:], stack_buf[:n])
	}
	return runs, .None
}
