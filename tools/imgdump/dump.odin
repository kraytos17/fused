// dump.odin — Image structure printers (master, cluster map, directory tree, hex).
#+build linux
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "src:fs"

fmt_size :: proc(buf: []u8, bytes: u64) -> string {
	switch {
	case bytes < 1024:
		return fmt.bprintf(buf, "%d B", bytes)
	case bytes < 1024 * 1024:
		return fmt.bprintf(buf, "%.1f KB", f64(bytes) / 1024.0)
	case:
		return fmt.bprintf(buf, "%.1f MB", f64(bytes) / (1024.0 * 1024.0))
	}
}

print_master :: proc(fd: ^os.File, m: ^fs.Master_Record, json: bool, needs_comma: ^bool) {
	if json {
		if needs_comma^ { fmt.print(",") }

		needs_comma^ = true
		sb: strings.Builder
		strings.builder_init(&sb, context.temp_allocator)
		strings.write_string(&sb, `"master":{"sig":"`)
		raw_sig := string(m.sig[:])
		for i := 0; i < len(raw_sig); i += 1 {
			if raw_sig[i] == 0 {
				strings.write_string(&sb, `\u0000`)
			} else {
				strings.write_byte(&sb, raw_sig[i])
			}
		}

		strings.write_string(&sb, `","rev":`)
		fmt.sbprint(&sb, m.rev)
		strings.write_string(&sb, `,"cluster_map_offset":`)
		fmt.sbprint(&sb, m.cluster_map_offset)
		strings.write_string(&sb, `,"cluster_map_size":`)
		fmt.sbprint(&sb, m.cluster_map_size)
		strings.write_string(&sb, `,"cluster_size":`)
		fmt.sbprint(&sb, m.cluster_size)
		strings.write_string(&sb, `,"root_sector_index":`)
		fmt.sbprint(&sb, m.root_sector_index)
		strings.write_string(&sb, `,"root_cluster":`)
		fmt.sbprint(&sb, m.root_cluster)
		strings.write_string(&sb, `}`)
		fmt.print(strings.to_string(sb))
		return
	}

	sig_len := 0
	for sig_len < 7 && m.sig[sig_len] != 0 { sig_len += 1 }

	image_mb := f64(u64(m.cluster_map_size) * u64(m.cluster_size) * fs.SECTOR_SIZE) / (1024.0 * 1024.0)
	fmt.println("=== MasterRecord (sector 0) ===")
	fmt.printf("  sig       = \"%s\"  (rev %d)\n", string(m.sig[:sig_len]), m.rev)
	fmt.printf("  image     = %d clusters  (%d sectors/cluster = %.1f MB)\n",
		m.cluster_map_size, m.cluster_size, image_mb)
	fmt.printf("  root dir  = cluster %d, sector %d\n", m.root_cluster, m.root_sector_index)
	fmt.println()
}

