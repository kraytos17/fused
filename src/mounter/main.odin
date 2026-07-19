// main.odin — fused read-only FUSE mounter.
//
// Opens a fused disk image, validates the MasterRecord, wires the
// FUSE callbacks from the mounter package (core.odin, create.odin, dir.odin,
// read.odin, write.odin, misc.odin), and calls fuse3.run.
//
// Usage: fused [--log-file=<path>] [--log-level=<level>] [--log-format=<format>] <image-path> [fuse-options...] <mountpoint>
// Example: fused --log-file=fused.log --log-level=warn fused.img -f mnt
// Levels: debug, info, warn, error (default: debug)
// Formats: long (default, with date/time/location), short (level only), full (level + thread id)
#+build linux
package mounter

import "base:runtime"
import "core:c"
import "core:container/lru"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "src:fs"
import "src:fuse3"

usage :: proc() {
	fmt.println("Usage: fused [--log-file=<path>] [--log-level=<level>] [--log-format=<format>] <image-path> [fuse-options...] <mountpoint>")
	fmt.println("Levels:  debug, info, warn, error  (default: debug)")
	fmt.println("Formats: long (default, date/time/location), short (level only), full (level + thread id)")
	fmt.println("Flags:   --log-file=<path>  --log-level=<level>  --log-format=<format>")
	fmt.println("         -f (foreground, default), -d (FUSE debug), -s (single-threaded)")
}

run :: proc() {
	context = runtime.default_context()
	for arg in os.args[1:] {
		if arg == "--help" || arg == "-h" {
			usage()
			os.exit(0)
		}
	}

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	when ODIN_DEBUG {
		context.allocator = mem.tracking_allocator(&track)
	}
	when !ODIN_DEBUG {
		_ = track
	}

	log_file_path: string
	log_level := log.Level.Debug
	log_opts := log.Default_Console_Logger_Opts
	fuse_args: [dynamic]string
	defer delete(fuse_args)

	for i in 1 ..< len(os.args) {
		arg := os.args[i]
		switch {
		case strings.has_prefix(arg, "--log-file="):
			log_file_path = strings.trim_prefix(arg, "--log-file=")
		case strings.has_prefix(arg, "--log-level="):
			level_str := strings.trim_prefix(arg, "--log-level=")
			switch level_str {
			case "debug": log_level = log.Level.Debug
			case "info":  log_level = log.Level.Info
			case "warn":  log_level = log.Level.Warning
			case "error": log_level = log.Level.Error
			case:
				log.errorf("unknown log level: %s (use debug|info|warn|error)", level_str)
			}
		case strings.has_prefix(arg, "--log-format="):
			fmt_str := strings.trim_prefix(arg, "--log-format=")
			switch fmt_str {
			case "short": log_opts = {.Level}
			case "long":  log_opts = log.Default_Console_Logger_Opts
			case "full":  log_opts = log.Default_Console_Logger_Opts + {.Thread_Id}
			case:
				log.errorf("unknown log format: %s (use short|long|full)", fmt_str)
			}
		case:
			append(&fuse_args, arg)
		}
	}

	fsys := new(FS)
	if log_file_path != "" {
		log_fd, log_open_err := os.open(log_file_path, {.Create, .Write, .Append})
		if log_open_err != nil {
			log.errorf("cannot open log file %s: %v", log_file_path, log_open_err)
			os.exit(1)
		}

		file_logger := log.create_file_logger(log_fd, log_level, log.Default_File_Logger_Opts)
		defer log.destroy_file_logger(file_logger)

		context.logger = log.create_multi_logger(file_logger)
		fsys.logger = context.logger
	} else {
		context.logger = log.create_console_logger(log_level, log_opts)
		defer log.destroy_console_logger(context.logger)
		fsys.logger = context.logger
	}

	if len(fuse_args) < 1 {
		log.errorf("usage: fused [--log-file=<path>] [--log-level=<level>] <image-path> [fuse-options...] <mountpoint>")
		os.exit(1)
	}

	image_path := fuse_args[0]
	vol, vol_err := fs.volume_open(image_path)
	if vol_err != .None {
		log.errorf("failed to open image: %v", vol_err)
		os.exit(1)
	}
	defer fs.volume_close(&vol)

	fsys.vol = vol
	fsys.disk_raw_fd = c.int(os.fd(vol.disk))
	log.debugf("opened %s → raw_fd=%d", image_path, fsys.disk_raw_fd)
	log.infof("mounted: rev=%d cluster_size=%d clusters=%d root=%d",
		vol.master.rev_max, vol.master.cluster_size, vol.master.cluster_map_size, vol.master.root_cluster)

	ops := fuse3.Operations{
		init       = fused_init,
		destroy    = fused_destroy,
		getattr    = fused_getattr,
		readdir    = fused_readdir,
		open       = fused_open,
		read       = fused_read,
		write      = fused_write,
		create     = fused_create,
		symlink    = fused_symlink,
		readlink   = fused_readlink,
		mkdir      = fused_mkdir,
		unlink     = fused_unlink,
		rmdir      = fused_rmdir,
		truncate   = fused_truncate,
		rename     = fused_rename,
		access     = fused_access,
		chmod      = fused_chmod,
		chown      = fused_chown,
		utimens    = fused_utimens,
		fallocate  = fused_fallocate,
		flush      = fused_flush,
		release    = fused_release,
		copy_file_range = fused_copy_file_range,
		read_buf   = fused_read_buf,
		write_buf  = fused_write_buf,
		opendir    = fused_opendir,
		releasedir = fused_releasedir,
		fsync      = fused_fsync,
		lseek      = fused_lseek,
		statfs     = fused_statfs,
		fsyncdir   = fused_fsyncdir,
		mknod      = fused_mknod,
		ioctl      = fused_ioctl,
		link       = fused_link,
		statx      = fused_statx,
	}

	dynamic_argv: [dynamic; 16]cstring
	append(&dynamic_argv, "fused")
	for i in 1 ..< len(fuse_args) {
		append(&dynamic_argv, strings.clone_to_cstring(fuse_args[i], context.temp_allocator))
	}

	has_f := false
	for a in dynamic_argv {
		if a == "-f" {
			has_f = true
		}
	}
	if !has_f {
		append(&dynamic_argv, "-f")
	}

	lru.init(&fsys.path_cache, 128, context.allocator, context.allocator)
	fsys.path_cache.on_remove = path_cache_on_remove
	lru.init(&fsys.lfn_cache, 256, context.allocator, context.allocator)
	fsys.lfn_cache.on_remove = lfn_cache_on_remove
	rc := fuse3.run(c.int(len(dynamic_argv)), raw_data(dynamic_argv[:]), &ops, fsys)
	if rc != 0 {
		log.errorf("fuse_main returned %d", rc)
		os.exit(1)
	}

	log.infof("unmounted")
	when ODIN_DEBUG {
		if len(track.allocation_map) > 0 {
			log.warnf("--- leaked allocations ---")
			for _, leak in track.allocation_map {
				log.warnf("  %v bytes at %v", leak.size, leak.location)
			}
		}
	}
}
