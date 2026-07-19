// types.odin — Cross-FFI struct types for the libfuse3 C API.
// Every struct carries a compile-time #assert(size_of(T) == N)
// to catch ABI drift between Odin and libfuse3.
#+build linux
package fuse3

import "core:c"
import "core:sys/posix"

// Domain-specific distinct types for FUSE inode numbers.
// libfuse3 uses fuse_ino_t = uint64_t internally.
Inode :: distinct u64

Libfuse_Version :: struct {
	major:   c.uint,
	minor:   c.uint,
	hotfix:  c.uint,
	padding: c.uint,
}

#assert(size_of(Libfuse_Version) == 16)

Args :: struct {
	argc:      c.int,
	argv:      [^]cstring,
	allocated: c.int,
}

#assert(size_of(Args) == 24)

Opt :: struct {
	templ:  cstring,
	offset: c.ulong, // unsigned long on x86_64
	value:  c.int,
}

#assert(size_of(Opt) == 24)

Stat :: posix.stat_t

#assert(size_of(Stat) == 144)

File_Info_Bits :: bit_field u32 {
	writepage:              u32 | 1,
	direct_io:              u32 | 1,
	keep_cache:             u32 | 1,
	flush:                  u32 | 1,
	nonseekable:            u32 | 1,
	flock_release:          u32 | 1,
	cache_readdir:          u32 | 1,
	noflush:                u32 | 1,
	parallel_direct_writes: u32 | 1,
	_:                      u32 | 23,
}

File_Info :: struct #packed {
	flags:        c.int32_t,
	bits:         File_Info_Bits,
	padding2:     c.uint32_t,
	padding3:     c.uint32_t,
	fh:           c.uint64_t,
	lock_owner:   c.uint64_t,
	poll_events:  c.uint32_t,
	backing_id:   c.int32_t,
	compat_flags: c.uint64_t,
	reserved:     [2]c.uint64_t,
}

#assert(size_of(File_Info) == 64)

Config :: struct {
	set_gid:              c.int32_t,
	gid:                  c.uint32_t,
	set_uid:              c.int32_t,
	uid:                  c.uint32_t,
	set_mode:             c.int32_t,
	umask:                c.uint32_t,
	entry_timeout:        c.double,
	negative_timeout:     c.double,
	attr_timeout:         c.double,
	intr:                 c.int32_t,
	intr_signal:          c.int32_t,
	remember:             c.int32_t,
	hard_remove:          c.int32_t,
	use_ino:              c.int32_t,
	readdir_ino:          c.int32_t,
	direct_io:            c.int32_t,
	kernel_cache:         c.int32_t,
	auto_cache:           c.int32_t,
	ac_attr_timeout_set:  c.int32_t,
	ac_attr_timeout:      c.double,
	nullpath_ok:          c.int32_t,
	show_help:            c.int32_t,
	modules:              cstring,
	debug:                c.int32_t,
	fmask:                c.uint32_t,
	dmask:                c.uint32_t,
	no_rofd_flush:        c.int32_t,
	parallel_direct_writes: c.int32_t,
	flags:                c.uint32_t,
	reserved:             [48]c.uint64_t,
}

#assert(size_of(Config) == 520)

Loop_Config :: struct {
	clone_fd:         c.int,
	max_idle_threads: c.uint,
}

#assert(size_of(Loop_Config) == 8)

Conn_Info_Bits :: bit_field u32 {
	no_interrupt: u32 | 1,
	_:            u32 | 31,
}

Conn_Info :: struct #packed {
	proto_major:             c.uint32_t,
	proto_minor:             c.uint32_t,
	max_write:               c.uint32_t,
	max_read:                c.uint32_t,
	max_readahead:           c.uint32_t,
	capable:                 c.uint32_t,
	want:                    c.uint32_t,
	max_background:          c.uint32_t,
	congestion_threshold:    c.uint32_t,
	time_gran:               c.uint32_t,
	max_backing_stack_depth: c.uint32_t,
	bits:                    Conn_Info_Bits, // @44
	capable_ext:             c.uint64_t, // @48
	want_ext:                c.uint64_t, // @56
	request_timeout:         c.uint16_t, // @64
	reserved:                [31]c.uint16_t,
}

#assert(size_of(Conn_Info) == 128)

