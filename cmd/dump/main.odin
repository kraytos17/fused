// main.odin — fused image dumper CLI entry point.
#+build linux
package main

import "base:runtime"
import "core:flags"
import "core:log"
import "core:os"
import "src:fs"

// Flags holds the CLI flags for the image dumper.
Flags :: struct {
	path:     string `args:"pos=0,required" usage:"Path to the fused disk image (.img file)"`,
	json:     bool   `args:"name=json" usage:"Output as JSON (machine-readable)"`,
	all:      bool   `args:"name=all" usage:"Show all clusters including empty ones in text mode"`,
	hex_path: string `args:"name=hex" usage:"Dump file contents as hex (e.g. --hex=/Kernel or --hex for root)"`,
	log_level: string `args:"name=log-level" usage:"Log level: debug, info, warn, error (default: debug)"`,
	overflow: [dynamic]string `args:"hidden"`,
}

// main is the CLI entry point for the dumper. It opens the image, parses
// flags, and dispatches to text or JSON output.
main :: proc() {
	context = runtime.default_context()

	f: Flags
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
	}

	context.logger = log.create_file_logger(os.stderr, log_level, log.Default_File_Logger_Opts)
	vol, verr := fs.volume_open(f.path)
	if verr != .None {
		log.errorf("cannot open %s: %v", f.path, verr)
		os.exit(1)
	}
	defer fs.volume_close(&vol)

	if f.hex_path != "" {
		hex_path := f.hex_path
		print_hex_by_path(&vol, hex_path)
		return
	}

	if f.json {
		print_json(&vol)
		return
	}

	print_master(&vol, false, nil)
	print_cluster_map(&vol, false, nil, f.all)
	print_directory_tree(&vol, false, nil)
}
