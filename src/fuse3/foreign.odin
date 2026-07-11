// foreign.odin — Foreign import + the foreign block for libfuse3.
//
// libfuse3 does not export `fuse_main` as a real symbol — it is a macro
// (see /usr/include/fuse3/fuse.h:990). The real entry point is
// `fuse_main_real_versioned`, which is what the meson build emits when
// LIBFUSE_BUILT_WITH_VERSIONED_SYMBOLS=1 (Arch fuse3 3.18.2).
#+build linux
package fuse3

import "core:c"

foreign import libfuse3 "system:fuse3"

foreign libfuse3 {
	@(link_name = "fuse_main_real_versioned")
	fuse_main_real_versioned :: proc "c"(
		argc:      c.int,
		argv:      [^]cstring,
		op:        ^Operations,
		op_size:   c.size_t,
		version:   ^Libfuse_Version,
		user_data: rawptr,
	) -> c.int ---

	fuse_version    :: proc "c"() -> c.int   ---
	fuse_pkgversion :: proc "c"() -> cstring ---

	@(link_name = "fuse_get_context")
	fuse_get_context :: proc "c"() -> ^Context ---
}

foreign libfuse3 {
	// Invalidates kernel caches for a file. Call after a write to ensure
	// the kernel re-reads attributes/data on the next access.  Path is
	// relative to the mount root.  Returns 0 on success, -errno on error.
	// May return -ENOENT if the path hasn't been cached yet (not an error).
	@(link_name = "fuse_invalidate_path")
	fuse_invalidate_path :: proc "c"(f: rawptr, path: cstring) -> c.int ---

	// Signals the event loop to exit.  Can be called from within a
	// callback (e.g., in response to a custom signal or shutdown command).
	// The fuse handle is obtained from fuse_get_context().fuse.
	@(link_name = "fuse_exit")
	fuse_exit :: proc "c"(f: rawptr) ---

	// Set a feature flag in fuse_conn_info.want_ext.
	// Returns true if the flag was successfully set (kernel supports it).
	@(link_name = "fuse_set_feature_flag")
	fuse_set_feature_flag :: proc "c"(conn: ^Conn_Info, flag: c.uint64_t) -> c.bool ---

	// Unset a feature flag in fuse_conn_info.want_ext.
	@(link_name = "fuse_unset_feature_flag")
	fuse_unset_feature_flag :: proc "c"(conn: ^Conn_Info, flag: c.uint64_t) ---

	// Query whether a feature flag is set in fuse_conn_info.want_ext.
	@(link_name = "fuse_get_feature_flag")
	fuse_get_feature_flag :: proc "c"(conn: ^Conn_Info, flag: c.uint64_t) -> c.bool ---
}
