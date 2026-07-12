// main.odin — fused read-only FUSE mounter.
//
// Opens a fused disk image, validates the MasterRecord, wires the
// FUSE callbacks from ops.odin, and calls fuse3.run.
//
// Usage: fused [--log-file=<path>] [--log-level=<level>] <image-path> [fuse-options...] <mountpoint>
// Example: fused --log-file=fused.log --log-level=warn fused.img -f mnt
// Levels: debug, info, warn, error (default: debug)
#+build linux
package main

import "base:runtime"
import "core:c"
import "core:container/lru"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "src:fs"
import "src:fuse3"

main :: proc() {
	context = runtime.default_context()
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	context.allocator = mem.tracking_allocator(&track)

	log_file_path: string
	log_level := log.Level.Debug
	fuse_args: [dynamic]string

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
		case:
			append(&fuse_args, arg)
		}
	}

	if log_file_path != "" {
		log_fd, log_open_err := os.open(log_file_path, {.Create, .Write, .Append})
		if log_open_err != nil {
			log.fatalf("cannot open log file %s: %v", log_file_path, log_open_err)
		}
		context.logger = log.create_file_logger(log_fd, log_level)
		g_logger = context.logger
	} else {
		context.logger = log.create_console_logger(log_level)
		g_logger = context.logger
	}

	if len(fuse_args) < 1 {
		log.fatalf("usage: fused [--log-file=<path>] [--log-level=<level>] <image-path> [fuse-options...] <mountpoint>")
	}

	image_path := fuse_args[0]
	fd, open_err := os.open(image_path, {.Read, .Write})
	if open_err != nil {
		log.fatalf("cannot open %s: %v", image_path, open_err)
	}
	defer os.close(fd)

	g_disk = fd
	{
		File_Impl_Layout :: struct {
			file: rawptr,
			name: string,
			cname: cstring,
			fd: posix.FD,
		}

		impl := (^struct{impl: ^File_Impl_Layout})(fd)
		g_fd = impl.impl.fd
	}

	master, master_ok := fs.read_master_record(fd)
	if !master_ok {
		log.errorf("failed to read MasterRecord")
		os.exit(1)
	}

	fi, stat_err := os.stat(image_path, context.temp_allocator)
	image_size: u64 = 0
	if stat_err == nil {
		image_size = u64(fi.size)
	}

	err := fs.validate_master(&master, image_size)
	if err != .None {
		log.errorf("validation failed: %v", err)
		os.exit(1)
	}

	g_master = master
	g_image_size = image_size
	fs.alloc_cache_init(&fs.g_alloc_cache, &master)
	defer fs.alloc_cache_destroy(&fs.g_alloc_cache)

	log.infof("mounted: rev=%d cluster_size=%d clusters=%d root=%d",
		master.rev, master.cluster_size, master.cluster_map_size, master.root_cluster)

	ops := fuse3.Operations{
		getattr    = fused_getattr,
		readdir    = fused_readdir,
		open       = fused_open,
		read       = fused_read,
		write      = fused_write,
		create     = fused_create,
		mkdir      = fused_mkdir,
		unlink     = fused_unlink,
		rmdir      = fused_rmdir,
		truncate   = fused_truncate,
		rename     = fused_rename,
		access     = fused_access,
		utimens    = fused_utimens,
		flush      = fused_flush,
		release    = fused_release,
		opendir    = fused_opendir,
		releasedir = fused_releasedir,
		fsync      = fused_fsync,
		statfs     = fused_statfs,
	}

	dynamic_argv: [dynamic; 16]cstring
	append(&dynamic_argv, "fused")
	for i in 1 ..< len(fuse_args) {
		append(&dynamic_argv, strings.clone_to_cstring(fuse_args[i], context.temp_allocator))
	}

	has_f := false
	has_s := false
	for a in dynamic_argv {
		if a == "-f" {
			has_f = true
		}
		if a == "-s" {
			has_s = true
		}
	}
	if !has_f {
		append(&dynamic_argv, "-f")
	}
	if !has_s {
		append(&dynamic_argv, "-s")
	}

	lru.init(&g_path_cache, 128, context.allocator, context.allocator)
	g_path_cache.on_remove = path_cache_on_remove
	rc := fuse3.run(c.int(len(dynamic_argv)), raw_data(dynamic_argv[:]), &ops, nil)
	if rc != 0 {
		log.errorf("fuse_main returned %d", rc)
		os.exit(1)
	}

	log.infof("unmounted")
	if len(track.allocation_map) > 0 {
		log.warnf("--- leaked allocations ---")
		for _, leak in track.allocation_map {
			log.warnf("  %v bytes at %v", leak.size, leak.location)
		}
	}
}
