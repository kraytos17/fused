// main.odin — fused image formatter.
//
// Formats a raw disk image with the MasterRecord, ClusterMap region,
// initial ClusterEntry tables for the root directory, and an optional
// demo file.  No FUSE dependency — can be built and run without libfuse3.
#+build linux
package main

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "src:fs"

main :: proc() {
	context = runtime.default_context()
	size         := u64(fs.DEFAULT_IMAGE_SIZE)
	cluster_size := u64(fs.DEFAULT_CLUSTER_SIZE)
	output_path  := "fused.img"
	embed_demo   := true

	for arg in os.args[1:] {
		switch {
		case strings.has_prefix(arg, "--size="):
			v, ok := parse_size(arg[7:])
			if !ok {fmt.eprintln("invalid --size:", arg[7:]); os.exit(1)}
			size = v
		case strings.has_prefix(arg, "--cluster-size="):
			v := u64(strconv.parse_int(arg[15:]) or_else 0)
			if v == 0 || v > 65536 {fmt.eprintln("invalid --cluster-size:", arg[15:]); os.exit(1)}
			cluster_size = v
		case strings.has_prefix(arg, "--output="):
			output_path = arg[9:]
		case arg == "--no-demo":
			embed_demo = false
		case:
			fmt.eprintln("unknown flag:", arg)
			fmt.eprintln("usage: disker [--size=N] [--cluster-size=N] [--output=path] [--no-demo]")
			os.exit(1)
		}
	}

	if size < 512 * (cluster_size + 2) {
		fmt.eprintln("image too small for the given cluster size")
		os.exit(1)
	}

	fmt.printf("Formatting %v bytes with cluster_size=%v → %s\n", size, cluster_size, output_path)

	fd, open_err := os.open(output_path, {.Create, .Write, .Trunc})
	if open_err != nil {
		fmt.eprintln("cannot create", output_path, ":", open_err)
		os.exit(1)
	}
	defer os.close(fd)

	os.truncate(fd, i64(size))
	total_sectors  := size / fs.SECTOR_SIZE
	total_clusters := total_sectors / cluster_size

	entries_per_sector := u64(fs.CLUSTER_ENTRIES_PER_SECTOR)
	cluster_map_sectors := (total_clusters + entries_per_sector - 1) / entries_per_sector

	reserved_clusters := (cluster_map_sectors + 1 + cluster_size - 1) / cluster_size
	root_cluster      := reserved_clusters
	root_sector_index := u16(1) // data starts after the one-sector ClusterEntry table

	master: fs.Master_Record
	master.sig = [7]u8{'F', 'U', 'S', 'E', 'D', 0, 0}
	master.rev = 2
	master.cluster_map_offset = 1
	master.cluster_map_size   = total_clusters
	master.cluster_size       = cluster_size
	master.root_sector_index  = root_sector_index
	master.root_cluster       = root_cluster
	master.end_sig = 0x0BB0

	write_master(fd, &master)
	reserved_flags: fs.Cluster_Map_Flags
	reserved_flags += {.Reserved, .Full}
	reserved_entry := fs.Cluster_Map_Entry{flags = reserved_flags}
	for _ in 0 ..< reserved_clusters {
		write_cluster_map_entry(fd, &reserved_entry)
	}

	initial_flags: fs.Cluster_Map_Flags
	initial_flags += {.Allocated}
	initial_entry := fs.Cluster_Map_Entry{stored_cluster = root_cluster, flags = initial_flags}
	write_cluster_map_entry(fd, &initial_entry)

	empty_entry: fs.Cluster_Map_Entry
	remaining_entries := total_clusters - reserved_clusters - 1
	for _ in 0 ..< remaining_entries {
		write_cluster_map_entry(fd, &empty_entry)
	}

	seek_to_sector(fd, fs.Sector(u64(root_cluster) * cluster_size))
	cm_state: fs.Cluster_Entry_State
	cm_state += {.Allocated, .Cluster_Map}
	cm_entry := fs.Cluster_Entry{state = cm_state, allocation_size = 1, sector_start = 0}
	write_cluster_entry(fd, &cm_entry)

	rd_state: fs.Cluster_Entry_State
	rd_state += {.Allocated, .Directory}
	rd_entry := fs.Cluster_Entry{state = rd_state, allocation_size = 1, sector_start = 1}
	write_cluster_entry(fd, &rd_entry)

	file_entry: fs.Cluster_Entry
	if embed_demo {
		fc_state: fs.Cluster_Entry_State
		fc_state += {.Allocated, .File_Content}
		demo_content := [?]u8{
			0x82, 0x00, 0x0d, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x81,
			0x00, 0x06, 0x4b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x82, 0x03,
			0x06, 0x06, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x81, 0x00,
			0x05, 0x4b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x82, 0x03, 0x05,
			0x06, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc8, 0x00, 0x5b,
		}

		demo_sectors := u16((len(demo_content) + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE)
		file_entry = fs.Cluster_Entry{
			state = fc_state, allocation_size = demo_sectors, sector_start = 2,
		}

		write_cluster_entry(fd, &file_entry)
		for _ in 0 ..< 29 {
			empty_ce: fs.Cluster_Entry
			write_cluster_entry(fd, &empty_ce)
		}
	} else {
		for _ in 0 ..< 30 {
			empty_ce: fs.Cluster_Entry
			write_cluster_entry(fd, &empty_ce)
		}
	}

	seek_to_sector(fd, fs.Sector(u64(root_cluster)*cluster_size + 1))
	zero_sector: [fs.SECTOR_SIZE]u8
	_, _ = os.write(fd, zero_sector[:])
	if embed_demo {
		now := time.now()
		y, mo, d := time.date(now)
		year := u16(y)
		h, m, s := time.clock(now)

		dt: fs.Packed_Date_Time
		dt.month  = u32(int(mo))
		dt.date   = u32(d)
		dt.hour   = u32(h)
		dt.minute = u32(m)
		dt.second = u32(s)

		demo_flags: fs.Dir_Flags
		demo_flags += {.Allocated, .Exists}
		demo_content := [?]u8{
			0x82, 0x00, 0x0d, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x81,
			0x00, 0x06, 0x4b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x82, 0x03,
			0x06, 0x06, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x81, 0x00,
			0x05, 0x4b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x82, 0x03, 0x05,
			0x06, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc8, 0x00, 0x5b,
		}
		demo := fs.Directory_Entry{
			flags          = demo_flags,
			sector_index   = 2,
			stored_cluster = root_cluster,
			year           = year,
			date_time      = dt,
			file_size      = u64(len(demo_content)),
		}

		demo_file_name := "Kernel"
		copy(demo.file_name[:], transmute([]u8)(demo_file_name))
		seek_to_sector(fd, fs.Sector(u64(root_cluster)*cluster_size + 1))

		sector_buf: [fs.SECTOR_SIZE]u8
		_, _ = os.read(fd, sector_buf[:])
		(^fs.Directory_Entry)(raw_data(sector_buf[:]))^ = demo
		seek_to_sector(fd, fs.Sector(u64(root_cluster)*cluster_size + 1))
		_, _ = os.write(fd, sector_buf[:])

		seek_to_sector(fd, fs.Sector(u64(root_cluster)*cluster_size + 2))
		content_buf: [fs.SECTOR_SIZE]u8
		copy(content_buf[:], demo_content[:])
		_, _ = os.write(fd, content_buf[:])
	}
	fmt.println("Done.")
}

write_master :: proc(fd: ^os.File, m: ^fs.Master_Record) {
	buf: [fs.SECTOR_SIZE]u8
	(^fs.Master_Record)(raw_data(buf[:]))^ = m^
	seek_to_sector(fd, 0)
	_, _ = os.write(fd, buf[:])
}

write_cluster_map_entry :: proc(fd: ^os.File, e: ^fs.Cluster_Map_Entry) {
	buf: [size_of(fs.Cluster_Map_Entry)]u8
	(^fs.Cluster_Map_Entry)(raw_data(buf[:]))^ = e^
	_, _ = os.write(fd, buf[:])
}

write_cluster_entry :: proc(fd: ^os.File, e: ^fs.Cluster_Entry) {
	buf: [size_of(fs.Cluster_Entry)]u8
	(^fs.Cluster_Entry)(raw_data(buf[:]))^ = e^
	_, _ = os.write(fd, buf[:])
}

seek_to_sector :: proc(fd: ^os.File, sector: fs.Sector) {
	os.seek(fd, i64(u64(sector) * fs.SECTOR_SIZE), io.Seek_From.Start)
}

parse_size :: proc(s: string) -> (u64, bool) {
	mult: u64 = 1
	str := s
	if strings.has_suffix(s, "K") || strings.has_suffix(s, "k") {
		mult = 1024; str = s[:len(s)-1]
	} else if strings.has_suffix(s, "M") || strings.has_suffix(s, "m") {
		mult = 1024 * 1024; str = s[:len(s)-1]
	} else if strings.has_suffix(s, "G") || strings.has_suffix(s, "g") {
		mult = 1024 * 1024 * 1024; str = s[:len(s)-1]
	}
	v, ok := strconv.parse_uint(str)
	return u64(v) * mult, ok
}