print_cluster_map :: proc(fd: ^os.File, m: ^fs.Master_Record, json: bool, needs_comma: ^bool, show_all: bool) {
	cm_sectors := (m.cluster_map_size + fs.CLUSTER_MAP_ENTRIES_PER_SECTOR - 1) / fs.CLUSTER_MAP_ENTRIES_PER_SECTOR
	allocated: u64
	if json {
		if needs_comma^ { fmt.print(",") }
		needs_comma^ = true
		fmt.print(`"clusters":[`)
	}

	json_first := true
	for sec_idx: u64; sec_idx < cm_sectors; sec_idx += 1 {
		buf: [fs.SECTOR_SIZE]u8
		if !fs.sector_read(fd, fs.Sector(m.cluster_map_offset + sec_idx), buf[:]) {
			break
		}

		cmes := (^[fs.CLUSTER_MAP_ENTRIES_PER_SECTOR]fs.Cluster_Map_Entry)(raw_data(buf[:]))
		for ei in 0 ..< fs.CLUSTER_MAP_ENTRIES_PER_SECTOR {
			ci := int(sec_idx) * fs.CLUSTER_MAP_ENTRIES_PER_SECTOR + ei
			if u64(ci) >= m.cluster_map_size { break }

			cme := cmes[ei]
			if json {
				if .Allocated in cme.flags { allocated += 1 }
				if !json_first { fmt.print(",") }

				json_first = false
				cm_buf: [64]u8
				js := fs.cme_flags_str(cme.flags, cm_buf[:])
				fmt.print(`{"idx":`)
				fmt.print(ci)
				fmt.print(`,"flags":"`)
				fmt.print(js)
				fmt.print(`","sector_index":`)
				fmt.print(cme.sector_index)
				fmt.print(`}`)
			} else {
				if .Allocated in cme.flags { allocated += 1 }
				if !show_all && .Allocated not_in cme.flags {
					continue
				}

				cm_buf: [64]u8
				js := fs.cme_flags_str(cme.flags, cm_buf[:])
				if (js == "0") {
					fmt.printf("  [%3d] FREE\n", ci)
				} else {
					fmt.printf("  [%3d] %s", ci, js)
					if cme.sector_index != 0 {
						fmt.printf("  sector_index=%d", cme.sector_index)
					}
					fmt.println()
				}
				if .Allocated in cme.flags {
					table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
					if fs.read_cluster_entry_table(fd, m, fs.Cluster(ci), &table) {
						for i in 0 ..< fs.CLUSTER_ENTRIES_PER_SECTOR {
							e := table[i]
							if .Allocated in e.state {
								ce_buf: [64]u8
								state_str := fs.ce_state_str(e.state, ce_buf[:])
								next_str := ""
								nb: [32]u8
								if e.next_cluster != 0 {
									next_str = fmt.bprintf(nb[:], "  next=(%d,%d)", e.next_cluster, e.next_sector_index)
								}

								sectors := "sector"
								if e.allocation_size != 1 { sectors = "sectors" }
								fmt.printf("    CE[%2d] %-22s  %d %s  @%d%s\n",
									i, state_str, e.allocation_size, sectors, e.sector_start, next_str)
							}
						}
					}
				}
			}
		}
	}
	if json {
		fmt.print(`],"allocated":`)
		fmt.print(allocated)
		fmt.print(`,"free":`)
		fmt.print(m.cluster_map_size - allocated)
		fmt.print(`,"total":`)
		fmt.print(m.cluster_map_size)
	} else {
		fmt.printf("  (%d allocated, %d free)\n", allocated, m.cluster_map_size - allocated)
		fmt.println()
	}
}

print_directory_tree :: proc(fd: ^os.File, m: ^fs.Master_Record, json: bool, needs_comma: ^bool) {
	if json {
		if needs_comma^ { fmt.print(",") }
		needs_comma^ = true
		fmt.print(`"root":`)
	}
	if !json { fmt.println("=== Directory Tree ===") }
	print_directory(fd, m, fs.Cluster(m.root_cluster), fs.Sector_Offset(m.root_sector_index), "", true, json)
}

