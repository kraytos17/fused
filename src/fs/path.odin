// path.odin — Unified path-to-DirectoryEntry resolution.
#+build linux
package fs

import "core:strings"

// Resolved_Entry bundles a resolved Directory_Entry with its disk location.
Resolved_Entry :: struct {
	entry:       Directory_Entry,
	cluster:     Cluster,
	offset:      Sector_Offset,
	entry_index: int,
}

// resolve_path walks a path string through the directory tree and returns the final entry.
// It handles both short names and LFNs, parses components without heap allocation,
// and returns false if any intermediate path component is missing or not a directory.
resolve_path :: proc(vol: ^Volume, path: string, allocator := context.allocator) -> (res: Resolved_Entry, ok: bool) {
	if path == "/" || len(path) == 0 {
		res.entry = Directory_Entry{
			flags          = Dir_Flags{.Allocated, .Directory, .Exists},
			sector_index   = vol.master.root_sector_index,
			stored_cluster = vol.master.root_cluster,
		}

		res.cluster = Cluster(vol.master.root_cluster)
		res.offset  = Sector_Offset(vol.master.root_sector_index)
		return res, true
	}

	comps: [16]string
	n_comps := 0
	rest := path
	for comp in strings.split_by_byte_iterator(&rest, '/') {
		if len(comp) == 0 { continue }
		if n_comps >= len(comps) { return {}, false }
		comps[n_comps] = comp
		n_comps += 1
	}
	if n_comps == 0 {
		return resolve_path(vol, "/")
	}

	current_cluster := Cluster(vol.master.root_cluster)
	current_offset  := Sector_Offset(vol.master.root_sector_index)
	for comp_idx in 0 ..< n_comps {
		target  := comps[comp_idx]
		is_last := comp_idx == n_comps - 1
		dirs, dirs_err := read_directory_entries(vol, current_cluster, current_offset)
		defer delete(dirs)
		if dirs_err != .None { return {}, false }

		found := false
		for &d, didx in dirs {
			if entry_short_name(&d) == target {
				found = true
			}
			if !found && .LFN in d.flags {
				lfn_name, lfn_ok := resolve_lfn(vol, &d, context.temp_allocator)
				if lfn_ok && lfn_name == target {
					found = true
				}
			}
			if found {
				if is_last {
					return Resolved_Entry{d, current_cluster, current_offset, didx}, true
				}
				if .Directory not_in d.flags {
					return {}, false
				}

				current_cluster = Cluster(d.stored_cluster)
				current_offset  = Sector_Offset(d.sector_index)
				break
			}
		}
		if !found { return {}, false }
	}
	return {}, false
}
