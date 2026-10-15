// resolve.odin — Path resolution and symlink target reader.
#+build linux
package main

import "core:strings"
import "src:fs"

// resolve_file resolves a path string to a Directory_Entry (thin wrapper around fs.resolve_path).
resolve_file :: proc(
	vol: ^fs.Volume,
	path: string,
) -> (
	entry: fs.Directory_Entry,
	cluster: fs.Cluster,
	offset: fs.Sector_Offset,
	entry_index: int,
	err: fs.FS_Error,
) {
	res, rerr := fs.resolve_path(vol, path)
	if rerr != .None { return {}, 0, 0, 0, rerr }
	return res.entry, res.cluster, res.offset, res.entry_index, .None
}

// resolve_symlink_target reads and returns the content of a symbolic link.
resolve_symlink_target :: proc(
	vol: ^fs.Volume,
	entry: ^fs.Directory_Entry,
	allocator := context.allocator,
) -> string {
	if .Link not_in entry.flags { return "" }
	if entry.stored_cluster == 0 { return "" }

	runs, ext_err := fs.resolve_extents(vol, fs.data_chain_of(entry^))
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
			if fs.sector_read(vol, sec, sec_buf[:]) != .None { return "" }

			n := min(remaining, fs.SECTOR_SIZE)
			strings.write_string(&sb, string(sec_buf[:n]))
			remaining -= n
		}
	}
	return strings.to_string(sb)
}

// dir_entry_at returns the entry at index idx in a sector buffer with
// per-entry stride des.
dir_entry_at :: #force_inline proc(buf: []u8, idx: int, des: int) -> ^fs.Directory_Entry {
	return (^fs.Directory_Entry)(&buf[idx * des])
}

// entry_kind classifies an entry for display.
entry_kind :: proc(e: ^fs.Directory_Entry) -> string {
	if .Directory in e.flags { return "DIR" }
	if .Link in e.flags { return "LINK" }
	return "FILE"
}

// entry_display_name returns the LFN when present, else the short name.
// Borrowed: valid while the sector buffer lives; clone to keep.
entry_display_name :: proc(vol: ^fs.Volume, e: ^fs.Directory_Entry) -> string {
	name := fs.entry_short_name(e)
	if .LFN in e.flags {
		if lfn, lfn_ok := fs.resolve_lfn(vol, e); lfn_ok {
			name = lfn
		}
	}
	return name
}
