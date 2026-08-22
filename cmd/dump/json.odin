// json.odin — JSON output builder for the image dumper.
//
// Uses core:encoding/json to marshal typed structs. Output is compact
// (single-line) strict JSON; the root directory map is sorted by key for
// deterministic output.
#+build linux
package main

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "src:fs"

// MasterJSON is the master-record section of the JSON output.
MasterJSON :: struct {
	sig:                string `json:"sig"`,
	rev_min:            u8     `json:"rev_min"`,
	rev_max:            u8     `json:"rev_max"`,
	features:           u64    `json:"features"`,
	cluster_map_offset: u64    `json:"cluster_map_offset"`,
	cluster_map_size:   u64    `json:"cluster_map_size"`,
	cluster_size:       u64    `json:"cluster_size"`,
	root_sector_index:  u16    `json:"root_sector_index"`,
	root_cluster:       u64    `json:"root_cluster"`,
}

// ClusterJSON represents a single cluster entry for JSON output.
ClusterJSON :: struct {
	// idx is the cluster index.
	idx:          int    `json:"idx"`,
	// flags is the human-readable flags string.
	flags:        string `json:"flags"`,
	// sector_index is the sector offset within the cluster.
	sector_index: u16    `json:"sector_index"`,
}

// EntryJSON represents a directory entry for JSON output.
EntryJSON :: struct {
	kind:     string               `json:"kind"`,
	size:     u64                  `json:"size"`,
	cluster:  u64                  `json:"cluster"`,
	sector:   u16                  `json:"sector"`,
	dt:       string               `json:"dt"`,
	target:   string               `json:"target,omitempty"`,
	children: map[string]EntryJSON `json:"children,omitempty"`,
}

// RootJSON is the top-level JSON document.
RootJSON :: struct {
	master:    MasterJSON           `json:"master"`,
	clusters:  [dynamic]ClusterJSON `json:"clusters"`,
	allocated: u64                  `json:"allocated"`,
	free:      u64                  `json:"free"`,
	total:     u64                  `json:"total"`,
	root:      map[string]EntryJSON `json:"root"`,
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
		if fs.sector_read(vol, fs.Sector(m.cluster_map_offset + sec_idx), buf[:]) != .None {
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
			if fs.sector_read(vol, sec, buf[:]) != .None { break }

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
	cluster_list, allocated, total := build_clusters(vol)
	defer {
		for c in cluster_list { delete(c.flags) }
		delete(cluster_list)
	}

	root_entries := build_directory(vol, fs.Cluster(m.root_cluster), fs.Sector_Offset(m.root_sector_index))
	defer delete(root_entries)

	root := RootJSON{
		master = MasterJSON{
			sig                = string(m.sig[:]),
			rev_min            = m.rev_min,
			rev_max            = m.rev_max,
			features           = transmute(u64)(m.features),
			cluster_map_offset = m.cluster_map_offset,
			cluster_map_size   = m.cluster_map_size,
			cluster_size       = m.cluster_size,
			root_sector_index  = m.root_sector_index,
			root_cluster       = m.root_cluster,
		},
		clusters  = cluster_list,
		allocated = allocated,
		free      = total - allocated,
		total     = total,
		root      = root_entries,
	}

	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)

	opts := json.Marshal_Options{spec = .JSON, sort_maps_by_key = true}
	if err := json.marshal_to_builder(&sb, root, &opts); err != nil {
		log.errorf("json marshal failed: %v", err)
		os.exit(1)
	}
	fmt.println(strings.to_string(sb))
}