print_directory :: proc(fd: ^os.File, m: ^fs.Master_Record, cluster: fs.Cluster, offset: fs.Sector_Offset, prefix: string, is_root: bool, json: bool) {
	runs, rok := fs.resolve_extents(fd, m, cluster, offset)
	if !rok {
		if json { fmt.print(`null`) }
		return
	}
	if json {
		fmt.print(`{`)
	}

	entry_count := 0
	for run in runs {
		n := int(run.count)
		for si in 0 ..< n {
			sec := fs.Sector(u64(run.sector) + u64(si))
			buf: [fs.SECTOR_SIZE]u8
			if !fs.sector_read(fd, sec, buf[:]) { break }

			raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(buf[:]))
			last_in_sector := -1
			for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
				if .Exists in raw[i].flags { last_in_sector = i }
			}
			for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
				e := raw[i]
				if .Exists not_in e.flags { continue }

				name := fs.entry_short_name(&e)
				if .LFN in e.flags {
					if lfn, lfn_ok := fs.resolve_lfn(fd, m, &e); lfn_ok {
						name = lfn
					}
				}

				kind: string
				if .Directory in e.flags { kind = "DIR" }
				else if .Link in e.flags { kind = "LINK" }
				else { kind = "FILE" }

				target: string
				if .Link in e.flags {
					target = resolve_symlink_target(fd, m, &e, context.temp_allocator)
				}

				connector := "├── "
				if is_root { connector = "  └── " }
				else if i == last_in_sector { connector = "  └── " }
				else { connector = "  ├── " }

				dt_buf: [32]u8
				dt_str := fmt.bprintf(dt_buf[:], "%04d-%02d-%02d %02d:%02d",
					e.year, e.date_time.month, e.date_time.date,
					e.date_time.hour, e.date_time.minute)

				if json {
					if entry_count > 0 { fmt.print(",") }

					entry_count += 1
					fmt.print(`"`)
					fmt.print(name)
					fmt.print(`":{"kind":"`)
					fmt.print(kind)
					fmt.print(`","size":`)
					fmt.print(e.file_size)
					fmt.print(`,"cluster":`)
					fmt.print(e.stored_cluster)
					fmt.print(`,"sector":`)
					fmt.print(e.sector_index)
					fmt.print(`,"dt":"`)
					fmt.print(dt_str)
					fmt.print(`"`)
					if .Link in e.flags && target != "" {
						fmt.print(`,"target":"`)
						fmt.print(target)
						fmt.print(`"`)
					}
					if .Directory in e.flags {
						fmt.print(`,"children":`)
						print_directory(fd, m,
							fs.Cluster(e.stored_cluster),
							fs.Sector_Offset(e.sector_index),
							"", false, true)
					}
					fmt.print(`}`)
				} else {
					sz_buf: [64]u8
					size_str := fmt_size(sz_buf[:], e.file_size)
					lc_buf: [32]u8
					loc_str := fmt.bprintf(lc_buf[:], "@(%d,%d)", e.stored_cluster, e.sector_index)
					fb: [24]u8
					fi := 0
					if .Read_Only in e.flags { fb[fi] = 'R'; fi += 1 }
					if .No_Write in e.flags { fb[fi] = 'W'; fi += 1 }
					if .No_Read in e.flags { fb[fi+0] = 'R'; fb[fi+1] = '!'; fi += 2 }
					if .No_Execute in e.flags { fb[fi+0] = 'X'; fb[fi+1] = '!'; fi += 2 }

					flags_suffix := string(fb[:fi])
					if .Link in e.flags && target != "" {
						fmt.printf("%s%s\"%s\" → \"%s\"  %-4s  %5s  %s  %s%s\n",
							prefix, connector, name, target, kind, size_str, loc_str, dt_str, flags_suffix)
					} else {
						fmt.printf("%s%s\"%s\"  %-4s  %5s  %s  %s%s\n",
							prefix, connector, name, kind, size_str, loc_str, dt_str, flags_suffix)
					}
					if .Directory in e.flags {
						cp_buf: [128]u8
						child_prefix := fmt.bprintf(cp_buf[:], "%s  ", prefix)
						print_directory(fd, m,
							fs.Cluster(e.stored_cluster),
							fs.Sector_Offset(e.sector_index),
							child_prefix, false, false)
					}
				}
				entry_count += 1
			}
		}
	}
	if json { fmt.print(`}`) }
}

print_hex_by_path :: proc(fd: ^os.File, m: ^fs.Master_Record, path: string) {
	entry, _, _, _, ok := resolve_file(fd, m, path)
	if !ok {
		log.errorf("path not found: %s", path)
		os.exit(1)
	}
	if .Directory in entry.flags {
		log.errorf("%s is a directory", path)
		os.exit(1)
	}

	runs, rok := fs.resolve_extents(fd, m, fs.Cluster(entry.stored_cluster), fs.Sector_Offset(entry.sector_index))
	if !rok { log.errorf("resolve_extents failed"); os.exit(1) }

	sb: strings.Builder
	strings.builder_init(&sb, context.allocator)
	defer strings.builder_destroy(&sb)

	header_buf: [64]u8
	fmt.bprintf(header_buf[:], "=== Hex dump of \"%s\" (%d bytes) ===\n", path, entry.file_size)
	fmt.print(string(header_buf[:]))

	remaining := entry.file_size
	file_off: u64
	for run in runs {
		for si: u64; si < u64(run.count); si += 1 {
			if remaining == 0 { break }

			sec := fs.Sector(u64(run.sector) + si)
			sec_buf: [fs.SECTOR_SIZE]u8
			if !fs.sector_read(fd, sec, sec_buf[:]) { return }

			n := min(remaining, fs.SECTOR_SIZE)
			off := file_off
			i: u64
			for i < n {
				fmt.sbprintf(&sb, "%08x  ", off)
				for j: u64; j < 16 && i+j < n; j += 1 {
					fmt.sbprintf(&sb, "%02x ", sec_buf[i+j])
				}
				if i + 16 > n {
					rem := (i + 16) - n
					for j: u64; j < rem; j += 1 { fmt.sbprintf(&sb, "   ") }
				}

				fmt.sbprintf(&sb, " ")
				for j: u64; j < 16 && i+j < n; j += 1 {
					b := sec_buf[i+j]
					if b >= 32 && b < 127 { fmt.sbprintf(&sb, "%c", b) }
					else { fmt.sbprintf(&sb, ".") }
				}

				fmt.sbprintf(&sb, "\n")
				off += 16
				i += 16
			}
			file_off += n
			remaining -= n
		}
	}
	fmt.print(strings.to_string(sb))
}
