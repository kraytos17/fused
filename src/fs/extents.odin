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

// read_chain reads the full extent chain starting at (cluster, offset) into a
// contiguous buffer. The caller owns the returned slice and must delete it.
read_chain :: proc(vol: ^Volume, cluster: Cluster, offset: Sector_Offset, allocator := context.allocator) -> (data: []u8, err: FS_Error) {
	runs, rerr := resolve_extents(vol, cluster, offset)
	defer delete(runs)
	if rerr != .None {
		return {}, rerr
	}

	total := 0
	for r in runs {
		total += int(r.count) * SECTOR_SIZE
	}

	data = make([]u8, total, allocator)
	pos := 0
	for r in runs {
		for si in 0 ..< int(r.count) {
			if !sector_read(vol, Sector(u64(r.sector) + u64(si)), data[pos:pos + SECTOR_SIZE]) {
				delete(data, allocator)
				return {}, .Sector_Read_Error
			}
			pos += SECTOR_SIZE
		}
	}
	return data, .None
}

// write_chain writes a byte buffer across the extent chain starting at
// (cluster, offset). The final sector is zero-padded when the buffer is not
// sector-aligned. The chain must be large enough to hold len(data).
write_chain :: proc(vol: ^Volume, cluster: Cluster, offset: Sector_Offset, data: []u8) -> FS_Error {
	runs, rerr := resolve_extents(vol, cluster, offset)
	defer delete(runs)
	if rerr != .None {
		return rerr
	}

	pos := 0
	for r in runs {
		for si in 0 ..< int(r.count) {
			if pos >= len(data) {
				return .None
			}

			sec := Sector(u64(r.sector) + u64(si))
			if pos + SECTOR_SIZE <= len(data) {
				if !sector_write(vol, sec, data[pos:pos + SECTOR_SIZE]) {
					return .Sector_Write_Error
				}
			} else {
				buf: [SECTOR_SIZE]u8
				copy(buf[:], data[pos:])
				if !sector_write(vol, sec, buf[:]) {
					return .Sector_Write_Error
				}
			}
			pos += SECTOR_SIZE
		}
	}
	return .None
}

// walk_chain_sectors iterates the sectors of an extent chain, calling visit
// for each one. The visitor reads the sector itself and returns false to stop
// the walk early.
walk_chain_sectors :: proc(vol: ^Volume, cluster: Cluster, offset: Sector_Offset, visit: proc(sector: Sector, user: rawptr) -> bool, user: rawptr) -> FS_Error {
	runs, rerr := resolve_extents(vol, cluster, offset)
	defer delete(runs)
	if rerr != .None {
		return rerr
	}
	for r in runs {
		for si in 0 ..< int(r.count) {
			if !visit(Sector(u64(r.sector) + u64(si)), user) {
				return .None
			}
		}
	}
	return .None
}
