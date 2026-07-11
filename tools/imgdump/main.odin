// main.odin — fused image dumper.
//
// Reads a fused image and prints every struct in human-readable form.
// Uses only the src/fs/ package — no FUSE dependency.
#+build linux
package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "src:fs"

main :: proc() {
	context = runtime.default_context()
	if len(os.args) < 2 {
		log.fatalf("usage: imgdump <image-path>")
	}

	path := os.args[1]
	fd, open_err := os.open(path, {.Read})
	if open_err != nil {
		log.fatalf("cannot open %s: %v", path, open_err)
	}
	defer os.close(fd)

	master, ok := fs.read_master_record(fd)
	if !ok {
		log.fatalf("failed to read MasterRecord")
	}

	fi, stat_err := os.stat(path, context.temp_allocator)
	image_size: u64 = 0
	if stat_err == nil {
		image_size = u64(fi.size)
	}

	err := fs.validate_master(&master, image_size)
	if err != .None {
		log.fatalf("validation failed: %v", err)
	}

	print_master(&master)
	print_cluster_map(fd, &master)
	print_root_directory(fd, &master)
}

print_master :: proc(m: ^fs.Master_Record) {
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

print_cluster_map :: proc(fd: ^os.File, m: ^fs.Master_Record) {
	fmt.printf("=== Cluster Map (%d entries) ===\n", m.cluster_map_size)
	count := u64(0)
	for cluster_idx in 0 ..< m.cluster_map_size {
		entry, ok := fs.read_cluster_map_entry(fd, m, fs.Cluster(cluster_idx))
		if ok && .Allocated in entry.flags {
			fmt.printf("  [%3d] flags=%-20s  stored_cluster=%d  sector_index=%d\n",
				cluster_idx, flags_str(entry.flags), entry.stored_cluster, entry.sector_index)
			count += 1
		}
	}

	fmt.printf("  (%d allocated, %d total)\n", count, m.cluster_map_size)
	fmt.println()
	fmt.println("=== ClusterEntry tables (allocated clusters only) ===")
	for cluster_idx in 0 ..< m.cluster_map_size {
		cme, ok := fs.read_cluster_map_entry(fd, m, fs.Cluster(cluster_idx))
		if !ok || .Allocated not_in cme.flags {
			continue
		}

		table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
		if !fs.read_cluster_entry_table(fd, m, fs.Cluster(cluster_idx), &table) {
			continue
		}

		fmt.printf("  Cluster %d (stored_cluster=%d, sector_index=%d):\n",
			cluster_idx, cme.stored_cluster, cme.sector_index)
		for i in 0 ..< fs.CLUSTER_ENTRIES_PER_SECTOR {
			e := table[i]
			if .Allocated in e.state {
				fmt.printf("    [%2d] state=%-22s  alloc=%d  start=%d  next=(%d,%d)\n",
					i, ce_state_str(e.state), e.allocation_size, e.sector_start,
					e.next_cluster, e.next_sector_index)
			}
		}
	}
	fmt.println()
}

print_root_directory :: proc(fd: ^os.File, m: ^fs.Master_Record) {
	fmt.println("=== Root Directory (cluster, sector) ===")
	root_cluster := fs.Cluster(m.root_cluster)
	root_offset  := fs.Sector_Offset(m.root_sector_index)
	ce, found_ce := fs.find_cluster_entry(fd, m, root_cluster, root_offset)
	if !found_ce {
		log.errorf("root directory ClusterEntry not found")
		return
	}
	if .Directory not_in ce.state {
		fmt.println("  (root directory ClusterEntry not found or not a directory)")
		return
	}

	entries, ok_dir := fs.read_directory_entries(fd, m, root_cluster, fs.Sector_Offset(ce.sector_start))
	if !ok_dir {
		log.errorf("failed to read root directory entries")
		return
	}

	fmt.printf("  Directory ClusterEntry: cluster=%d sector_start=%d alloc=%d\n",
		m.root_cluster, ce.sector_start, ce.allocation_size)
	fmt.printf("  (%d entries present)\n", len(entries))
	fmt.println()

	for &e, i in entries {
		name := ""
		if .LFN in e.flags {
			lfn, lfn_ok := fs.resolve_lfn(fd, m, &e)
			name = lfn if lfn_ok else "(lfn?)"
		} else {
			name = fs.entry_short_name(&e)
		}

		kind := ""
		if .Directory in e.flags {kind = " DIR"}
		if .Link in e.flags {kind = " LINK"}
		if !(.Directory in e.flags) && !(.Link in e.flags) {kind = " FILE"}

		fmt.printf("  [%d] \"%s\"%s  flags=%s  size=%d  cluster=%d  sector=%d  year=%d  dt=%02d/%02d %02d:%02d:%02d\n",
			i, name, kind, dir_flags_str(e.flags), e.file_size,
			e.stored_cluster, e.sector_index, e.year,
			e.date_time.date, e.date_time.month,
			e.date_time.hour, e.date_time.minute, e.date_time.second)
	}
}

flags_str :: proc(f: fs.Cluster_Map_Flags) -> string {
	parts: [dynamic; 8]string
	if .Allocated in f {append(&parts, "ALLOCATED")}
	if .Reserved  in f {append(&parts, "RESERVED")}
	if .Full      in f {append(&parts, "FULL")}
	if len(parts) == 0 {return "0"}
	return strings.join(parts[:], "|")
}

ce_state_str :: proc(s: fs.Cluster_Entry_State) -> string {
	parts: [dynamic; 8]string
	if .Allocated    in s {append(&parts, "ALLOCATED")}
	if .Cluster_Map  in s {append(&parts, "CLUSTER_MAP")}
	if .Directory    in s {append(&parts, "DIRECTORY")}
	if .File_Content in s {append(&parts, "FILE_CONTENT")}
	if .LFN          in s {append(&parts, "LFN")}
	if len(parts) == 0 {return "0"}
	return strings.join(parts[:], "|")
}

dir_flags_str :: proc(f: fs.Dir_Flags) -> string {
	parts: [dynamic; 8]string
	if .Allocated  in f {append(&parts, "ALLOCATED")}
	if .LFN        in f {append(&parts, "LFN")}
	if .Directory  in f {append(&parts, "DIRECTORY")}
	if .Read_Only  in f {append(&parts, "READONLY")}
	if .Link       in f {append(&parts, "LINK")}
	if .Exists     in f {append(&parts, "EXISTS")}
	if .No_Write   in f {append(&parts, "NOWRITE")}
	if .No_Read    in f {append(&parts, "NOREAD")}
	if .No_Execute in f {append(&parts, "NOEXEC")}
	if len(parts) == 0 {return "0"}
	return strings.join(parts[:], "|")
}
