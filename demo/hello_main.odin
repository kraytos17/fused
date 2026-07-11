package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "src:fuse3"

when ODIN_DEBUG {
	TRACK: mem.Tracking_Allocator
}

HELLO_CONTENT := [?]u8{
	'H', 'e', 'l', 'l', 'o', ' ', 'f', 'r', 'o', 'm', ' ', 'f', 'u', 's', 'e', 'd', '!', '\n',
}

FILE_MODE_RO :: posix.mode_t{.IFREG, .IRUSR, .IRGRP, .IROTH}
DIR_MODE_RO  :: posix.mode_t{.IFDIR, .IRUSR, .IRGRP, .IROTH, .IXUSR, .IXGRP, .IXOTH}

hello_getattr :: proc "c"(path: cstring, stbuf: ^fuse3.Stat, _: ^fuse3.File_Info) -> c.int {
	context = runtime.default_context()
	stbuf^ = {}
	p := cast([^]c.char)(path)
	is_root := p[0] == 0 || (p[0] == '/' && p[1] == 0)
	if is_root {
		stbuf.st_mode = posix.mode_t(DIR_MODE_RO)
		stbuf.st_nlink = 2
	} else {
		stbuf.st_mode = posix.mode_t(FILE_MODE_RO)
		stbuf.st_nlink = 1
		stbuf.st_size = posix.off_t(len(HELLO_CONTENT))
	}
	return 0
}

hello_read :: proc "c"(
	path: cstring,
	buf: [^]c.char,
	size: c.size_t,
	off: posix.off_t,
	_: ^fuse3.File_Info,
) -> c.int {
	context = runtime.default_context()
	if off >= posix.off_t(len(HELLO_CONTENT)) {
		return 0
	}

	avail := c.size_t(posix.off_t(len(HELLO_CONTENT)) - off)
	n := min(size, avail)
	src := raw_data(HELLO_CONTENT[:])[off:]
	mem.copy(rawptr(buf), rawptr(src), int(n))
	return c.int(n)
}

hello_readdir :: proc "c"(
	path: cstring,
	buf: rawptr,
	filler: fuse3.Fill_Dir_Proc,
	off: posix.off_t,
	_: ^fuse3.File_Info,
	flags: c.int,
) -> c.int {
	context = runtime.default_context()
	if rc := fuse3.fill_dir(filler, buf, ".", nil); rc != 0 {return rc}
	if rc := fuse3.fill_dir(filler, buf, "..", nil); rc != 0 {return rc}
	if rc := fuse3.fill_dir(filler, buf, "hello.txt", nil); rc != 0 {return rc}
	return 0
}

main :: proc() {
	context = runtime.default_context()
	when ODIN_DEBUG {
		mem.tracking_allocator_init(&TRACK, context.allocator)
		defer mem.tracking_allocator_destroy(&TRACK)
		context.allocator = mem.tracking_allocator(&TRACK)
	}

	maj, min := fuse3.check_version()
	fmt.printf("libfuse3 runtime version: %d.%d (built for %d.%d)\n",
		maj, min, fuse3.FUSE_USE_VERSION_MAJOR, fuse3.FUSE_USE_VERSION_MINOR)
	fmt.printf("libfuse3 package version: %s\n", fuse3.pkgversion())
	dynamic_argv: [dynamic]cstring
	defer delete(dynamic_argv)

	append(&dynamic_argv, "fused")
	has_f := false
	for i in 1 ..< len(os.args) {
		if os.args[i] == "-f" {
			has_f = true
		}
		append(&dynamic_argv, strings.clone_to_cstring(os.args[i], context.temp_allocator))
	}
	if !has_f {
		append(&dynamic_argv, "-f")
	}

	ops: fuse3.Operations
	ops.getattr = hello_getattr
	ops.readdir = hello_readdir
	ops.read = hello_read
	rc := fuse3.run(c.int(len(dynamic_argv)), raw_data(dynamic_argv), &ops, nil)
	if rc != 0 {
		fmt.eprintln("fuse_main returned", rc)
		os.exit(1)
	}

	when ODIN_DEBUG {
		if len(TRACK.allocation_map) > 0 {
			fmt.eprintln("--- leaked allocations (tracking allocator) ---")
			for _, leak in TRACK.allocation_map {
				fmt.eprintf("  %v bytes at %v\n", leak.size, leak.location)
			}
		}
	}
}
