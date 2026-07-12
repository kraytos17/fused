// main.odin — fused image dumper.
//
// Reads a fused image and prints every structure in human-readable form.
// Single-pass cluster map scan, zero-heap-alloc flag printers, recursive
// directory tree walk, hex dump mode, and JSON output.
// Uses only the src/fs/ package — no FUSE dependency.
#+build linux
package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "src:fs"

Flags :: struct {
	path:     string,
	json:     bool,
	hex:      bool,
	hex_path: string,
}

main :: proc() {
	context = runtime.default_context()
	context.logger = log.create_console_logger(log.Level.Warning)
	flags := parse_args()
	fd, open_err := os.open(flags.path, {.Read})
	if open_err != nil {
		log.errorf("cannot open %s: %v", flags.path, open_err)
		os.exit(1)
	}
	defer os.close(fd)

	master, ok := fs.read_master_record(fd)
	if !ok { log.errorf("failed to read MasterRecord"); os.exit(1) }

	fi, stat_err := os.stat(flags.path, context.temp_allocator)
	image_size: u64 = 0
	if stat_err == nil {
		image_size = u64(fi.size)
	}
	if err := fs.validate_master(&master, image_size); err != .None {
		log.errorf("validation failed: %v", err)
		os.exit(1)
	}
	if flags.hex {
		print_hex_by_path(fd, &master, flags.hex_path)
		return
	}

	if flags.json { fmt.print(`{`) }
	print_master(fd, &master, flags.json)
	if flags.json { fmt.print(`,`) }
	print_cluster_map(fd, &master, flags.json)
	if flags.json { fmt.print(`,`) }
	print_directory_tree(fd, &master, flags.json)
	if flags.json { fmt.println(`}`) }
}

parse_args :: proc() -> Flags {
	f: Flags
	i := 1
	for i < len(os.args) {
		arg := os.args[i]
		switch {
		case arg == "--help" || arg == "-h":
			print_help(); os.exit(0)
		case arg == "--json":
			f.json = true
		case strings.has_prefix(arg, "--hex"):
			rest := strings.trim_prefix(arg, "--hex")
			if rest == "" || rest[0] != '=' {
				f.hex = true; f.hex_path = "/"
			} else {
				f.hex = true; f.hex_path = rest[1:]
			}
		case:
			if f.path == "" {
				f.path = arg
			} else {
				log.errorf("unexpected argument: %s", arg)
				print_help(); os.exit(1)
			}
		}
		i += 1
	}
	if f.path == "" {
		log.errorf("missing image path")
		print_help(); os.exit(1)
	}
	return f
}

print_help :: proc() {
	fmt.eprintln(`Usage: imgdump [options] <image-path>

Dumps a fused filesystem image in human-readable form.

Options:
  --json             Output as JSON (machine-readable)
  --hex[=<path>]     Dump file contents as hex (default: /)
  --help, -h         Show this help

Examples:
  imgdump fused.img
  imgdump --json fused.img | jq '.clusters[] | select(.flags == "ALLOCATED")'
  imgdump --hex=/Kernel fused.img`)
}

cme_flags_str :: proc(f: fs.Cluster_Map_Flags, buf: []byte) -> string {
	sb := strings.builder_from_slice(buf)
	n := 0
	if .Allocated in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "ALLOCATED"); n += 1
	}
	if .Reserved in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "RESERVED"); n += 1
	}
	if .Full in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "FULL"); n += 1
	}
	if n == 0 { return "0" }
	return strings.to_string(sb)
}

ce_state_str :: proc(s: fs.Cluster_Entry_State, buf: []byte) -> string {
	sb := strings.builder_from_slice(buf)
	n := 0
	if .Allocated in s {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "ALLOCATED"); n += 1
	}
	if .Cluster_Map in s {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "CLUSTER_MAP"); n += 1
	}
	if .Directory in s {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "DIRECTORY"); n += 1
	}
	if .File_Content in s {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "FILE_CONTENT"); n += 1
	}
	if .LFN in s {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "LFN"); n += 1
	}
	if n == 0 { return "0" }
	return strings.to_string(sb)
}

dir_flags_str :: proc(f: fs.Dir_Flags, buf: []byte) -> string {
	sb := strings.builder_from_slice(buf)
	n := 0
	if .Allocated in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "ALLOCATED"); n += 1
	}
	if .LFN in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "LFN"); n += 1
	}
	if .Directory in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "DIRECTORY"); n += 1
	}
	if .Read_Only in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "READONLY"); n += 1
	}
	if .Link in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "LINK"); n += 1
	}
	if .Exists in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "EXISTS"); n += 1
	}
	if .No_Write in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "NOWRITE"); n += 1
	}
	if .No_Read in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "NOREAD"); n += 1
	}
	if .No_Execute in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "NOEXEC"); n += 1
	}
	if n == 0 { return "0" }
	return strings.to_string(sb)
}

