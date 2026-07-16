// main.odin — fused image dumper CLI entry point.
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
	all:      bool,
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
	if !ok {
		log.errorf("failed to read MasterRecord")
		os.exit(1)
    }

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

	needs_comma: bool
	if flags.json { fmt.print(`{`) }

	print_master(fd, &master, flags.json, &needs_comma)
	print_cluster_map(fd, &master, flags.json, &needs_comma, flags.all)
	print_directory_tree(fd, &master, flags.json, &needs_comma)
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
		case arg == "--all":
			f.all = true
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
  --all              Show all clusters (including empty) in text mode
  --help, -h         Show this help

Examples:
  imgdump fused.img
  imgdump --json fused.img | jq '.clusters[] | select(.flags == "ALLOCATED")'
  imgdump --hex=/Kernel fused.img`)
}
