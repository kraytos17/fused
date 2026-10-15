// main.odin — fused read-write FUSE mounter daemon lifecycle.
//
// Opens a fused disk image from a pre-parsed Mount_Options, validates the
// MasterRecord, wires the FUSE callbacks from the mounter package, and calls
// fuse3.run. CLI parsing lives in cmd/mount (usage text included there).
#+build linux
package mounter

import "base:runtime"
import "core:c"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "src:fs"
import "src:fuse3"

// Mount_Options carries the parsed CLI state into run. The mount CLI mixes
// fused-owned flags (--log-*) with opaque FUSE passthrough (-d, -s, -o…),
// which core:flags cannot express (unknown flags abort parsing with
// Missing_Flag), so argv is partitioned by the cmd/mount entry point and
// passed here pre-split. The library never reads os.args.
Mount_Options :: struct {
	// image_path is the fused disk image to mount.
	image_path:    string,
	// log_file_path selects file logging; "" means console logging.
	log_file_path: string,
	// log_level is the logger verbosity.
	log_level:     log.Level,
	// log_opts selects the console logger format.
	log_opts:      log.Options,
	// fuse_args is the opaque FUSE passthrough (options + mountpoint),
	// NOT including image_path. Borrowed: the caller owns it.
	fuse_args:     []string,
	// cache sizes the three in-memory caches; zero entries select defaults.
	cache:         fs.Cache_Config,
}

// build_operations assembles the FUSE callback table. Extracted from run()
// so the 43-callback wiring reads (and reviews) in isolation; no logic.
build_operations :: proc() -> fuse3.Operations {
	return {
		init = fused_init,
		destroy = fused_destroy,
		getattr = fused_getattr,
		readdir = fused_readdir,
		open = fused_open,
		read = fused_read,
		write = fused_write,
		create = fused_create,
		symlink = fused_symlink,
		readlink = fused_readlink,
		mkdir = fused_mkdir,
		unlink = fused_unlink,
		rmdir = fused_rmdir,
		truncate = fused_truncate,
		rename = fused_rename,
		access = fused_access,
		chmod = fused_chmod,
		chown = fused_chown,
		utimens = fused_utimens,
		fallocate = fused_fallocate,
		flush = fused_flush,
		release = fused_release,
		setxattr = fused_setxattr,
		getxattr = fused_getxattr,
		listxattr = fused_listxattr,
		removexattr = fused_removexattr,
		copy_file_range = fused_copy_file_range,
		read_buf = fused_read_buf,
		write_buf = fused_write_buf,
		opendir = fused_opendir,
		releasedir = fused_releasedir,
		fsync = fused_fsync,
		lseek = fused_lseek,
		statfs = fused_statfs,
		fsyncdir = fused_fsyncdir,
		lock = fused_lock,
		flock = fused_flock,
		mknod = fused_mknod,
		ioctl = fused_ioctl,
		link = fused_link,
		statx = fused_statx,
		bmap = fused_bmap,
		poll = fused_poll,
	}
}

// _run_setup_logger builds the run-scoped logger: file-backed multi logger
// when log_file_path is set, console logger otherwise. Returns the logger
// to install, the file logger (destroyed by the caller), and ok=false when
// the log file cannot be opened. Destroys must be deferred in run()'s own
// scope (see below), so they are NOT deferred here.
@(private = "file")
_run_setup_logger :: proc(
	log_file_path: string,
	log_level: log.Level,
	log_opts: log.Options,
) -> (
	logger, file_logger: log.Logger,
	file_log: bool,
	ok: bool,
) {
	file_log = log_file_path != ""
	if file_log {
		log_fd, log_open_err := os.open(log_file_path, {.Create, .Write, .Append})
		if log_open_err != nil {
			log.errorf("cannot open log file %s: %v", log_file_path, log_open_err)
			return {}, {}, true, false
		}

		file_logger = log.create_file_logger(log_fd, log_level, log.Default_File_Logger_Opts)
		logger = log.create_multi_logger(file_logger)
	} else {
		logger = log.create_console_logger(log_level, log_opts)
	}
	return logger, file_logger, file_log, true
}

