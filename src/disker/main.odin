// main.odin — fused image formatter.
//
// Formats a raw disk image by writing sequentially from sector 0:
//   MasterRecord → ClusterMap table (sector-by-sector)
//   → root cluster (CE table, directory, optional demo file).
// No FUSE dependency — builds without libfuse3.
#+build linux
package main

import "base:runtime"
import "core:fmt"
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

Flags :: struct {
	size:         u64,
	cluster_size: u64,
	output:       string,
	demo_file:    string,
	no_demo:      bool,
	verbose:      bool,
	force:        bool,
}

Writer :: struct {
	fd:  ^os.File,
	pos: i64,
}

writer_init :: proc(w: ^Writer, fd: ^os.File) {
	w.fd = fd
	w.pos = 0
}

writer_write :: proc(w: ^Writer, data: []u8) -> bool {
	_, err := os.write_at(w.fd, data, w.pos)
	if err != nil {
		log.errorf("write at %d failed: %v", w.pos, err)
		return false
	}
	w.pos += i64(len(data))
	return true
}

main :: proc() {
	context = runtime.default_context()
	context.logger = log.create_console_logger(log.Level.Info)
	flags := parse_args()
	if flags.size < fs.SECTOR_SIZE * (flags.cluster_size + 2) {
		log.errorf("image too small: need at least %d bytes for cluster_size=%d",
			fs.SECTOR_SIZE * (flags.cluster_size + 2), flags.cluster_size)
		os.exit(1)
	}
	if !flags.force {
		if _, err := os.stat(flags.output, context.temp_allocator); err == nil {
			log.errorf("%s exists; use --force to overwrite", flags.output)
			os.exit(1)
		}
	}

	fd, open_err := os.open(flags.output, {.Create, .Write, .Trunc})
	if open_err != nil {
		log.errorf("cannot create %s: %v", flags.output, open_err)
		os.exit(1)
	}
	defer os.close(fd)

	trunc_err := os.truncate(fd, i64(flags.size))
	if trunc_err != nil {
		log.fatalf("truncate to %d failed: %v", flags.size, trunc_err)
	}
	if flags.verbose {
		log.infof("formatting %s: size=%d cluster_size=%d",
			flags.output, flags.size, flags.cluster_size)
	}

	demo_data: []u8
	needs_free := false
	if flags.no_demo {
		demo_data = {}
	} else if flags.demo_file != "" {
		data, err := os.read_entire_file(flags.demo_file, context.allocator)
		if err != nil {
			log.warnf("cannot read demo file %s; using embedded demo", flags.demo_file)
			demo_data = DEMO_CONTENT[:]
		} else {
			demo_data = data
			needs_free = true
		}
	} else {
		demo_data = DEMO_CONTENT[:]
	}
	defer if needs_free { delete(demo_data) }

	w: Writer
	writer_init(&w, fd)
	total_sectors  := flags.size / fs.SECTOR_SIZE
	total_clusters := total_sectors / flags.cluster_size

	cme_per_sector := u64(fs.CLUSTER_MAP_ENTRIES_PER_SECTOR)
	cm_sectors     := (total_clusters + cme_per_sector - 1) / cme_per_sector
	reserved_clusters := (cm_sectors + 1 + flags.cluster_size - 1) / flags.cluster_size
	root_cluster := reserved_clusters

	master: fs.Master_Record
	master.sig = fs.FUSED_SIG
	master.rev = 4
	master.cluster_map_offset = 1
	master.cluster_map_size = total_clusters
	master.cluster_size = flags.cluster_size
	ce_sectors := u64(1)
	master.root_sector_index = u16(ce_sectors)
	master.root_cluster = root_cluster
	master.end_sig = 0x0BB0
	{
		master_buf: [fs.SECTOR_SIZE]u8
		(^fs.Master_Record)(raw_data(master_buf[:]))^ = master
		if !writer_write(&w, master_buf[:]) { os.exit(1) }
	}
	{
		report_interval := max(1, cm_sectors / 10)
		for sec_idx: u64; sec_idx < cm_sectors; sec_idx += 1 {
			sec_buf: [fs.SECTOR_SIZE]u8
			entries := (^[fs.CLUSTER_MAP_ENTRIES_PER_SECTOR]fs.Cluster_Map_Entry)(raw_data(sec_buf[:]))
			base := int(sec_idx) * fs.CLUSTER_MAP_ENTRIES_PER_SECTOR
			for ei in 0 ..< fs.CLUSTER_MAP_ENTRIES_PER_SECTOR {
				ci := base + ei
				if u64(ci) >= total_clusters { break }
				switch {
				case u64(ci) < reserved_clusters:
					entries[ei] = {flags = {.Reserved, .Full}}
				case u64(ci) == reserved_clusters:
					entries[ei] = {flags = {.Allocated}}
				}
			}
			if !writer_write(&w, sec_buf[:]) { os.exit(1) }
			if flags.verbose && cm_sectors > 100 && sec_idx % report_interval == 0 {
				log.infof("  cluster map: %d/%d sectors", sec_idx + 1, cm_sectors)
			}
		}
	}

	root_sector := i64(u64(root_cluster) * flags.cluster_size)
	w.pos = root_sector * fs.SECTOR_SIZE
	{
		ce_buf: [fs.SECTOR_SIZE]u8
		ce_table := (^[fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry)(raw_data(ce_buf[:]))
		ce_table[0] = {
			state            = {.Allocated, .Cluster_Map},
			allocation_size  = 1,
			sector_start     = 0,
		}
		ce_table[1] = {
			state            = {.Allocated, .Directory},
			allocation_size  = 1,
			sector_start     = 1,
		}
		if len(demo_data) > 0 {
			demo_sectors := u16((len(demo_data) + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE)
			ce_table[2] = {
				state            = {.Allocated, .File_Content},
				allocation_size  = demo_sectors,
				sector_start     = 2,
			}
		}
		if !writer_write(&w, ce_buf[:]) {
			os.exit(1)
		}

		dir_buf: [fs.SECTOR_SIZE]u8
		if len(demo_data) > 0 {
			now := time.now()
			y, mo, d := time.date(now)
			h, m, s := time.clock(now)
			entry := fs.Directory_Entry{
				flags          = {.Allocated, .Exists},
				sector_index   = 2,
				stored_cluster = root_cluster,
				year           = u16(y),
				date_time      = {month = u32(int(mo)), date = u32(d), hour = u32(h), minute = u32(m), second = u32(s)},
				atime_year     = u16(y),
				atime_date_time= {month = u32(int(mo)), date = u32(d), hour = u32(h), minute = u32(m), second = u32(s)},
				file_size      = u64(len(demo_data)),
			}
			copy(entry.file_name[:], "Kernel")
			(^fs.Directory_Entry)(raw_data(dir_buf[:]))^ = entry
		}
		if !writer_write(&w, dir_buf[:]) {
			os.exit(1)
		}
		if len(demo_data) > 0 {
			content_buf: [fs.SECTOR_SIZE]u8
			copy(content_buf[:], demo_data)
			if !writer_write(&w, content_buf[:]) { os.exit(1) }
		}
	}
	if flags.verbose {
		image_mb := f64(flags.size) / (1024.0 * 1024.0)
		log.infof("done: %s  (%.1f MB, %d clusters  %d/sector CME  %d CME sectors  %d reserved)",
			flags.output, image_mb, total_clusters, fs.CLUSTER_MAP_ENTRIES_PER_SECTOR, cm_sectors, reserved_clusters)
	}
}

parse_args :: proc() -> Flags {
	f: Flags = {
		size         = fs.DEFAULT_IMAGE_SIZE,
		cluster_size = fs.DEFAULT_CLUSTER_SIZE,
		output       = "fused.img",
	}

	positional: [dynamic]string
	defer delete(positional)

	for arg in os.args[1:] {
		switch {
		case arg == "--help" || arg == "-h":
			print_help(); os.exit(0)
		case strings.has_prefix(arg, "--size="):
			s, ok := parse_size(strings.trim_prefix(arg, "--size="))
			if !ok { log.errorf("invalid --size: %s", arg); os.exit(1) }
			f.size = s
		case strings.has_prefix(arg, "--cluster-size="):
			v := u64(strconv.parse_int(strings.trim_prefix(arg, "--cluster-size=")) or_else 0)
			if v == 0 || v > 65536 { log.errorf("invalid --cluster-size: %s", arg); os.exit(1) }
			f.cluster_size = v
		case strings.has_prefix(arg, "--output="):
			f.output = strings.trim_prefix(arg, "--output=")
		case strings.has_prefix(arg, "--demo-file="):
			f.demo_file = strings.trim_prefix(arg, "--demo-file=")
		case arg == "--no-demo":
			f.no_demo = true
		case arg == "--verbose" || arg == "-v":
			f.verbose = true
		case arg == "--force" || arg == "-f":
			f.force = true
		case strings.has_prefix(arg, "--"):
			log.errorf("unknown flag: %s", arg)
			print_help(); os.exit(1)
		case:
			append(&positional, arg)
		}
	}
	if len(positional) > 0 {
		f.output = positional[len(positional)-1]
	}
	return f
}

print_help :: proc() {
	fmt.eprintln(`Usage: disker [options] [<output-path>]

Formats a raw disk image for the fused filesystem (rev 4).

Options:
  --size=<N>          Image size (e.g. 1M, 256M, 1G)  (default: 1M)
  --cluster-size=<N>  Sectors per cluster (default: 16)
  --output=<path>     Output image path (default: fused.img)
  --demo-file=<path>  File to embed as /Kernel (default: embedded demo)
  --no-demo           Do not embed a demo file
  --verbose, -v       Show progress for large images
  --force, -f         Overwrite existing output
  --help, -h          Show this help

Examples:
  disker --size=256M --cluster-size=64 --output=big.img
  disker --force fused.img
  disker --demo-file=mykernel.bin --output=os.img
  disker --no-demo fused.img`)
}

parse_size :: proc(s: string) -> (u64, bool) {
	last := s[len(s)-1]
	switch last {
	case 'K', 'k':
		v, ok := strconv.parse_uint(s[:len(s)-1])
		return u64(v) * 1024, ok
	case 'M', 'm':
		v, ok := strconv.parse_uint(s[:len(s)-1])
		return u64(v) * 1024 * 1024, ok
	case 'G', 'g':
		v, ok := strconv.parse_uint(s[:len(s)-1])
		return u64(v) * 1024 * 1024 * 1024, ok
	case:
		v, ok := strconv.parse_uint(s)
		return u64(v), ok
	}
}
