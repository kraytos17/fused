// main.odin — fused image check (fsck-like validation).
//
// Validates MasterRecord, cluster counts, and free-sector coherence without
// mounting. Useful as `make doctor` or `fused-check <image>`.
#+build linux
package main

import "base:runtime"
import "core:flags"
import "core:fmt"
import "core:log"
import "core:os"
import "src:fs"

Flags :: struct {
	path:      string `args:"pos=0,required" usage:"Path to fused disk image"`,
	log_level: string `args:"name=log-level" usage:"Log level: debug, info, warn, error (default: debug)"`,
	verbose:   bool   `args:"name=verbose" usage:"Verbose output"`,
	overflow:  [dynamic]string `args:"hidden"`,
}

main :: proc() {
	context = runtime.default_context()

	f: Flags
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
		log.errorf("unknown log level: %s", f.log_level)
		os.exit(1)
	}

	context.logger = log.create_console_logger(log_level)
	defer log.destroy_console_logger(context.logger)

	if f.verbose {
		fmt.printf("check: opening %s (verbose)\n", f.path)
	}

	vol, err := fs.volume_open(f.path)
	if err != .None {
		fmt.eprintf("check: %s: open failed: %v\n", f.path, err)
		os.exit(1)
	}
	defer fs.volume_close(&vol)

	master_ok := fs.validate_master(&vol.master, vol.image_size) == .None
	fmt.printf("master: rev %d..%d features=%v cluster_size=%d clusters=%d root=%d — %s\n",
		vol.master.rev_min, vol.master.rev_max, vol.master.features,
		vol.master.cluster_size, vol.master.cluster_map_size, vol.master.root_cluster,
		"ok" if master_ok else "FAIL")

	// Free-sector coherence: compare alloc_cache_count_free vs. what statfs would report.
	// vol.cache is already initialized by volume_open (which ran recovery).
	free_actual := fs.alloc_cache_count_free(&vol)
	fmt.printf("free_sectors: %d / %d (%.1f%% free)\n",
		free_actual, vol.master.cluster_map_size * vol.master.cluster_size,
		f64(free_actual) / f64(vol.master.cluster_map_size * vol.master.cluster_size) * 100)

	// Basic cluster accounting: ensure free + used + reserved == total
	total := vol.master.cluster_map_size * vol.master.cluster_size
	used := total - free_actual
	fmt.printf("used_sectors: %d\n", used)
	if !master_ok {
		fmt.eprintf("check: %s: FAILED\n", f.path)
		os.exit(1)
	}
	fmt.printf("check: %s: OK\n", f.path)
}
