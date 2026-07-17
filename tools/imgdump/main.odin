// main.odin — fused image dumper CLI entry point.
#+build linux
package main

import "base:runtime"
import "core:flags"
import "core:fmt"
import "core:log"
import "core:os"
import "src:fs"

Flags :: struct {
	path:     string `args:"pos=0,required" usage:"Path to the fused disk image (.img file)"`,
	json:     bool   `args:"name=json" usage:"Output as JSON (machine-readable)"`,
	all:      bool   `args:"name=all" usage:"Show all clusters including empty ones in text mode"`,
	hex_path: string `args:"name=hex" usage:"Dump file contents as hex (e.g. --hex=/Kernel or --hex for root)"`,
	log_level: string `args:"name=log-level" usage:"Log level: debug, info, warn, error (default: warn)"`,
	overflow: [dynamic]string `args:"hidden"`,
}

main :: proc() {
	context = runtime.default_context()

	f: Flags
	flags.parse_or_exit(&f, os.args, flags.Parsing_Style.Unix)

	log_level := log.Level.Warning
	switch f.log_level {
	case "debug": log_level = log.Level.Debug
	case "info":  log_level = log.Level.Info
	case "warn":  log_level = log.Level.Warning
	case "error": log_level = log.Level.Error
	case:
		log.errorf("unknown log level: %s (use debug|info|warn|error)", f.log_level)
	}

	context.logger = log.create_console_logger(log_level)
	fd, open_err := os.open(f.path, {.Read})
	if open_err != nil {
		log.errorf("cannot open %s: %v", f.path, open_err)
		os.exit(1)
	}
	defer os.close(fd)

	master, ok := fs.read_master_record(fd)
	if !ok {
		log.errorf("failed to read MasterRecord")
		os.exit(1)
    }

	fi, stat_err := os.stat(f.path, context.temp_allocator)
	image_size: u64 = 0
	if stat_err == nil {
		image_size = u64(fi.size)
	}
	if err := fs.validate_master(&master, image_size); err != .None {
		log.errorf("validation failed: %v", err)
		os.exit(1)
	}
	if f.hex_path != "" {
		hex_path := f.hex_path
		print_hex_by_path(fd, &master, hex_path)
		return
	}

	needs_comma: bool
	if f.json {
		fmt.print(`{`)
	}

	print_master(fd, &master, f.json, &needs_comma)
	print_cluster_map(fd, &master, f.json, &needs_comma, f.all)
	print_directory_tree(fd, &master, f.json, &needs_comma)
	if f.json {
		fmt.println(`}`)
	}
}