print_master :: proc(fd: ^os.File, m: ^fs.Master_Record, json: bool) {
	if json {
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

	fmt.println("=== MasterRecord (sector 0) ===")
	fmt.printf("  sig                 = \"%s\"\n", string(m.sig[:]))
	fmt.printf("  rev                 = %d\n", m.rev)
	fmt.printf("  cluster_map_offset  = %d\n", m.cluster_map_offset)
	fmt.printf("  cluster_map_size    = %d\n", m.cluster_map_size)
	fmt.printf("  cluster_size        = %d\n", m.cluster_size)
	fmt.printf("  root_sector_index   = %d\n", m.root_sector_index)
	fmt.printf("  root_cluster        = %d\n", m.root_cluster)
	fmt.printf("  end_sig             = 0x%04X\n", m.end_sig)
	fmt.println()
}

print_cluster_map :: proc(fd: ^os.File, m: ^fs.Master_Record, json: bool) {
	cm_sectors := (m.cluster_map_size + fs.CLUSTER_MAP_ENTRIES_PER_SECTOR - 1) / fs.CLUSTER_MAP_ENTRIES_PER_SECTOR
	allocated: u64
	if json {
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
			if .Allocated in cme.flags { allocated += 1 }

			cm_buf: [64]u8
			if json {
				if !json_first { fmt.print(",") }
				json_first = false
				js := cme_flags_str(cme.flags, cm_buf[:])
				fmt.print(`{"idx":`)
				fmt.print(ci)
				fmt.print(`,"flags":"`)
				fmt.print(js)
				fmt.print(`","sector_index":`)
				fmt.print(cme.sector_index)
				fmt.print(`}`)
			} else {
				js := cme_flags_str(cme.flags, cm_buf[:])
				fmt.printf("  [%3d] flags=%-20s  sector_index=%d\n", ci, js, cme.sector_index)
				if .Allocated in cme.flags {
					table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
					if fs.read_cluster_entry_table(fd, m, fs.Cluster(ci), &table) {
						for i in 0 ..< fs.CLUSTER_ENTRIES_PER_SECTOR {
							e := table[i]
							if .Allocated in e.state {
								ce_buf: [64]u8
								fmt.printf("    CE[%2d] state=%-22s  alloc=%d  start=%d  next=(%d,%d)\n",
									i, ce_state_str(e.state, ce_buf[:]), e.allocation_size, e.sector_start,
									e.next_cluster, e.next_sector_index)
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
		fmt.print(`,"total":`)
		fmt.print(m.cluster_map_size)
	} else {
		fmt.printf("  (%d allocated, %d total)\n", allocated, m.cluster_map_size)
		fmt.println()
	}
}

print_directory_tree :: proc(fd: ^os.File, m: ^fs.Master_Record, json: bool) {
	if json { fmt.print(`"root":`) }
	print_directory(fd, m, fs.Cluster(m.root_cluster), fs.Sector_Offset(m.root_sector_index), "", json)
}

print_directory :: proc(fd: ^os.File, m: ^fs.Master_Record, cluster: fs.Cluster, offset: fs.Sector_Offset, indent: string, json: bool) {
	runs, rok := fs.resolve_extents(fd, m, cluster, offset)
	if !rok {
		if json { fmt.print(`null`) }
		return
	}

	if json { fmt.print(`{`) }
	entry_count := 0
	for run in runs {
		n := int(run.count)
		for si in 0 ..< n {
			sec := fs.Sector(u64(run.sector) + u64(si))
			buf: [fs.SECTOR_SIZE]u8
			if !fs.sector_read(fd, sec, buf[:]) { break }

			raw := (^[fs.DIR_ENTRIES_PER_SECTOR]fs.Directory_Entry)(raw_data(buf[:]))
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

				dt_buf: [32]u8
				dt_str := fmt.bprintf(dt_buf[:], "%02d/%02d %02d:%02d:%02d",
					e.date_time.date, e.date_time.month,
					e.date_time.hour, e.date_time.minute, e.date_time.second)

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
					fmt.print(`,"year":`)
					fmt.print(e.year)
					fmt.print(`,"dt":"`)
					fmt.print(dt_str)
					fmt.print(`"`)
					if .Directory in e.flags {
						fmt.print(`,"children":`)
						print_directory(fd, m,
							fs.Cluster(e.stored_cluster),
							fs.Sector_Offset(e.sector_index),
							"", true)
					}
					fmt.print(`}`)
				} else {
					f_buf: [64]u8
					fs_str := dir_flags_str(e.flags, f_buf[:])
					fmt.printf("%s[%d] \"%s\"  %-4s  flags=%s  size=%d  cluster=%d  sector=%d  year=%d  dt=%s\n",
						indent, i, name, kind, fs_str, e.file_size,
						e.stored_cluster, e.sector_index, e.year, dt_str)
					if .Directory in e.flags {
						ci_buf: [64]u8
						child_indent := fmt.bprintf(ci_buf[:], "%s  ", indent)
						print_directory(fd, m,
							fs.Cluster(e.stored_cluster),
							fs.Sector_Offset(e.sector_index),
							child_indent, false)
					}
				}
			}
		}
	}
	if json { fmt.print(`}`) }
}

print_hex_by_path :: proc(fd: ^os.File, m: ^fs.Master_Record, path: string) {
	entry, cluster, offset, _, ok := resolve_file(fd, m, path)
	if !ok {
		log.errorf("path not found: %s", path)
		os.exit(1)
	}
	if .Directory in entry.flags {
		log.errorf("%s is a directory", path)
		os.exit(1)
	}

	runs, rok := fs.resolve_extents(fd, m, cluster, offset)
	if !rok { log.errorf("resolve_extents failed"); os.exit(1) }

	sb: strings.Builder
	strings.builder_init(&sb, context.allocator)
	defer strings.builder_destroy(&sb)

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
		ce, ce_ok := fs.find_cluster_entry(fd, m, current_c, current_o)
		if !ce_ok { return }

		dirs, dirs_ok := fs.read_directory_entries(fd, m, current_c, fs.Sector_Offset(ce.sector_start))
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
