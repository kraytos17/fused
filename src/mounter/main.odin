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
	// trace_mode enables JSONL op tracing (.Off by default); trace_path
	// is the output file ("-" selects stdout, which is never closed).
	trace_mode:    Trace_Mode,
	trace_path:    string,
}

// build_operations assembles the FUSE callback table. Extracted from run()
// so the 43-callback wiring reads (and reviews) in isolation; no logic.
build_operations :: proc() -> fuse3.Operations {
	return {
		init = traced_init,
		destroy = traced_destroy,
		getattr = traced_getattr,
		readdir = traced_readdir,
		open = traced_open,
		read = traced_read,
		write = traced_write,
		create = traced_create,
		symlink = traced_symlink,
		readlink = traced_readlink,
		mkdir = traced_mkdir,
		unlink = traced_unlink,
		rmdir = traced_rmdir,
		truncate = traced_truncate,
		rename = traced_rename,
		access = traced_access,
		chmod = traced_chmod,
		chown = traced_chown,
		utimens = traced_utimens,
		fallocate = traced_fallocate,
		flush = traced_flush,
		release = traced_release,
		setxattr = traced_setxattr,
		getxattr = traced_getxattr,
		listxattr = traced_listxattr,
		removexattr = traced_removexattr,
		copy_file_range = traced_copy_file_range,
		read_buf = traced_read_buf,
		write_buf = traced_write_buf,
		opendir = traced_opendir,
		releasedir = traced_releasedir,
		fsync = traced_fsync,
		lseek = traced_lseek,
		statfs = traced_statfs,
		fsyncdir = traced_fsyncdir,
		lock = traced_lock,
		flock = traced_flock,
		mknod = traced_mknod,
		ioctl = traced_ioctl,
		link = traced_link,
		statx = traced_statx,
		bmap = traced_bmap,
		poll = traced_poll,
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
	// Trace mode needs a destination before anything runs: fail fast
	// here rather than after opening the image.
	trace_required := opts.trace_mode != .Off && len(opts.trace_path) == 0
	if trace_required {
		log.errorf("trace mode requires --trace-out=<file> (or - for stdout)")
		free(fsys)
		return false
	}

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
	if opts.trace_mode != .Off {
		if fsys.trace = trace_sink_open(opts.trace_path, opts.trace_mode); fsys.trace == nil {
			log.errorf("cannot open trace file %s", opts.trace_path)
			destroy_fs_for_test(fsys)
			free(fsys)
			return false
		}
		log.infof("tracing %v → %s", opts.trace_mode, opts.trace_path)
	}

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
	// Full teardown before the leak dump: trace sink first (it outlives
	// the FS shell), then caches, lock tables, FS shell. The volume
	// itself is closed by the deferred volume_close.
	trace_sink_close(fsys.trace)
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
