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
import "src:fs"

// DEMO_CONTENT is the embedded demo file content (a small binary blob).
DEMO_CONTENT := [?]u8{
	0x82, 0x00, 0x0d, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x81,
	0x00, 0x06, 0x4b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x82, 0x03,
	0x06, 0x06, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x81, 0x00,
	0x05, 0x4b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x82, 0x03, 0x05,
	0x06, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc8, 0x00, 0x5b,
}

// Flags holds the CLI flags for the formatter.
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

main :: proc() {
	context = runtime.default_context()

	f: Flags
	f.size_str = "1M"
	f.cluster_str = "16"
	f.output = "fused.img"

	flags.parse_or_exit(&f, os.args, flags.Parsing_Style.Unix)
	if len(f.overflow) > 0 {
		log.errorf("unknown args: %v", f.overflow)
		os.exit(1)
	}

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

	cluster_size := u64(strconv.parse_uint(f.cluster_str) or_else 0)
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

	if ferr := fs.format_image(fd, {
		size         = size,
		cluster_size = cluster_size,
		features     = fs.Features{.Uid_Gid, .Journal_V2, .XAttr},
		rev_min      = 8,
		rev_max      = 8,
		demo_data    = demo_data,
	}); ferr != .None {
		log.errorf("format failed: %v", ferr)
		os.exit(1)
	}

	if f.verbose {
		image_mb := f64(size) / (1024.0 * 1024.0)
		g := fs.format_geometry(size, cluster_size)
		log.infof("done: %s  (%.1f MB, %d clusters  %d/sector CME  %d CME sectors  %d reserved)",
			f.output, image_mb, g.total_clusters, fs.CLUSTER_MAP_ENTRIES_PER_SECTOR, g.cm_sectors, g.reserved_clusters)
	}
}

// parse_size parses size strings with K, M, or G suffix (e.g. "1M", "256K", "1G").
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
