// main.odin — fused image formatter.
//
// Formats a raw disk image with the MasterRecord, ClusterMap region,
// initial ClusterEntry tables for the root directory, and an optional
// demo file.  No FUSE dependency — can be built and run without libfuse3.
#+build linux
package main

import "base:runtime"
import "core:io"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "src:fs"

DEMO_CONTENT := [?]u8{
	0x82, 0x00, 0x0d, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x81,
	0x00, 0x06, 0x4b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x82, 0x03,
	0x06, 0x06, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x81, 0x00,
	0x05, 0x4b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x82, 0x03, 0x05,
	0x06, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc8, 0x00, 0x5b,
}

main :: proc() {
	context = runtime.default_context()
	size         := u64(fs.DEFAULT_IMAGE_SIZE)
	cluster_size := u64(fs.DEFAULT_CLUSTER_SIZE)
	output_path  := "fused.img"
	embed_demo   := true

	for arg in os.args[1:] {
		switch {
		case strings.has_prefix(arg, "--size="):
			s, ok := parse_size(strings.trim_prefix(arg, "--size="))
			if !ok {
				log.fatalf("invalid --size: %s", arg)
			}
			size = s
		case strings.has_prefix(arg, "--cluster-size="):
			rest := strings.trim_prefix(arg, "--cluster-size=")
			v := u64(strconv.parse_int(rest) or_else 0)
			if v == 0 || v > 65536 {
				log.fatalf("invalid --cluster-size: %s", rest)
			}
			cluster_size = v
		case strings.has_prefix(arg, "--output="):
			output_path = strings.trim_prefix(arg, "--output=")
		case arg == "--no-demo":
			embed_demo = false
		case:
			log.errorf("unknown flag: %s", arg)
			log.errorf("usage: disker [--size=N] [--cluster-size=N] [--output=path] [--no-demo]")
			os.exit(1)
		}
	}
	if size < 512 * (cluster_size + 2) {
		log.fatalf("image too small for the given cluster size")
	}

	log.infof("formatting %v bytes with cluster_size=%v → %s", size, cluster_size, output_path)

	fd, open_err := os.open(output_path, {.Create, .Write, .Trunc})
	if open_err != nil {
		log.fatalf("cannot create %s: %v", output_path, open_err)
	}
	defer os.close(fd)

	trunc_err := os.truncate(fd, i64(size))
	if trunc_err != nil {
		log.fatalf("truncate failed: %v", trunc_err)
	}

	total_sectors  := size / fs.SECTOR_SIZE
	total_clusters := total_sectors / cluster_size

	entries_per_sector := u64(fs.CLUSTER_ENTRIES_PER_SECTOR)
	cluster_map_sectors := (total_clusters + entries_per_sector - 1) / entries_per_sector
	reserved_clusters := (cluster_map_sectors + 1 + cluster_size - 1) / cluster_size
	root_cluster := reserved_clusters

	master: fs.Master_Record
	master.sig = fs.FUSED_SIG
	master.rev = 3
	master.cluster_map_offset = 1
	master.cluster_map_size = total_clusters
	master.cluster_size = cluster_size
	master.root_sector_index  = 1
	master.root_cluster = root_cluster
	master.end_sig = 0x0BB0

	write_master(fd, &master)
	map_count := int(total_clusters)
	map_buf := make([]u8, map_count * size_of(fs.Cluster_Map_Entry))
	map_table := cast([^]fs.Cluster_Map_Entry)(raw_data(map_buf))
	for i in 0 ..< int(reserved_clusters) {
		map_table[i] = fs.Cluster_Map_Entry{
			flags = fs.Cluster_Map_Flags{.Reserved, .Full},
		}
	}
	map_table[reserved_clusters] = fs.Cluster_Map_Entry{
		stored_cluster = root_cluster,
		flags          = fs.Cluster_Map_Flags{.Allocated},
	}

	must_write(fd, map_buf, "ClusterMap array")
	seek_to_sector(fd, fs.Sector(u64(root_cluster) * cluster_size))

	ce_buf: [fs.SECTOR_SIZE]u8
	ce_table := (^[fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry)(raw_data(ce_buf[:]))
	ce_table[0] = fs.Cluster_Entry{
		state = fs.Cluster_Entry_State{.Allocated, .Cluster_Map},
		allocation_size = 1,
		sector_start = 0,
	}
	ce_table[1] = fs.Cluster_Entry{
		state = fs.Cluster_Entry_State{.Allocated, .Directory},
		allocation_size = 1,
		sector_start = 1,
	}
	if embed_demo {
		demo_sectors := u16((len(DEMO_CONTENT) + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE)
		ce_table[2] = fs.Cluster_Entry{state = fs.Cluster_Entry_State{.Allocated, .File_Content}, allocation_size = demo_sectors, sector_start = 2}
	}

	must_write(fd, ce_buf[:], "ClusterEntry table")
	seek_to_sector(fd, fs.Sector(u64(root_cluster)*cluster_size + 1))
	dir_sector: [fs.SECTOR_SIZE]u8
	if embed_demo {
		now := time.now()
		y, mo, d := time.date(now)
		h, m, s := time.clock(now)
		demo_entry := fs.Directory_Entry{
			flags = fs.Dir_Flags{.Allocated, .Exists},
			sector_index = 2, stored_cluster = root_cluster, year = u16(y),
			date_time = fs.Packed_Date_Time{
				month = u32(int(mo)), date = u32(d),
				hour = u32(h), minute = u32(m), second = u32(s),
			},
			atime_year = u16(y),
			atime_date_time = fs.Packed_Date_Time{
				month = u32(int(mo)), date = u32(d),
				hour = u32(h), minute = u32(m), second = u32(s),
			},
			file_size = u64(len(DEMO_CONTENT)),
		}
		copy(demo_entry.file_name[:], "Kernel")
		(^fs.Directory_Entry)(raw_data(dir_sector[:]))^ = demo_entry
	}

	must_write(fd, dir_sector[:], "root directory sector")
	if embed_demo {
		seek_to_sector(fd, fs.Sector(u64(root_cluster)*cluster_size + 2))
		content_buf: [fs.SECTOR_SIZE]u8
		copy(content_buf[:], DEMO_CONTENT[:])
		must_write(fd, content_buf[:], "demo file content")
	}
	log.infof("done: %s", output_path)
}

write_master :: proc(fd: ^os.File, m: ^fs.Master_Record) {
	buf: [fs.SECTOR_SIZE]u8
	(^fs.Master_Record)(raw_data(buf[:]))^ = m^
	seek_to_sector(fd, 0)
	must_write(fd, buf[:], "MasterRecord")
}

seek_to_sector :: proc(fd: ^os.File, sector: fs.Sector) {
	_, seek_err := os.seek(fd, i64(u64(sector) * fs.SECTOR_SIZE), io.Seek_From.Start)
	if seek_err != nil {
		log.fatalf("seek to sector %d failed: %v", sector, seek_err)
	}
}

must_write :: proc(fd: ^os.File, data: []u8, label: string) {
	_, err := os.write(fd, data)
	if err != nil {
		log.fatalf("write %s failed: %v", label, err)
	}
}

parse_size :: proc(s: string) -> (u64, bool) {
	mult: u64 = 1
	str := s
	if strings.has_suffix(s, "K") || strings.has_suffix(s, "k") {
		mult = 1024
		str = s[:len(s)-1]
	} else if strings.has_suffix(s, "M") || strings.has_suffix(s, "m") {
		mult = 1024 * 1024
		str = s[:len(s)-1]
	} else if strings.has_suffix(s, "G") || strings.has_suffix(s, "g") {
		mult = 1024 * 1024 * 1024
		str = s[:len(s)-1]
	}
	v, ok := strconv.parse_uint(str)
	return u64(v) * mult, ok
}
