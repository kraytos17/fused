// main.odin — fused FUSE mounter binary entry point.
//
// Owns all process concerns: argv partitioning (fused --log-* flags vs
// opaque FUSE passthrough, which core:flags cannot express — unknown flags
// abort its parsing), log-level/format mapping, usage text, and exit codes.
// The mounter library takes a pre-split Mount_Options and never reads
// os.args or terminates the process.
#+build linux
package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "src:fs"
import "src:logflags"
import "src:mounter"

usage :: proc() {
	fmt.println(
		"Usage: fused [--log-file=<path>] [--log-level=<level>] [--log-format=<format>] <image-path> [fuse-options...] <mountpoint>",
	)
	fmt.println("Levels:  debug, info, warn, error  (default: debug)")
	fmt.println(
		"Formats: long (default, date/time/location), short (level only), full (level + thread id)",
	)
	fmt.println("Flags:   --log-file=<path>  --log-level=<level>  --log-format=<format>")
	fmt.println("         --path-cache-cap=<n>  --lfn-cache-cap=<n>  --alloc-cache-cap=<n>")
	fmt.println("         -f (foreground, default), -d (FUSE debug), -s (single-threaded)")
	fmt.println("         -h shows FUSE help when mounting; bare -h shows this text")
}

// main is the binary entry point. It partitions argv, maps log options,
// and calls mounter.run() via the FUSE event loop.
//
// `--help` anywhere prints fused usage. A bare `-h` (no image+mountpoint to
// mount) also prints fused usage; otherwise `-h` passes through to FUSE,
// which prints its own option help.
main :: proc() {
	context = runtime.default_context()
	for arg in os.args[1:] {
		if arg == "--help" {
			usage()
			os.exit(0)
		}
	}

	log_file_path: string
	log_level := log.Level.Debug
	log_opts := log.Default_Console_Logger_Opts
	cache := fs.DEFAULT_CACHE_CONFIG
	fuse_args: [dynamic]string
	defer delete(fuse_args)

	parse_cache_cap :: proc(arg, prefix: string, dst: ^int) -> bool {
		n := strconv.parse_uint(strings.trim_prefix(arg, prefix)) or_else 0
		if n == 0 {
			return false
		}

		dst^ = int(n)
		return true
	}

	for arg in os.args[1:] {
		switch {
		case strings.has_prefix(arg, "--log-file="):
			log_file_path = strings.trim_prefix(arg, "--log-file=")
		case strings.has_prefix(arg, "--log-level="):
			level_str := strings.trim_prefix(arg, "--log-level=")
			lvl, ok := logflags.parse_log_level(level_str)
			if !ok {
				fmt.eprintf("unknown log level: %s (use debug|info|warn|error)\n", level_str)
				os.exit(1)
			}
			log_level = lvl
		case strings.has_prefix(arg, "--path-cache-cap="):
			if !parse_cache_cap(arg, "--path-cache-cap=", &cache.path_cap) {
				fmt.eprintf("invalid --path-cache-cap (want positive int)\n")
				os.exit(1)
			}
		case strings.has_prefix(arg, "--lfn-cache-cap="):
			if !parse_cache_cap(arg, "--lfn-cache-cap=", &cache.lfn_cap) {
				fmt.eprintf("invalid --lfn-cache-cap (want positive int)\n")
				os.exit(1)
			}
		case strings.has_prefix(arg, "--alloc-cache-cap="):
			if !parse_cache_cap(arg, "--alloc-cache-cap=", &cache.alloc_cap) {
				fmt.eprintf("invalid --alloc-cache-cap (want positive int)\n")
				os.exit(1)
			}
		case strings.has_prefix(arg, "--log-format="):
			fmt_str := strings.trim_prefix(arg, "--log-format=")
			lf, fok := logflags.parse_log_format(fmt_str)
			if !fok {
				fmt.eprintf("unknown log format: %s (use short|long|full)\n", fmt_str)
				os.exit(1)
			}
			log_opts = logflags.log_format_opts(lf)
		case:
			append(&fuse_args, arg)
		}
	}

	// A bare -h with nothing mountable prints fused usage; otherwise -h
	// passes through to FUSE.
	has_help := false
	for a in fuse_args {
		if a == "-h" {
			has_help = true
			break
		}
	}
	if has_help && len(fuse_args) < 2 {
		usage()
		os.exit(0)
	}
	if len(fuse_args) < 1 {
		fmt.eprintf(
			"usage: fused [--log-file=<path>] [--log-level=<level>] <image-path> [fuse-options...] <mountpoint>\n",
		)
		os.exit(1)
	}

	ok := mounter.run(
		{
			image_path = fuse_args[0],
			log_file_path = log_file_path,
			log_level = log_level,
			log_opts = log_opts,
			fuse_args = fuse_args[1:],
			cache = cache,
		},
	)
	if !ok {
		os.exit(1)
	}
}
