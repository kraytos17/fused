// resolve.odin — Path resolution and symlink target reader.
#+build linux
package main

import "core:os"
import "core:strings"
import "src:fs"

resolve_file :: proc(fd: ^os.File, m: ^fs.Master_Record, path: string) -> (entry: fs.Directory_Entry, cluster: fs.Cluster, offset: fs.Sector_Offset, entry_index: int, ok: bool) {
	if path == "/" || path == "" {
		entry = {flags = {.Allocated, .Directory, .Exists}}
		return entry, fs.Cluster(m.root_cluster), fs.Sector_Offset(m.root_sector_index), 0, true
	}

	comp_list := strings.split(path, "/")
	current_c := fs.Cluster(m.root_cluster)
	current_o := fs.Sector_Offset(m.root_sector_index)
	for comp_idx in 0 ..< len(comp_list) {
		comp := comp_list[comp_idx]
		if comp == "" { continue }

		is_last := comp_idx == len(comp_list) - 1
		dirs, dirs_ok := fs.read_directory_entries(fd, m, current_c, current_o)
		if !dirs_ok { return }

		found := false
		for &d, didx in dirs {
			if fs.entry_short_name(&d) != comp { continue }
			found = true
			if is_last { return d, current_c, current_o, didx, true }
			if .Directory not_in d.flags { return }
			current_c = fs.Cluster(d.stored_cluster)
			current_o = fs.Sector_Offset(d.sector_index)
			break
		}
		if !found { return }
	}
	return
}

resolve_symlink_target :: proc(fd: ^os.File, m: ^fs.Master_Record, entry: ^fs.Directory_Entry, allocator := context.allocator) -> string {
	if .Link not_in entry.flags { return "" }
	if entry.stored_cluster == 0 { return "" }

	runs, rok := fs.resolve_extents(fd, m, fs.Cluster(entry.stored_cluster), fs.Sector_Offset(entry.sector_index))
	if !rok { return "" }

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
			if !fs.sector_read(fd, sec, sec_buf[:]) { return "" }

			n := min(remaining, fs.SECTOR_SIZE)
			strings.write_string(&sb, string(sec_buf[:n]))
			remaining -= n
		}
	}
	return strings.to_string(sb)
}
