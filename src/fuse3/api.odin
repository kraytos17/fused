#+build linux
package fuse3

import "core:c"
import "core:sys/posix"

current_libfuse_version :: #force_inline proc "contextless"() -> Libfuse_Version {
	return Libfuse_Version {
		major   = FUSE_USE_VERSION_MAJOR,
		minor   = FUSE_USE_VERSION_MINOR,
		hotfix  = FUSE_HOTFIX_VERSION,
		padding = 0,
	}
}

@(require_results)
run :: proc "c"(argc: c.int, argv: [^]cstring, ops: ^Operations, user_data: rawptr) -> c.int {
	v := current_libfuse_version()
	return fuse_main_real_versioned(argc, argv, ops, size_of(Operations), &v, user_data)
}

@(require_results)
fill_dir :: #force_inline proc "c"(
	filler: Fill_Dir_Proc,
	buf:    rawptr,
	name:   cstring,
	stbuf:  ^Stat,
	off:    posix.off_t = 0,
) -> c.int {
	return filler(buf, name, stbuf, off, c.int(Fill_Dir_Flags.Defaults))
}

check_version :: #force_inline proc "contextless"() -> (major, minor: c.int) {
	v := fuse_version()
	return v / 100, v % 100
}

pkgversion :: #force_inline proc "contextless"() -> cstring {
	return fuse_pkgversion()
}

// nix negates a posix errno to the form libfuse expects callbacks to return.
//   nix(.None)  → 0   (success)
//   nix(.NOENT) → -2  (no such file)
//   nix(.ACCES) → -13 (permission denied)
nix :: #force_inline proc "contextless"(e: posix.Errno) -> c.int {
	return -c.int(e)
}

// ctx returns a copy of the current FUSE context.  Per libfuse docs the
// underlying C pointer is only valid for the duration of the current
// FUSE operation — returning by value (not by pointer) prevents storing
// a dangling reference beyond the callback scope.  Must be called from
// within a FUSE callback.
ctx :: #force_inline proc "c"() -> Context {
	return fuse_get_context()^
}

// invalidate tells the kernel to drop cached attributes and/or data for
// the given path.  Call after a write so the kernel re-fetches on the
// next access.  Returns 0 on success, -errno on error.  -ENOENT means
// the path wasn't cached yet (not an error per se).  Must be called from
// within a FUSE callback.
@(require_results)
invalidate :: proc "c"(path: cstring) -> c.int {
	c := fuse_get_context()
	return fuse_invalidate_path(c.fuse, path)
}

// exit signals the event loop to unmount and return from fuse3.run().
// Can be called from within any FUSE callback.  After the call, the
// current callback should return as normal; the loop exits when it
// gets back to the top of the event dispatch.
exit :: proc "c"() {
	c := fuse_get_context()
	fuse_exit(c.fuse)
}

// set_feature requests a capability flag in the connection info during
// the init callback.  Returns true if the kernel supports the flag.
// Call from the init callback, before returning.
@(require_results)
set_feature :: #force_inline proc "c"(conn: ^Conn_Info, flag: c.uint64_t) -> bool {
	return bool(fuse_set_feature_flag(conn, flag))
}

// unset_feature clears a capability flag requested by set_feature.
unset_feature :: #force_inline proc "c"(conn: ^Conn_Info, flag: c.uint64_t) {
	fuse_unset_feature_flag(conn, flag)
}

// get_feature returns whether a capability flag is set on the connection.
@(require_results)
get_feature :: #force_inline proc "c"(conn: ^Conn_Info, flag: c.uint64_t) -> bool {
	return bool(fuse_get_feature_flag(conn, flag))
}
