// main.odin — fused image formatter.
//
// Formats a raw disk image by writing sequentially from sector 0:
//   MasterRecord → ClusterMap table (sector-by-sector)
//   → root cluster (CE table, directory, optional demo file).
// No FUSE dependency — builds without libfuse3.
#+build linux
package main

import "base:runtime"
import "core:flags"
import "core:log"
import "core:os"
import "core:strconv"
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
	size_str:     string `args:"name=size" usage:"Image size (e.g. 1M, 256M, 1G; default: 1M)"`,
	cluster_str:  string `args:"name=cluster-size" usage:"Sectors per cluster (default: 16)"`,
	output:       string `args:"pos=0" usage:"Output image path (default: fused.img)"`,
	demo_file:    string `args:"name=demo-file" usage:"File to embed as /Kernel (default: embedded demo)"`,
	no_demo:      bool   `args:"name=no-demo" usage:"Do not embed a demo file"`,
	verbose:      bool   `args:"name=verbose" usage:"Show progress for large images"`,
	force:        bool   `args:"name=force" usage:"Overwrite existing output"`,
	log_level:    string `args:"name=log-level" usage:"Log level: debug, info, warn, error (default: debug)"`,
	overflow: [dynamic]string `args:"hidden"`,
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

	f: Flags
	f.size_str = "1M"
	f.cluster_str = "16"
	f.output = "fused.img"

	flags.parse_or_exit(&f, os.args, flags.Parsing_Style.Unix)
	log_level := log.Level.Debug
	switch f.log_level {
	case "debug": log_level = log.Level.Debug
	case "info":  log_level = log.Level.Info
	case "warn":  log_level = log.Level.Warning
	case "error": log_level = log.Level.Error
	case "":
	case:
		log.errorf("unknown log level: %s (use debug|info|warn|error)", f.log_level)
		os.exit(1)
	}

	context.logger = log.create_console_logger(log_level)
	size, size_ok := parse_size(f.size_str)
	if !size_ok {
		log.errorf("invalid --size: %s", f.size_str)
		os.exit(1)
	}

	cluster_size := u64(strconv.parse_int(f.cluster_str) or_else 0)
	if cluster_size == 0 || cluster_size > 65536 {
		log.errorf("invalid --cluster-size: %s", f.cluster_str)
		os.exit(1)
	}
	if size < fs.SECTOR_SIZE * (cluster_size + 2) {
		log.errorf("image too small: need at least %d bytes for cluster_size=%d",
			fs.SECTOR_SIZE * (cluster_size + 2), cluster_size)
		os.exit(1)
	}
	if !f.force {
		if _, err := os.stat(f.output, context.temp_allocator); err == nil {
			log.errorf("%s exists; use --force to overwrite", f.output)
			os.exit(1)
		}
	}

	fd, open_err := os.open(f.output, {.Create, .Write, .Trunc})
	if open_err != nil {
		log.errorf("cannot create %s: %v", f.output, open_err)
		os.exit(1)
	}
	defer os.close(fd)

	trunc_err := os.truncate(fd, i64(size))
	if trunc_err != nil {
		log.errorf("truncate to %d failed: %v", size, trunc_err)
		os.exit(1)
	}
	if f.verbose {
		log.infof("formatting %s: size=%d cluster_size=%d",
			f.output, size, cluster_size)
	}

	demo_data: []u8
	needs_free := false
	if f.no_demo {
		demo_data = {}
	} else if f.demo_file != "" {
		data, err := os.read_entire_file(f.demo_file, context.allocator)
		if err != nil {
			log.warnf("cannot read demo file %s; using embedded demo", f.demo_file)
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
	total_sectors := size / fs.SECTOR_SIZE
	total_clusters := total_sectors / cluster_size

	cme_per_sector := u64(fs.CLUSTER_MAP_ENTRIES_PER_SECTOR)
	cm_sectors := (total_clusters + cme_per_sector - 1) / cme_per_sector
	journal_sectors := max(64, total_clusters / 10)
	metadata_sectors := 1 + cm_sectors + journal_sectors
	reserved_clusters := (metadata_sectors + cluster_size - 1) / cluster_size
	root_cluster := reserved_clusters

	master: fs.Master_Record
	master.sig = fs.FUSED_SIG
	master.rev_min = 7
	master.rev_max = 7
	master.features = fs.Features{.Uid_Gid, .Journal_V2}
	master.cluster_map_offset = 1
	master.cluster_map_size = total_clusters
	master.cluster_size = cluster_size
	ce_sectors := u64(1)
	master.root_sector_index = u16(ce_sectors)
	master.root_cluster = root_cluster
	master.end_sig = 0x0BB0
	// Compute journal region size: max(64, total_clusters / 10) sectors
	journal_sectors = max(64, total_clusters / 10)
	fs.journal_v2_set_region_size(&master, journal_sectors)
	fs.journal_seq_init(&master)
	{
		master_buf: [fs.SECTOR_SIZE]u8
		(^fs.Master_Record)(&master_buf[0])^ = master
		if !writer_write(&w, master_buf[:]) {
			log.errorf("write master failed")
			os.exit(1)
		}
	}
	{
		report_interval := max(1, cm_sectors / 10)
		for sec_idx: u64; sec_idx < cm_sectors; sec_idx += 1 {
			sec_buf: [fs.SECTOR_SIZE]u8
			entries := (^[fs.CLUSTER_MAP_ENTRIES_PER_SECTOR]fs.Cluster_Map_Entry)(&sec_buf[0])
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
			if !writer_write(&w, sec_buf[:]) {
				log.errorf("write cluster map failed")
				os.exit(1)
			}
			if f.verbose && cm_sectors > 100 && sec_idx % report_interval == 0 {
				log.infof("  cluster map: %d/%d sectors", sec_idx + 1, cm_sectors)
			}
		}
	}

	// Zero the journal region (right after CME table)
	jrnl_start := fs.intent_log_sector(&master)
	jrnl_sectors := fs.journal_v2_region_size(&master)
	w.pos = i64(u64(jrnl_start) * fs.SECTOR_SIZE)
	jrnl_zero: [fs.SECTOR_SIZE]u8
	for i: u64; i < jrnl_sectors; i += 1 {
		if !writer_write(&w, jrnl_zero[:]) { os.exit(1) }
	}

	root_sector := i64(u64(root_cluster) * cluster_size)
	w.pos = root_sector * fs.SECTOR_SIZE
	{
		ce_buf: [fs.SECTOR_SIZE]u8
		ce_table := (^[fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry)(&ce_buf[0])
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
			log.errorf("write CE table failed")
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
			(^fs.Directory_Entry)(&dir_buf[0])^ = entry
		}
		if !writer_write(&w, dir_buf[:]) {
			log.errorf("write directory entry failed")
			os.exit(1)
		}
		if len(demo_data) > 0 {
			content_buf: [fs.SECTOR_SIZE]u8
			copy(content_buf[:], demo_data)
			if !writer_write(&w, content_buf[:]) {
				log.errorf("write file content failed")
				os.exit(1)
			}
		}
	}

	if f.verbose {
		image_mb := f64(size) / (1024.0 * 1024.0)
		log.infof("done: %s  (%.1f MB, %d clusters  %d/sector CME  %d CME sectors  %d reserved)",
			f.output, image_mb, total_clusters, fs.CLUSTER_MAP_ENTRIES_PER_SECTOR, cm_sectors, reserved_clusters)
	}
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
