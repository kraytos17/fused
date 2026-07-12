// main.odin — fused read-only FUSE mounter.
//
// Opens a fused disk image, validates the MasterRecord, wires the
// FUSE callbacks from ops.odin, and calls fuse3.run.
//
// Usage: fused <image-path> [fuse-options...] <mountpoint>
// Example: fused fused.img -f -d /tmp/mnt
#+build linux
package main

import "base:runtime"
import "core:c"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "src:fs"
import "src:fuse3"

main :: proc() {
	context = runtime.default_context()
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	context.allocator = mem.tracking_allocator(&track)
	context.logger = log.create_console_logger(log.Level.Debug)
	g_logger = context.logger
	if len(os.args) < 2 {
		log.fatalf("usage: fused <image-path> [fuse-options...] <mountpoint>")
	}

	image_path := os.args[1]
	fd, open_err := os.open(image_path, {.Read, .Write})
	if open_err != nil {
		log.fatalf("cannot open %s: %v", image_path, open_err)
	}
	defer os.close(fd)

	g_disk = fd
	master, master_ok := fs.read_master_record(fd)
	if !master_ok {
		log.fatalf("failed to read MasterRecord")
	}

	fi, stat_err := os.stat(image_path, context.temp_allocator)
	image_size: u64 = 0
	if stat_err == nil {
		image_size = u64(fi.size)
	}

	err := fs.validate_master(&master, image_size)
	if err != .None {
		log.fatalf("validation failed: %v", err)
	}

	g_master = master
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
	for i in 2 ..< len(os.args) {
		append(
			&dynamic_argv, strings.clone_to_cstring(os.args[i], context.temp_allocator),
		)
	}

	has_f := false
	for a in dynamic_argv {
		if a == "-f" {
			has_f = true
			break
		}
	}
	if !has_f {
		append(&dynamic_argv, "-f")
	}

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
