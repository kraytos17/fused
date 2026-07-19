// json.odin — JSON output builder for the image dumper.
#+build linux
package main

import "core:fmt"
import "core:strings"
import "src:fs"

// ClusterJSON represents a single cluster entry for JSON output.
ClusterJSON :: struct {
	// idx is the cluster index.
	idx:          int,
	// flags is the human-readable flags string.
	flags:        string,
	// sector_index is the sector offset within the cluster.
	sector_index: u16,
}

// EntryJSON represents a directory entry for JSON output.
EntryJSON :: struct {
	kind:     string,
	size:     u64,
	cluster:  u64,
	sector:   u16,
	dt:       string,
	target:   string,
	children: map[string]EntryJSON,
}

// json_escape_string escapes a string for safe JSON output.
json_escape_string :: proc(sb: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		b := u8(s[i])
		switch b {
		case '"':  strings.write_string(sb, `\"`)
		case '\\': strings.write_string(sb, `\\`)
		case '\b': strings.write_string(sb, `\b`)
		case '\f': strings.write_string(sb, `\f`)
		case '\n': strings.write_string(sb, `\n`)
		case '\r': strings.write_string(sb, `\r`)
		case '\t': strings.write_string(sb, `\t`)
		case:
			if b < 0x20 || b >= 0x7f {
				fmt.sbprintf(sb, "\\u%04x", u32(b))
			} else {
				strings.write_byte(sb, b)
			}
		}
	}
}

// json_write_entry writes a single directory entry (with optional children) as JSON.
json_write_entry :: proc(sb: ^strings.Builder, name: string, entry: EntryJSON) {
	strings.write_byte(sb, '"')
	json_escape_string(sb, name)
	fmt.sbprintf(sb, `":{{"kind":"%s","size":%d,"cluster":%d,"sector":%d,"dt":"`,
		entry.kind, entry.size, entry.cluster, entry.sector)
	json_escape_string(sb, entry.dt)
	strings.write_byte(sb, '"')

	if entry.target != "" {
		fmt.sbprintf(sb, `,"target":"`)
		json_escape_string(sb, entry.target)
		strings.write_byte(sb, '"')
	}

	if entry.children != nil {
		fmt.sbprintf(sb, `,"children":{{`)
		first := true
		for child_name, child_entry in entry.children {
			if !first { strings.write_byte(sb, ',') }
			first = false
			json_write_entry(sb, child_name, child_entry)
		}
		strings.write_byte(sb, '}')
	}
	strings.write_byte(sb, '}')
}

// build_clusters builds the JSON cluster entry array from disk.
build_clusters :: proc(vol: ^fs.Volume) -> (clusters: [dynamic]ClusterJSON, allocated, total: u64) {
	m := &vol.master
	total = m.cluster_map_size
	clusters = make([dynamic]ClusterJSON)

	entries_per_sector := u64(fs.CLUSTER_MAP_ENTRIES_PER_SECTOR)
	cm_sectors := (m.cluster_map_size + entries_per_sector - 1) / entries_per_sector

	for sec_idx: u64; sec_idx < cm_sectors; sec_idx += 1 {
		buf: [fs.SECTOR_SIZE]u8
		if !fs.sector_read(vol, fs.Sector(m.cluster_map_offset + sec_idx), buf[:]) {
			break
		}

		cmes := (^[fs.CLUSTER_MAP_ENTRIES_PER_SECTOR]fs.Cluster_Map_Entry)(&buf[0])
		for ei in 0 ..< fs.CLUSTER_MAP_ENTRIES_PER_SECTOR {
			ci := int(sec_idx) * fs.CLUSTER_MAP_ENTRIES_PER_SECTOR + ei
			if u64(ci) >= m.cluster_map_size { break }

			cme := cmes[ei]
			if .Allocated in cme.flags { allocated += 1 }
			cm_buf: [64]u8
			flags_str := strings.clone(fs.cme_flags_str(cme.flags, cm_buf[:]))
			append(&clusters, ClusterJSON{
				idx          = ci,
				flags        = flags_str,
				sector_index = cme.sector_index,
			})
		}
	}
	return clusters, allocated, total
}