Context :: struct {
	fuse:         rawptr, // struct fuse *  (opaque)
	uid:          posix.uid_t, // u32
	gid:          posix.gid_t, // u32
	pid:          posix.pid_t, // i32
	private_data: rawptr,
	umask:        posix.mode_t, // u32
}

#assert(size_of(Context) == 40)

Session    :: struct {}
Pollhandle :: struct {}
Buf :: struct {
	size:     c.size_t,
	flags:    c.int,
	_ignore1: c.uint32_t,
	mem:      rawptr,
	fd:       c.int,
	_ignore2: c.uint32_t,
	pos:      posix.off_t,
	mem_size: c.size_t,
}

#assert(size_of(Buf) == 48)

Bufvec :: struct {
	count: c.size_t,
	idx:   c.size_t,
	off:   c.size_t,
	_buf:  [1]Buf,
}

#assert(size_of(Bufvec) == 72)

FUSE_BUF_IS_FD  :: 2
FUSE_BUF_FD_SEEK :: 4

Fill_Dir_Proc :: proc "c"(
	buf:   rawptr,
	name:  cstring,
	stbuf: ^Stat,
	off:   posix.off_t,
	flags: c.int,
) -> c.int

// Operations maps 1:1 to libfuse3's fuse_operations struct.
// Callbacks set to nil are silently skipped by libfuse3 (optional).
Operations :: struct {
	// required — path-based. Return attrs for the given path.
	getattr:     proc "c"(path: cstring, stbuf: ^Stat, fi: ^File_Info) -> c.int,
	// optional — read a symlink target. Return 0 on success, -errno on error.
	readlink:    proc "c"(path: cstring, buf: [^]c.char, size: c.size_t) -> c.int,
	// optional — create a device node. Return -ENOSYS to fall back.
	mknod:       proc "c"(path: cstring, mode: posix.mode_t, rdev: posix.dev_t) -> c.int,
	// required for writable — create a directory.
	mkdir:       proc "c"(path: cstring, mode: posix.mode_t) -> c.int,
	// required for writable — remove a file.
	unlink:      proc "c"(path: cstring) -> c.int,
	// required for writable — remove a directory.
	rmdir:       proc "c"(path: cstring) -> c.int,
	// optional — create a symbolic link.
	symlink:     proc "c"(target: cstring, linkpath: cstring) -> c.int,
	// required for writable — rename (cross-directory supported).
	rename:      proc "c"(oldpath: cstring, newpath: cstring, flags: c.uint) -> c.int,
	// optional — hard link. Return -ENOSYS if unsupported.
	link:        proc "c"(oldpath: cstring, newpath: cstring) -> c.int,
	// required — change file permissions.
	chmod:       proc "c"(path: cstring, mode: posix.mode_t, fi: ^File_Info) -> c.int,
	// required — change file ownership.
	chown:       proc "c"(path: cstring, uid: posix.uid_t, gid: posix.gid_t, fi: ^File_Info) -> c.int,
	// required — truncate or extend a file.
	truncate:    proc "c"(path: cstring, size: posix.off_t, fi: ^File_Info) -> c.int,
	// required — open a file. Set fi.fh for read/release.
	open:        proc "c"(path: cstring, fi: ^File_Info) -> c.int,
	// required for readable — read data. Return number of bytes read.
	read:        proc "c"(path: cstring, buf: [^]c.char, size: c.size_t, off: posix.off_t, fi: ^File_Info) -> c.int,
	// required for writable — write data. Return number of bytes written.
	write:       proc "c"(path: cstring, buf: [^]c.char, size: c.size_t, off: posix.off_t, fi: ^File_Info) -> c.int,
	// optional — filesystem statistics. Used by df.
	statfs:      proc "c"(path: cstring, stbuf: ^posix.statvfs_t) -> c.int,
	// optional — flush pending data. Called on every close(2).
	flush:       proc "c"(path: cstring, fi: ^File_Info) -> c.int,
	// required — release an open file. Cleanup happens here.
	release:     proc "c"(path: cstring, fi: ^File_Info) -> c.int,
	// optional — synchronise file contents.
	fsync:       proc "c"(path: cstring, isdatasync: c.int, fi: ^File_Info) -> c.int,
	// optional — set extended attribute.
	setxattr:    proc "c"(path: cstring, name: cstring, value: [^]c.char, size: c.size_t, flags: c.int) -> c.int,
	// optional — get extended attribute.
	getxattr:    proc "c"(path: cstring, name: cstring, value: [^]c.char, size: c.size_t) -> c.int,
	// optional — list extended attribute names.
	listxattr:   proc "c"(path: cstring, list: [^]c.char, size: c.size_t) -> c.int,
	// optional — remove extended attribute.
	removexattr: proc "c"(path: cstring, name: cstring) -> c.int,
	// required — open a directory for readdir.
	opendir:     proc "c"(path: cstring, fi: ^File_Info) -> c.int,
	// required for listing — fill directory entries via filler.
	readdir:     proc "c"(path: cstring, buf: rawptr, filler: Fill_Dir_Proc, off: posix.off_t, fi: ^File_Info, flags: c.int) -> c.int,
	// required — release a directory handle.
	releasedir:  proc "c"(path: cstring, fi: ^File_Info) -> c.int,
	// optional — synchronise directory contents.
	fsyncdir:    proc "c"(path: cstring, isdatasync: c.int, fi: ^File_Info) -> c.int,
	// required — initialise filesystem. Returns user_data pointer.
	init:        proc "c"(conn: ^Conn_Info, cfg: ^Config) -> rawptr,
	// optional — cleanup on unmount.
	destroy:     proc "c"(private_data: rawptr),
	// required — check file access permissions.
	access:      proc "c"(path: cstring, mask: c.int) -> c.int,
	// required for writable — create and open a new file.
	create:      proc "c"(path: cstring, mode: posix.mode_t, fi: ^File_Info) -> c.int,
	// optional — lock a file region. struct flock* passed as raw lock arg.
	lock:        proc "c"(path: cstring, fi: ^File_Info, cmd: c.int, lock: rawptr) -> c.int,
	// optional — set file timestamps.
	utimens:     proc "c"(path: cstring, tv: [^]posix.timespec, fi: ^File_Info) -> c.int,
	// optional — map file blocks (not commonly implemented).
	bmap:        proc "c"(path: cstring, blocksize: c.size_t, idx: ^c.uint64_t) -> c.int,
	// optional — device I/O control.
	// FUSE_USE_VERSION 318 < 35 ⇒ cmd is c.int; if we ever bump to 35+ change to c.uint.
	ioctl:       proc "c"(path: cstring, cmd: c.int, arg: rawptr, fi: ^File_Info, flags: c.uint, data: rawptr) -> c.int,
	// optional — poll for I/O events.
	poll:        proc "c"(path: cstring, fi: ^File_Info, ph: ^Pollhandle, reventsp: ^c.uint) -> c.int,
	// required for zero-copy — write from a buffer vector.
	write_buf:   proc "c"(path: cstring, buf: ^Bufvec, off: posix.off_t, fi: ^File_Info) -> c.int,
	// required for zero-copy — read into a buffer vector.
	read_buf:    proc "c"(path: cstring, bufp: ^^Bufvec, size: c.size_t, off: posix.off_t, fi: ^File_Info) -> c.int,
	// optional — flock-style file locking.
	flock:       proc "c"(path: cstring, fi: ^File_Info, op: c.int) -> c.int,
	// required — pre-allocate or punch a hole in a file.
	fallocate:   proc "c"(path: cstring, mode: c.int, off: posix.off_t, length: posix.off_t, fi: ^File_Info) -> c.int,
	// optional — copy a range of bytes between two files.
	copy_file_range: proc "c"(
		path_in: cstring,
		fi_in: ^File_Info,
		off_in: posix.off_t,
		path_out: cstring,
		fi_out: ^File_Info,
		off_out: posix.off_t,
		size: c.size_t,
		flags: c.int,
	) -> c.ssize_t,
	// required — seek with SEEK_HOLE/SEEK_DATA support.
	lseek:       proc "c"(path: cstring, off: posix.off_t, whence: c.int, fi: ^File_Info) -> posix.off_t,
	// optional — extended stat for newer kernels.
	statx:       proc "c"(path: cstring, flags: c.int, mask: c.int, stxbuf: rawptr, fi: ^File_Info) -> c.int,
}

#assert(size_of(Operations) == 344)
