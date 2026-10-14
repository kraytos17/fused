// main.odin — fused image dumper CLI entry point.
#+build linux
package main

import "base:runtime"
import "core:flags"
import "core:log"
import "core:os"
import "src:fs"
import "src:logflags"

// Flags holds the CLI flags for the image dumper.
Flags :: struct {
	path:      string `args:"pos=0,required" usage:"Path to the fused disk image (.img file)"`,
	json:      bool `args:"name=json" usage:"Output as JSON (machine-readable)"`,
	all:       bool `args:"name=all" usage:"Show all clusters including empty ones in text mode"`,
	hex_path:  string `args:"name=hex" usage:"Dump file contents as hex (e.g. --hex=/Kernel or --hex for root)"`,
	log_level: log.Level `args:"name=log-level" usage:"Log level: debug, info, warn, error (default: debug)"`,
	overflow:  [dynamic]string `args:"hidden"`,
}

// Dump_Mode selects one dumper output. Derived once from flags so the
// dispatch below is a single switch instead of re-testing flag combos.
Dump_Mode :: enum {
	Text,
	Json,
	Hex,
}

// main is the CLI entry point for the dumper. It opens the image, parses
// flags, and dispatches to text or JSON output.
main :: proc() {
	context = runtime.default_context()

	f: Flags
	flags.register_type_setter(logflags.set_log_level)
	flags.parse_or_exit(&f, os.args, flags.Parsing_Style.Unix)
	if len(f.overflow) > 0 {
		for arg in f.overflow {
			if arg == "--hex" {
				log.errorf("--hex requires a value (e.g. --hex=/Kernel)")
				os.exit(1)
			}
		}

		log.errorf("unknown args: %v", f.overflow)
		os.exit(1)
	}
	if f.json && f.hex_path != "" {
		log.errorf("--json and --hex are mutually exclusive")
		os.exit(1)
	}

	mode := Dump_Mode.Text
	if f.hex_path != "" {
		mode = .Hex
	} else if f.json {
		mode = .Json
	}

	context.logger = log.create_file_logger(os.stderr, f.log_level, log.Default_File_Logger_Opts)
	vol, verr := fs.volume_open(f.path)
	if verr != .None {
		log.errorf("cannot open %s: %v", f.path, verr)
		os.exit(1)
	}

	defer fs.volume_close(&vol)
	switch mode {
	case .Hex:
		print_hex_by_path(&vol, f.hex_path)
	case .Json:
		print_json(&vol)
	case .Text:
		print_master(&vol, false, nil)
		print_cluster_map(&vol, false, nil, f.all)
		print_directory_tree(&vol, false, nil)
	}
}