// build_directory recursively builds a JSON directory structure from disk.
build_directory :: proc(vol: ^fs.Volume, cluster: fs.Cluster, offset: fs.Sector_Offset) -> map[string]EntryJSON {
	runs, ext_err := fs.resolve_extents(vol, cluster, offset)
	if ext_err != .None { return nil }

	result := make(map[string]EntryJSON)

	for run in runs {
		n := int(run.count)
		for si in 0 ..< n {
			sec := fs.Sector(u64(run.sector) + u64(si))
			buf: [fs.SECTOR_SIZE]u8
			if !fs.sector_read(vol, sec, buf[:]) { break }

			features := vol.master.features
			des := int(fs.dir_entry_size(features))
			depc := int(fs.dir_entries_per_sector(features))

			get_ent :: #force_inline proc(buf: []u8, idx: int, des: int) -> ^fs.Directory_Entry {
				return (^fs.Directory_Entry)(&buf[idx * des])
			}

			for i in 0 ..< depc {
				e := get_ent(buf[:], i, des)^
				if .Exists not_in e.flags { continue }

				name := strings.clone(fs.entry_short_name(&e))
				if .LFN in e.flags {
					if lfn, lfn_ok := fs.resolve_lfn(vol, &e); lfn_ok {
						delete(name)
						name = strings.clone(lfn)
					}
				}
				if name == "" { continue }

				kind: string
				if .Directory in e.flags { kind = "DIR" }
				else if .Link in e.flags { kind = "LINK" }
				else { kind = "FILE" }

				dt_buf: [32]u8
				dt_str := strings.clone(fmt.bprintf(dt_buf[:], "%04d-%02d-%02d %02d:%02d",
					e.year, e.date_time.month, e.date_time.date,
					e.date_time.hour, e.date_time.minute))

				entry := EntryJSON{
					kind    = kind,
					size    = e.file_size,
					cluster = e.stored_cluster,
					sector  = e.sector_index,
					dt      = dt_str,
				}

				if .Link in e.flags {
					target := resolve_symlink_target(vol, &e, context.temp_allocator)
					if target != "" {
						entry.target = strings.clone(target)
					}
				}

				if .Directory in e.flags {
					entry.children = build_directory(vol, fs.Cluster(e.stored_cluster), fs.Sector_Offset(e.sector_index))
				}

				result[name] = entry
			}
		}
	}
	return result
}

// print_json builds and prints the complete JSON output.
print_json :: proc(vol: ^fs.Volume) {
	m := &vol.master

	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)

	fmt.sbprintf(&sb, `{{"master":{{"sig":"`)
	sig_str := string(m.sig[:])
	json_escape_string(&sb, sig_str)
	fmt.sbprintf(&sb, `","rev_min":%d,"rev_max":%d,"features":%d,`,
		m.rev_min, m.rev_max, transmute(u64)(m.features))
	fmt.sbprintf(&sb, `"cluster_map_offset":%d,"cluster_map_size":%d`,
		m.cluster_map_offset, m.cluster_map_size)
	fmt.sbprintf(&sb, `,"cluster_size":%d,"root_sector_index":%d,"root_cluster":%d},`,
		m.cluster_size, m.root_sector_index, m.root_cluster)

	// Clusters
	cluster_list, allocated, total := build_clusters(vol)
	defer {
		for c in cluster_list { delete(c.flags) }
		delete(cluster_list)
	}

	fmt.sbprintf(&sb, `"clusters":[`)
	first_cluster := true
	for c in cluster_list {
		if !first_cluster { strings.write_byte(&sb, ',') }
		first_cluster = false
		fmt.sbprintf(&sb, `{{"idx":%d,"flags":"%s","sector_index":%d}}`,
			c.idx, c.flags, c.sector_index)
	}
	fmt.sbprintf(&sb, `],"allocated":%d,"free":%d,"total":%d,`, allocated, total - allocated, total)

	// Root directory
	fmt.sbprintf(&sb, `"root":{{`)
	root_entries := build_directory(vol, fs.Cluster(m.root_cluster), fs.Sector_Offset(m.root_sector_index))
	defer delete(root_entries)

	first := true
	for name, entry in root_entries {
		if !first { strings.write_byte(&sb, ',') }
		first = false
		json_write_entry(&sb, name, entry)
	}
	fmt.sbprintf(&sb, `}}}}`)

	fmt.println(strings.to_string(sb))
}
