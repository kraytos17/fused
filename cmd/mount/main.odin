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
import "core:strings"
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
	fuse_args: [dynamic]string
	defer delete(fuse_args)

	for arg in os.args[1:] {
		switch {
		case strings.has_prefix(arg, "--log-file="):
			log_file_path = strings.trim_prefix(arg, "--log-file=")
		case strings.has_prefix(arg, "--log-level="):
			level_str := strings.trim_prefix(arg, "--log-level=")
			switch level_str {
			case "debug":
				log_level = log.Level.Debug
			case "info":
				log_level = log.Level.Info
			case "warn":
				log_level = log.Level.Warning
			case "error":
				log_level = log.Level.Error
			case:
				fmt.eprintf("unknown log level: %s (use debug|info|warn|error)\n", level_str)
				os.exit(1)
			}
		case strings.has_prefix(arg, "--log-format="):
			fmt_str := strings.trim_prefix(arg, "--log-format=")
			switch fmt_str {
			case "short":
				log_opts = {.Level}
			case "long":
				log_opts = log.Default_Console_Logger_Opts
			case "full":
				log_opts = log.Default_Console_Logger_Opts + {.Thread_Id}
			case:
				fmt.eprintf("unknown log format: %s (use short|long|full)\n", fmt_str)
				os.exit(1)
			}
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
		},
	)
	if !ok {
		os.exit(1)
	}
}