// _run_build_argv builds the fuse_main argv (program name + borrowed FUSE
// args + ensured -f foreground flag). Only entries 1..<1+n_cloned are
// cloned (index 0 "fused" and a possible trailing "-f" are static);
// the caller frees exactly those (see below) plus the backing.
@(private = "file")
_run_build_argv :: proc(fuse_args: []string) -> (argv: [dynamic]cstring, n_cloned: int) {
	append(&argv, "fused")
	for arg in fuse_args {
		append(&argv, strings.clone_to_cstring(arg, context.allocator))
	}

	n_cloned = len(fuse_args)
	has_f := false
	for a in argv {
		if a == "-f" {
			has_f = true
		}
	}
	if !has_f {
		append(&argv, "-f")
	}
	return argv, n_cloned
}

// _run_dump_leaks logs any allocations still live at unmount (debug only).
@(private = "file")
_run_dump_leaks :: proc(track: ^mem.Tracking_Allocator) {
	when ODIN_DEBUG {
		if len(track.allocation_map) > 0 {
			log.warnf("--- leaked allocations ---")
			for _, leak in track.allocation_map {
				log.warnf("  %v bytes at %v", leak.size, leak.location)
			}
		}
	}
}

run :: proc(opts: Mount_Options) -> bool {
	context = runtime.default_context()
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	when ODIN_DEBUG {
		context.allocator = mem.tracking_allocator(&track)
	}
	when !ODIN_DEBUG {
		_ = track
	}

	fsys := new(FS)
	// Loggers live until run() returns (after unmount): their destroys must
	// be function-scoped. A defer inside the setup helper's branches would
	// fire at helper exit (Odin defers run at scope end, unlike Go), freeing
	// logger state while mounted callbacks still use it — use-after-free.
	// _run_setup_logger therefore returns without deferring; the destroys
	// below fire at run() exit.
	logger, file_logger, file_log, lok := _run_setup_logger(
		opts.log_file_path,
		opts.log_level,
		opts.log_opts,
	)
	if !lok {
		free(fsys)
		return false
	}

	context.logger = logger
	fsys.logger = logger
	defer if file_log {
		log.destroy_file_logger(file_logger)
	} else {
		log.destroy_console_logger(context.logger)
	}

	image_path := opts.image_path
	vol, vol_err := fs.volume_open(image_path, opts.cache)
	if vol_err != .None {
		log.errorf("failed to open image: %v", vol_err)
		free(fsys)
		return false
	}

	defer fs.volume_close(&vol)
	fsys.vol = vol
	fsys.disk_raw_fd = c.int(os.fd(vol.disk))
	init_fs_state(fsys, context.allocator, opts.cache)

	log.debugf("opened %s → raw_fd=%d", image_path, fsys.disk_raw_fd)
	log.infof(
		"mounted: rev=%d cluster_size=%d clusters=%d root=%d",
		vol.master.rev_max,
		vol.master.cluster_size,
		vol.master.cluster_map_size,
		vol.master.root_cluster,
	)

	ops := build_operations()
	dynamic_argv, n_cloned := _run_build_argv(opts.fuse_args)
	rc := fuse3.run(c.int(len(dynamic_argv)), raw_data(dynamic_argv[:]), &ops, fsys)
	// Session over: argv is no longer needed. Free exactly the cloned
	// entries (index 0 "fused" and a possible trailing "-f" are static).
	for i in 1 ..< 1 + n_cloned {
		delete(dynamic_argv[i])
	}

	delete(dynamic_argv)
	// NOTE: opts.fuse_args is borrowed — the cmd/mount caller frees it.
	// Full teardown before the leak dump: caches, lock tables, FS shell.
	// The volume itself is closed by the deferred volume_close.
	destroy_fs_for_test(fsys)
	free(fsys)
	if rc != 0 {
		log.errorf("fuse_main returned %d", rc)
		return false
	}

	log.infof("unmounted")
	_run_dump_leaks(&track)
	return true
}
