// resolve.odin — Path resolution and symlink target reader.
#+build linux
package main

import "core:strings"
import "src:fs"

// resolve_file resolves a path string to a Directory_Entry (thin wrapper around fs.resolve_path).
resolve_file :: proc(vol: ^fs.Volume, path: string) -> (entry: fs.Directory_Entry, cluster: fs.Cluster, offset: fs.Sector_Offset, entry_index: int, ok: bool) {
	res, rok := fs.resolve_path(vol, path)
	if !rok { return }
	return res.entry, res.cluster, res.offset, res.entry_index, true
}

// resolve_symlink_target reads and returns the content of a symbolic link.
resolve_symlink_target :: proc(vol: ^fs.Volume, entry: ^fs.Directory_Entry, allocator := context.allocator) -> string {
	if .Link not_in entry.flags { return "" }
	if entry.stored_cluster == 0 { return "" }

	runs, ext_err := fs.resolve_extents(vol, fs.Cluster(entry.stored_cluster), fs.Sector_Offset(entry.sector_index))
	if ext_err != .None { return "" }

	sb: strings.Builder
	strings.builder_init(&sb, allocator)
	defer strings.builder_destroy(&sb)

	remaining := entry.file_size
	for run in runs {
		if remaining == 0 { break }
		for si: u64; si < u64(run.count); si += 1 {
			if remaining == 0 { break }

			sec := fs.Sector(u64(run.sector) + si)
			sec_buf: [fs.SECTOR_SIZE]u8
			if !fs.sector_read(vol, sec, sec_buf[:]) { return "" }

			n := min(remaining, fs.SECTOR_SIZE)
			strings.write_string(&sb, string(sec_buf[:n]))
			remaining -= n
		}
	}
	return strings.to_string(sb)
}
