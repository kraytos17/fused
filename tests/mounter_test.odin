// mounter_test.odin — Direct unit tests of the FUSE mounter callbacks.
//
// These tests exercise fused_* callbacks in-process against a real test
// image, without a live FUSE mount. A fake fuse3.Context is installed via
// fuse3.set_test_context so get_fs()/begin_op() resolve a test FS. This
// covers the errno-mapping layer that the Odin fs tests cannot reach and
// that the Python tests only cover indirectly through the kernel.
#+build linux
package tests

import "core:c"
import "core:container/bit_array"
import "core:mem"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "src:fs"
import "src:fuse3"
import "src:mounter"

// setup_mounter opens a dedicated test volume and initializes an FS in place
// at fsys. It installs a fake FUSE context whose private_data points to
// *fsys. Uses a per-test image copy so mounter tests never perturb the shared
// /dev/shm image used by the fs unit tests.  Caller must call teardown_mounter.
setup_mounter :: proc(t: ^testing.T, fsys: ^mounter.FS) -> (ok: bool) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {
		testing.fail(t)
		return false
	}

	fsys^ = {}
	mounter.init_fs_for_test(fsys, vol)
	ctx := fuse3.Context {
		uid          = 1000,
		gid          = 1000,
		private_data = fsys,
	}
	fuse3.set_test_context(&ctx)
	return true
}

// teardown_mounter releases the test FS and its volume.
teardown_mounter :: proc(fsys: ^mounter.FS) {
	vol := fsys.vol
	mounter.destroy_fs_for_test(fsys)
	close_test_volume(&vol)
}

// cleanup_root best-effort removes the given entries from the root directory so
// tests are idempotent even after a previous run left residue in the shared
// test image.
cleanup_root :: proc(fsys: ^mounter.FS, names: []string) {
	for name in names {
		// +1 for the NUL: cstring(raw_data(...)) below strlen-scans, so
		// the buffer must be terminated (make zero-fills the trailing byte).
		buf := make([]u8, 2 + len(name))
		buf[0] = '/'
		copy(buf[1:], name)
		path := string(buf[:1+len(name)])
		// Try unlink, then rmdir; ignore errors.
		mounter.fused_unlink(cstring(raw_data(path)))
		mounter.fused_rmdir(cstring(raw_data(path)))
		delete(buf)
	}
}

// expect_errno asserts a callback return value equals the negated errno.
expect_errno :: proc(t: ^testing.T, got: c.int, want: posix.Errno) {
	testing.expect_value(t, got, -c.int(want))
}

// Fill_Dir collector: a FUSE filler stub that accumulates names.
Dir_Collector :: struct {
	buf: [256]u8,
	len: int,
}

collect_filler :: proc "c" (
	buf: rawptr,
	name: cstring,
	stbuf: ^fuse3.Stat,
	off: posix.off_t,
	flags: c.int,
) -> c.int {
	c := (^Dir_Collector)(buf)
	n := len(name)
	if c.len + n + 1 <= len(c.buf) {
		mem.copy(&c.buf[c.len], rawptr(name), n)
		c.len += n
		c.buf[c.len] = 0
		c.len += 1
	}
	return 0
}

// test_mount_getattr — getattr on root, demo file, and a missing path.
@(test)
test_mount_getattr :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)

	st: fuse3.Stat
	rc := mounter.fused_getattr("/", &st, nil)
	testing.expect_value(t, rc, 0)
	testing.expect(t, posix.Mode_Bits.IFDIR in st.st_mode, "root is dir")
	testing.expect(t, posix.Mode_Bits.IRUSR in st.st_mode, "root r")

	st = {}
	rc = mounter.fused_getattr("/Kernel", &st, nil)
	testing.expect_value(t, rc, 0)
	testing.expect(t, posix.Mode_Bits.IFREG in st.st_mode, "Kernel is file")
	testing.expect_value(t, posix.off_t(st.st_size), posix.off_t(60))

	st = {}
	rc = mounter.fused_getattr("/nope", &st, nil)
	expect_errno(t, rc, .ENOENT)
}

// test_mount_readdir — readdir on root yields ., .. and Kernel.
@(test)
test_mount_readdir :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)

	collector: Dir_Collector
	rc := mounter.fused_readdir("/", &collector, collect_filler, 0, nil, 0)
	testing.expect_value(t, rc, 0)

	list := strings.split(string(collector.buf[:collector.len]), "\x00")
	defer delete(list)
	found_dot := false
	found_dotdot := false
	found_kernel := false
	for e in list {
		switch e {
		case ".":
			found_dot = true
		case "..":
			found_dotdot = true
		case "Kernel":
			found_kernel = true
		}
	}

	testing.expect(t, found_dot, "has .")
	testing.expect(t, found_dotdot, "has ..")
	testing.expect(t, found_kernel, "has Kernel")
}

// test_mount_create_write_read_unlink — full file lifecycle.
@(test)
test_mount_create_write_read_unlink :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)
	cleanup_root(&fsys, []string{"ufile"})

	fi: fuse3.File_Info
	rc := mounter.fused_create("/ufile", posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)
	testing.expect(t, fi.fh != 0, "create sets fh")

	data := "hello mounter\n"
	rc = mounter.fused_write("/ufile", raw_data(data), c.size_t(len(data)), 0, &fi)
	testing.expect_value(t, rc, c.int(len(data)))

	buf := make([]u8, 64)
	defer delete(buf)
	rc = mounter.fused_read("/ufile", raw_data(buf), c.size_t(len(data)), 0, &fi)
	testing.expect_value(t, rc, c.int(len(data)))
	testing.expect(t, string(buf[:rc]) == data, "read back content")

	rc = mounter.fused_unlink("/ufile")
	testing.expect_value(t, rc, 0)

	st: fuse3.Stat
	rc = mounter.fused_getattr("/ufile", &st, nil)
	expect_errno(t, rc, .ENOENT)
}

// test_mount_mkdir_rmdir — directory lifecycle + ENOTEMPTY.
@(test)
test_mount_mkdir_rmdir :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)
	cleanup_root(&fsys, []string{"udir"})

	rc := mounter.fused_mkdir("/udir", posix.mode_t{.IRUSR, .IWUSR, .IXUSR})
	testing.expect_value(t, rc, 0)

	// Empty rmdir succeeds.
	rc = mounter.fused_rmdir("/udir")
	testing.expect_value(t, rc, 0)

	// Recreate, add a file, rmdir → ENOTEMPTY.
	rc = mounter.fused_mkdir("/udir", posix.mode_t{.IRUSR, .IWUSR, .IXUSR})
	testing.expect_value(t, rc, 0)
	fi: fuse3.File_Info
	rc = mounter.fused_create("/udir/child", posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)
	rc = mounter.fused_rmdir("/udir")
	expect_errno(t, rc, .ENOTEMPTY)

	rc = mounter.fused_unlink("/udir/child")
	testing.expect_value(t, rc, 0)
	rc = mounter.fused_rmdir("/udir")
	testing.expect_value(t, rc, 0)
}

// test_mount_rename — same-directory and cross-directory rename.
@(test)
test_mount_rename :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)
	cleanup_root(&fsys, []string{"r1", "r2", "rdir"})

	fi: fuse3.File_Info
	rc := mounter.fused_create("/r1", posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)
	one: string = "x"
	rc = mounter.fused_write("/r1", raw_data(one), 1, 0, &fi)
	testing.expect_value(t, rc, 1)

	// Same-dir rename.
	rc = mounter.fused_rename("/r1", "/r2", 0)
	testing.expect_value(t, rc, 0)
	st: fuse3.Stat
	rc = mounter.fused_getattr("/r1", &st, nil)
	expect_errno(t, rc, .ENOENT)
	rc = mounter.fused_getattr("/r2", &st, nil)
	testing.expect_value(t, rc, 0)

	// Cross-dir rename.
	rc = mounter.fused_mkdir("/rdir", posix.mode_t{.IRUSR, .IXUSR})
	testing.expect_value(t, rc, 0)
	rc = mounter.fused_rename("/r2", "/rdir/r2moved", 0)
	testing.expect_value(t, rc, 0)
	rc = mounter.fused_getattr("/rdir/r2moved", &st, nil)
	testing.expect_value(t, rc, 0)

	rc = mounter.fused_unlink("/rdir/r2moved")
	testing.expect_value(t, rc, 0)
	rc = mounter.fused_rmdir("/rdir")
	testing.expect_value(t, rc, 0)
}

// test_mount_symlink_readlink — symlink creation and target readback.
@(test)
test_mount_symlink_readlink :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)
	cleanup_root(&fsys, []string{"slink"})

	rc := mounter.fused_symlink("/Kernel", "/slink")
	testing.expect_value(t, rc, 0)

	buf: [64]u8
	rc = mounter.fused_readlink("/slink", raw_data(buf[:]), c.size_t(len(buf)))
	testing.expect_value(t, rc, 0)
	testing.expect_value(t, string(cstring(&buf[0])), "/Kernel")

	rc = mounter.fused_unlink("/slink")
	testing.expect_value(t, rc, 0)
}

// test_mount_truncate — extend and shrink via truncate.
@(test)
test_mount_truncate :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)
	cleanup_root(&fsys, []string{"tfile"})

	fi: fuse3.File_Info
	rc := mounter.fused_create("/tfile", posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)
	ten: string = "abcdefghij"
	rc = mounter.fused_write("/tfile", raw_data(ten), 10, 0, &fi)
	testing.expect_value(t, rc, 10)

	// Extend.
	rc = mounter.fused_truncate("/tfile", 20, nil)
	testing.expect_value(t, rc, 0)
	st: fuse3.Stat
	rc = mounter.fused_getattr("/tfile", &st, nil)
	testing.expect_value(t, rc, 0)
	testing.expect_value(t, posix.off_t(st.st_size), posix.off_t(20))

	// Shrink.
	rc = mounter.fused_truncate("/tfile", 5, nil)
	testing.expect_value(t, rc, 0)
	rc = mounter.fused_getattr("/tfile", &st, nil)
	testing.expect_value(t, rc, 0)
	testing.expect_value(t, posix.off_t(st.st_size), posix.off_t(5))

	rc = mounter.fused_unlink("/tfile")
	testing.expect_value(t, rc, 0)
}

// test_mount_chmod_access — permission flags and access checks.
@(test)
test_mount_chmod_access :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)
	cleanup_root(&fsys, []string{"cfile"})

	fi: fuse3.File_Info
	rc := mounter.fused_create("/cfile", posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)

	rc = mounter.fused_access("/cfile", 0)
	testing.expect_value(t, rc, 0)
	rc = mounter.fused_access("/cfile", 4) // R_OK
	testing.expect_value(t, rc, 0)

	// Remove read permission → access(R_OK) → EACCES.
	rc = mounter.fused_chmod("/cfile", posix.mode_t{.IWUSR}, nil)
	testing.expect_value(t, rc, 0)
	rc = mounter.fused_access("/cfile", 4)
	expect_errno(t, rc, .EACCES)

	rc = mounter.fused_unlink("/cfile")
	testing.expect_value(t, rc, 0)
}

// test_mount_statfs — statfs geometry.
@(test)
test_mount_statfs :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)

	st: posix.statvfs_t
	rc := mounter.fused_statfs("/", &st)
	testing.expect_value(t, rc, 0)
	testing.expect_value(t, c.ulong(st.f_bsize), c.ulong(512))
	testing.expect_value(t, c.ulong(st.f_namemax), c.ulong(255))
	testing.expect(t, st.f_blocks > 0, "blocks > 0")
}

// test_mount_xattr — set/get/list/remove + errno semantics.
@(test)
test_mount_xattr :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)

	red: string = "red"
	blue: string = "blue"
	one_char: string = "x"

	rc := mounter.fused_setxattr("/Kernel", "user.color", raw_data(red), 3, 0)
	testing.expect_value(t, rc, 0)

	// Probe size.
	rc = mounter.fused_getxattr("/Kernel", "user.color", nil, 0)
	testing.expect_value(t, rc, 3)

	buf: [8]u8
	rc = mounter.fused_getxattr("/Kernel", "user.color", raw_data(buf[:]), c.size_t(len(buf)))
	testing.expect_value(t, rc, 3)
	testing.expect_value(t, string(buf[:3]), "red")

	// Too-small buffer → ERANGE.
	rc = mounter.fused_getxattr("/Kernel", "user.color", raw_data(buf[:]), 2)
	expect_errno(t, rc, .ERANGE)

	// Missing → ENODATA.
	rc = mounter.fused_getxattr("/Kernel", "user.missing", nil, 0)
	expect_errno(t, rc, .ENODATA)

	// CREATE on existing → EEXIST. The ABI word is built from the typed
	// set (positions transmute back to wire values), never spelled raw.
	rc = mounter.fused_setxattr("/Kernel", "user.color", raw_data(blue), 4, transmute(c.int)(fuse3.Xattr_Flags{.Create}))
	expect_errno(t, rc, .EEXIST)

	// REPLACE on missing → ENODATA.
	rc = mounter.fused_setxattr("/Kernel", "user.nope", raw_data(one_char), 1, transmute(c.int)(fuse3.Xattr_Flags{.Replace}))
	expect_errno(t, rc, .ENODATA)

	// List.
	rc = mounter.fused_listxattr("/Kernel", nil, 0)
	testing.expect(t, rc > 0, "listxattr probe > 0")

	// Remove.
	rc = mounter.fused_removexattr("/Kernel", "user.color")
	testing.expect_value(t, rc, 0)
	rc = mounter.fused_getxattr("/Kernel", "user.color", nil, 0)
	expect_errno(t, rc, .ENODATA)
}

// test_mount_stub_callbacks — unimplemented callbacks return -ENOSYS.
@(test)
test_mount_stub_callbacks :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)

	rc := mounter.fused_mknod("/x", posix.mode_t{}, 0)
	expect_errno(t, rc, .ENOSYS)
	rc = mounter.fused_ioctl("/x", 0, nil, nil, 0, nil)
	expect_errno(t, rc, .ENOSYS)
	rc = mounter.fused_link("/a", "/b")
	expect_errno(t, rc, .ENOSYS)
	rc = mounter.fused_statx("/x", 0, 0, nil, nil)
	expect_errno(t, rc, .ENOSYS)
}

// test_mount_fs_error_to_errno — full FS_Error → errno mapping.
@(test)
test_mount_fs_error_to_errno :: proc(t: ^testing.T) {
	// (FS_Error, expected c.int) pairs.
	Cases :: struct {
		err:  fs.FS_Error,
		want: c.int,
	}
	cases := []Cases {
		{fs.FS_Error.None, c.int(0)},
		{fs.FS_Error.Entry_Not_Found, c.int(-int(posix.ENOENT))},
		{fs.FS_Error.Not_A_Directory, c.int(-int(posix.ENOTDIR))},
		{fs.FS_Error.Not_A_File, c.int(-int(posix.EISDIR))},
		{fs.FS_Error.Name_Too_Long, c.int(-int(posix.ENAMETOOLONG))},
		{fs.FS_Error.No_Space, c.int(-int(posix.ENOSPC))},
		{fs.FS_Error.Sector_Read_Error, c.int(-int(posix.EIO))},
		{fs.FS_Error.Sector_Write_Error, c.int(-int(posix.EIO))},
		{fs.FS_Error.Cluster_Not_Found, c.int(-int(posix.EIO))},
		{fs.FS_Error.Cluster_Map_Full, c.int(-int(posix.EIO))},
		{fs.FS_Error.Multi_Sector_Cluster_Map_Unsupported, c.int(-int(posix.EIO))},
		{fs.FS_Error.Invalid_Signature, c.int(-int(posix.EIO))},
		{fs.FS_Error.Version_Too_Old, c.int(-int(posix.EIO))},
		{fs.FS_Error.Version_Too_New, c.int(-int(posix.EIO))},
		{fs.FS_Error.Feature_Not_Supported, c.int(-int(posix.EIO))},
		{fs.FS_Error.Corrupt_Master_Record, c.int(-int(posix.EIO))},
	}
	for c in cases {
		testing.expect_value(t, mounter.fs_error_to_errno(c.err), c.want)
	}
}

// test_mount_read_shared_resolver — write, then read back twice with an
// extend + truncate in between. Exercises resolve_extents_shared through
// fused_read: miss (upgrade + fill), hit (temp snapshot), invalidate,
// miss again. Data must be exact on every read.
@(test)
test_mount_read_shared_resolver :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)
	cleanup_root(&fsys, []string{"shfile"})
	defer cleanup_root(&fsys, []string{"shfile"})

	fi: fuse3.File_Info
	rc := mounter.fused_create("/shfile", posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)

	data := "shared resolver data\n"
	rc = mounter.fused_write("/shfile", raw_data(data), c.size_t(len(data)), 0, &fi)
	testing.expect_value(t, rc, c.int(len(data)))

	buf := make([]u8, 64)
	defer delete(buf)
	// First read: cache miss → upgrade → fill.
	rc = mounter.fused_read("/shfile", raw_data(buf), c.size_t(len(data)), 0, &fi)
	testing.expect_value(t, rc, c.int(len(data)))
	testing.expect(t, string(buf[:rc]) == data, "read 1 exact")
	// Second read: cache hit → temp snapshot.
	rc = mounter.fused_read("/shfile", raw_data(buf), c.size_t(len(data)), 0, &fi)
	testing.expect_value(t, rc, c.int(len(data)))
	testing.expect(t, string(buf[:rc]) == data, "read 2 exact")

	// Extend past the first chain, then read the full span: forces
	// invalidation + re-resolve through the shared path.
	more := "extended tail\n"
	rc = mounter.fused_write(
		"/shfile",
		raw_data(more),
		c.size_t(len(more)),
		posix.off_t(len(data)),
		&fi,
	)
	testing.expect_value(t, rc, c.int(len(more)))

	big := make([]u8, 128)
	defer delete(big)
	rc = mounter.fused_read("/shfile", raw_data(big), c.size_t(len(data) + len(more)), 0, &fi)
	testing.expect_value(t, rc, c.int(len(data) + len(more)))
	testing.expect(t, string(big[:len(data)]) == data, "extended head exact")
	testing.expect(t, string(big[len(data):rc]) == more, "extended tail exact")
}

// test_mount_readdir_lfn_shared — readdir over a long (>16 char) name twice.
// Exercises lfn_lookup_shared (miss + peek-hit) and the resolve_lfn
// ownership fix: names must match exactly, not just be non-empty.
@(test)
test_mount_readdir_lfn_shared :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)
	long := "this_is_a_very_long_filename_for_lfn"
	cleanup_root(&fsys, []string{long})
	defer cleanup_root(&fsys, []string{long})

	fi: fuse3.File_Info
	// +1 for the NUL terminator cstring() scans for (make zero-fills it).
	path_buf := make([]u8, 2 + len(long))
	defer delete(path_buf)
	path_buf[0] = '/'
	copy(path_buf[1:], long)
	rc := mounter.fused_create(cstring(raw_data(path_buf)), posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)

	for _ in 0 ..< 2 {
		collector: Dir_Collector
		rc = mounter.fused_readdir("/", &collector, collect_filler, 0, nil, 0)
		testing.expect_value(t, rc, 0)

		list := strings.split(string(collector.buf[:collector.len]), "\x00")
		defer delete(list)
		found := false
		for e in list {
			if e == long {
				found = true
			}
		}
		testing.expect(t, found, "long name exact on pass")
	}
}

// test_mount_write_buf_fd_backed_partial_is_eio — an fd-backed bufvec at an
// unaligned offset cannot stage through the sector buffer. It must report
// EIO, not panic through the C boundary (and not a silent short count).
@(test)
test_mount_write_buf_fd_backed_partial_is_eio :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)
	cleanup_root(&fsys, []string{"fdfile"})
	defer cleanup_root(&fsys, []string{"fdfile"})

	fi: fuse3.File_Info
	rc := mounter.fused_create("/fdfile", posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)

	bv: fuse3.Bufvec
	bv.count = 1
	bv._buf[0] = fuse3.Buf{
		size  = 10,
		flags = {.Is_Fd},
		fd    = -1,
	}
	// off=1: unaligned head forces the copy path, which has no userspace
	// address for fd-backed bufs.
	rc = mounter.fused_write_buf("/fdfile", &bv, 1, &fi)
	expect_errno(t, rc, .EIO)
}

// test_mount_write_span_overflow_is_eoverflow — a write span whose end wraps
// u64 must fail closed with EOVERFLOW instead of shrinking the allocation
// (which would let the write run past it).
@(test)
test_mount_write_span_overflow_is_eoverflow :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)
	cleanup_root(&fsys, []string{"ovfile"})
	defer cleanup_root(&fsys, []string{"ovfile"})

	fi: fuse3.File_Info
	rc := mounter.fused_create("/ovfile", posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)

	// off + size wraps u64: must not allocate, must report EOVERFLOW.
	// buf is never touched (the span check runs first), so nil is fine.
	rc = mounter.fused_write("/ovfile", nil, max(c.size_t), 512, &fi)
	expect_errno(t, rc, .EOVERFLOW)

	// Sanity: a normal write on the same handle still works.
	data := "overflow-guard\n"
	rc = mounter.fused_write("/ovfile", raw_data(data), c.size_t(len(data)), 0, &fi)
	testing.expect_value(t, rc, c.int(len(data)))
}

// test_mount_negative_offsets_are_einval — negative offsets/sizes wrap on
// u64 conversion, so the boundary rejects them with EINVAL before any
// arithmetic (defense-in-depth; the kernel never delivers them).
@(test)
test_mount_negative_offsets_are_einval :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)
	cleanup_root(&fsys, []string{"negfile"})
	defer cleanup_root(&fsys, []string{"negfile"})

	fi: fuse3.File_Info
	rc := mounter.fused_create("/negfile", posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)

	data := "negative-guard\n"
	rc = mounter.fused_write("/negfile", raw_data(data), c.size_t(len(data)), -1, &fi)
	expect_errno(t, rc, .EINVAL)

	buf := make([]u8, 64)
	defer delete(buf)
	rc = mounter.fused_read("/negfile", raw_data(buf), c.size_t(len(data)), -1, &fi)
	expect_errno(t, rc, .EINVAL)

	rc = mounter.fused_truncate("/negfile", -1, nil)
	expect_errno(t, rc, .EINVAL)

	rc = mounter.fused_fallocate("/negfile", 0, -1, 512, &fi)
	expect_errno(t, rc, .EINVAL)
	rc = mounter.fused_fallocate("/negfile", 0, 0, -1, &fi)
	expect_errno(t, rc, .EINVAL)

	// Sanity: the handle still works after rejected calls.
	rc = mounter.fused_write("/negfile", raw_data(data), c.size_t(len(data)), 0, &fi)
	testing.expect_value(t, rc, c.int(len(data)))
}

// test_lfn_cache_key_distinct pins Lfn_Cache_Key injectivity: the key names
// an entry by directory plus chain-relative index with no packing, so
// distinct entries cannot collide the way the old u64 word did past 2^16
// entries per directory. Identical triples still match.
@(test)
test_lfn_cache_key_distinct :: proc(t: ^testing.T) {
	a := mounter.Lfn_Cache_Key{dir = {7, 0}, index = 0x20000}
	b := mounter.Lfn_Cache_Key{dir = {7, 2}, index = 0}
	testing.expect(t, a != b, "distinct entries must differ")
	c := mounter.Lfn_Cache_Key{dir = {7, 2}, index = 0}
	testing.expect(t, b == c, "identical entries must match")
}

// test_mount_create_past_dir_extend — fill a directory past its first
// sector (9 entries/sector) so find_or_extend_dir extends the chain
// repeatedly, then verify every file resolves. Without the post-extension
// extent-cache invalidate, the re-resolve hits the pre-extend chain and
// new files land in the full old tail sector, overwriting siblings
// (fewer names in readdir, getattr misses).
@(test)
test_mount_create_past_dir_extend :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)

	fi: fuse3.File_Info
	rc := mounter.fused_mkdir("/bigdir", posix.mode_t{.IRUSR, .IWUSR, .IXUSR})
	testing.expect_value(t, rc, 0)

	path_buf: [32]u8
	copy(path_buf[:], "/bigdir/F")
	for i in 0 ..< 30 {
		path_buf[9] = u8('0' + (i / 10))
		path_buf[10] = u8('0' + (i % 10))
		path_buf[11] = 0
		rc = mounter.fused_create(cstring(raw_data(path_buf[:])), posix.mode_t{.IRUSR, .IWUSR}, &fi)
		testing.expect_value(t, rc, 0)
	}

	collector: Dir_Collector
	rc = mounter.fused_readdir("/bigdir", &collector, collect_filler, 0, nil, 0)
	testing.expect_value(t, rc, 0)
	found := 0
	list := strings.split(string(collector.buf[:collector.len]), "\x00")
	defer delete(list)
	for e in list {
		if len(e) == 3 && e[0] == 'F' { found += 1 }
	}
	testing.expect(t, found == 30, "all 30 files listed")

	st: fuse3.Stat
	for i in 0 ..< 30 {
		path_buf[9] = u8('0' + (i / 10))
		path_buf[10] = u8('0' + (i % 10))
		path_buf[11] = 0
		rc = mounter.fused_getattr(cstring(raw_data(path_buf[:])), &st, nil)
		testing.expect_value(t, rc, 0)
	}
}

// test_map_key_roundtrip pins that struct map keys hash identically
// whether built as literals or field-wise (padding stays zero in both
// constructions). Covers all four key types; a toolchain change in
// zero-init would flip these from hits to misses.
@(test)
test_map_key_roundtrip :: proc(t: ^testing.T) {
	m1 := make(map[fs.File_Identity]int)
	defer delete(m1)
	m1[fs.File_Identity{fs.Cluster(7), fs.Sector_Offset(2), 3}] = 1
	k1: fs.File_Identity
	k1.dir_cluster = fs.Cluster(7)
	k1.dir_offset = fs.Sector_Offset(2)
	k1.entry_index = 3
	v1, ok1 := m1[k1]
	testing.expect(t, ok1 && v1 == 1, "File_Identity roundtrip")

	m2 := make(map[fs.Chain_Location]int)
	defer delete(m2)
	m2[fs.Chain_Location{fs.Cluster(7), fs.Sector_Offset(2)}] = 1
	k2: fs.Chain_Location
	k2.cluster = fs.Cluster(7)
	k2.offset = fs.Sector_Offset(2)
	v2, ok2 := m2[k2]
	testing.expect(t, ok2 && v2 == 1, "Chain_Location roundtrip")

	m3 := make(map[mounter.Lfn_Cache_Key]int)
	defer delete(m3)
	m3[mounter.Lfn_Cache_Key{dir = fs.Chain_Location{fs.Cluster(7), fs.Sector_Offset(0)}, index = 0x20000}] = 1
	k3: mounter.Lfn_Cache_Key
	k3.dir = fs.Chain_Location{fs.Cluster(7), fs.Sector_Offset(0)}
	k3.index = 0x20000
	v3, ok3 := m3[k3]
	testing.expect(t, ok3 && v3 == 1, "Lfn_Cache_Key roundtrip")

	m4 := make(map[mounter.Extent_Cache_Key]int)
	defer delete(m4)
	m4[mounter.Extent_Cache_Key{cluster = 7, offset = 2}] = 1
	k4: mounter.Extent_Cache_Key
	k4.cluster = 7
	k4.offset = 2
	v4, ok4 := m4[k4]
	testing.expect(t, ok4 && v4 == 1, "Extent_Cache_Key roundtrip")
}

// readdir_names collects one listing and reports whether name is present.
readdir_has :: proc(t: ^testing.T, path: cstring, off: posix.off_t, name: string) -> bool {
	collector: Dir_Collector
	rc := mounter.fused_readdir(path, &collector, collect_filler, off, nil, 0)
	testing.expect_value(t, rc, 0)
	list := strings.split(string(collector.buf[:collector.len]), "\x00")
	defer delete(list)
	for e in list {
		if e == name { return true }
	}
	return false
}

// readdir_count collects one listing and returns the non-empty name count.
readdir_count :: proc(t: ^testing.T, path: cstring, off: posix.off_t) -> int {
	collector: Dir_Collector
	rc := mounter.fused_readdir(path, &collector, collect_filler, off, nil, 0)
	testing.expect_value(t, rc, 0)
	list := strings.split(string(collector.buf[:collector.len]), "\x00")
	defer delete(list)
	n := 0
	for e in list {
		if len(e) > 0 { n += 1 }
	}
	return n
}

// test_mount_readdir_resume — FUSE resume cookies: off=0 lists all; off=k
// skips every item with cookie <= k (.=1, ..=2, entries 3+position), so a
// resume concatenates exactly with its skipped prefix. Without cookies the
// kernel re-requests from "." forever on directories that overflow its
// getdents buffer.
@(test)
test_mount_readdir_resume :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)

	fi: fuse3.File_Info
	rc := mounter.fused_mkdir("/rdir", posix.mode_t{.IRUSR, .IWUSR, .IXUSR})
	testing.expect_value(t, rc, 0)

	path_buf: [32]u8
	copy(path_buf[:], "/rdir/F")
	for i in 0 ..< 10 {
		path_buf[7] = u8('0' + (i / 10))
		path_buf[8] = u8('0' + (i % 10))
		path_buf[9] = 0
		rc = mounter.fused_create(cstring(raw_data(path_buf[:])), posix.mode_t{.IRUSR, .IWUSR}, &fi)
		testing.expect_value(t, rc, 0)
	}

	testing.expect(t, readdir_count(t, "/rdir", 0) == 12, "full listing")
	testing.expect(t, readdir_has(t, "/rdir", 0, "."), "dot at 0")
	testing.expect(t, readdir_has(t, "/rdir", 5, "F03"), "resume at F03")
	testing.expect(t, !readdir_has(t, "/rdir", 5, "F02"), "F02 skipped")
	testing.expect(t, !readdir_has(t, "/rdir", 5, "."), "dot skipped")
	testing.expect(t, !readdir_has(t, "/rdir", 1, "."), "dot skipped at 1")
	testing.expect(t, readdir_has(t, "/rdir", 1, ".."), "dotdot at 1")
	testing.expect(t, readdir_count(t, "/rdir", 5) == 7, "seven remain")
	testing.expect(t, readdir_count(t, "/rdir", 12) == 0, "nothing past end")
	testing.expect(t, readdir_count(t, "/rdir", 100) == 0, "nothing far past end")
}

// test_dir_extend_zeroes_new_sectors — stale-sector regression test.
// Neither allocate nor free zeroes data sectors, so a reused cluster keeps
// its old bytes; a stale slot with garbage .Exists bits would surface as a
// phantom entry and steal a real slot. mkdir zeroes its first sector and
// find_or_extend_dir zeroes each added sector — this test proves both by
// poisoning every free data sector first, so whatever the allocator takes
// is guaranteed stale. (Reserved clusters are skipped by range; allocated
// chains are skipped by their bitmap bits.)
@(test)
test_dir_extend_zeroes_new_sector :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)
	vol := &fsys.vol

	// Best-effort pre-clean, mirroring cleanup_root: a previous failed run
	// may have left /pdir behind.
	for i in 0 ..< 9 {
		path_buf: [32]u8
		copy(path_buf[:], "/pdir/F0")
		path_buf[8] = u8('0' + i)
		path_buf[9] = 0
		mounter.fused_unlink(cstring(raw_data(path_buf[:])))
	}
	mounter.fused_rmdir("/pdir")

	// Poison every free data sector with garbage Exists entries; collect
	// them for zero-back at the end. No allocation happens here, so the
	// free-space accounting and bitmaps stay consistent.
	poisoned := make([dynamic]fs.Sector)
	defer delete(poisoned)
	for ci in 0 ..< int(vol.master.cluster_map_size) {
		if u64(ci) < vol.master.root_cluster { continue }
		bm, _, berr := fs.alloc_cache_ensure(&vol.cache, vol, u64(ci))
		if berr != .None { continue }
		it := bit_array.make_iterator(&bm)
		for is_set, bit in bit_array.iterate_by_all(&it) {
			if is_set { continue }
			sec := fs.Sector(u64(ci) * vol.master.cluster_size + u64(bit))
			buf: [fs.SECTOR_SIZE]u8
			raw := (^[(fs.DIR_ENTRIES_PER_SECTOR)]fs.Directory_Entry)(raw_data(buf[:]))
			for i in 0 ..< fs.DIR_ENTRIES_PER_SECTOR {
				raw[i].flags = fs.Dir_Flags{.Allocated, .Exists}
				copy(raw[i].file_name[:], "POISON!")
				raw[i].file_name[7] = 0
			}
			testing.expect(t, fs.sector_write(vol, sec, buf[:]) == .None, "poison write")
			append(&poisoned, sec)
		}
	}
	testing.expect(t, len(poisoned) > 0, "poisoned some sectors")

	// mkdir takes a poisoned cluster: the fresh dir must read empty.
	fi: fuse3.File_Info
	rc := mounter.fused_mkdir("/pdir", posix.mode_t{.IRUSR, .IWUSR, .IXUSR})
	testing.expect_value(t, rc, 0)
	testing.expect(t, readdir_count(t, "/pdir", 0) == 2, "fresh dir is empty")

	// Fill the first sector, then extend into another poisoned cluster.
	path_buf: [32]u8
	copy(path_buf[:], "/pdir/F")
	for i in 0 ..< 8 {
		path_buf[7] = u8('0' + (i / 10))
		path_buf[8] = u8('0' + (i % 10))
		path_buf[9] = 0
		rc = mounter.fused_create(cstring(raw_data(path_buf[:])), posix.mode_t{.IRUSR, .IWUSR}, &fi)
		testing.expect_value(t, rc, 0)
	}
	path_buf[7] = '0'
	path_buf[8] = '8'
	path_buf[9] = 0
	rc = mounter.fused_create(cstring(raw_data(path_buf[:])), posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)
	st: fuse3.Stat
	rc = mounter.fused_getattr(cstring(raw_data(path_buf[:])), &st, nil)
	testing.expect_value(t, rc, 0)

	// Exact order: dots, F00..F08, nothing else. No phantoms, no gaps.
	want := [11]string{".", "..", "F00", "F01", "F02", "F03", "F04", "F05", "F06", "F07", "F08"}
	collector: Dir_Collector
	rc = mounter.fused_readdir("/pdir", &collector, collect_filler, 0, nil, 0)
	testing.expect_value(t, rc, 0)
	list := strings.split(string(collector.buf[:collector.len]), "\x00")
	defer delete(list)
	got := make([dynamic]string)
	defer delete(got)
	for e in list {
		if len(e) > 0 { append(&got, e) }
	}
	testing.expect(t, len(got) == len(want), "exact entry count")
	for i in 0 ..< min(len(got), len(want)) {
		testing.expectf(t, got[i] == want[i], "pos %d: want %q got %q", i, want[i], got[i])
	}

	// Remove the test dir, then zero back every poisoned sector so later
	// tests inherit no stale state from this one.
	for i in 0 ..< 9 {
		path_buf[7] = u8('0' + (i / 10))
		path_buf[8] = u8('0' + (i % 10))
		path_buf[9] = 0
		rc = mounter.fused_unlink(cstring(raw_data(path_buf[:])))
		testing.expect_value(t, rc, 0)
	}
	rc = mounter.fused_rmdir("/pdir")
	testing.expect_value(t, rc, 0)
	zero: [fs.SECTOR_SIZE]u8
	for sec in poisoned {
		testing.expect(t, fs.sector_write(vol, sec, zero[:]) == .None, "zero-back")
	}
}
// test_mount_rmdir_root_is_ebusy — removing the root must fail without
// touching it (resolve synthesizes root from the live master record, so
// removal would deallocate the real root chain). Linux reports EBUSY.
@(test)
test_mount_rmdir_root_is_ebusy :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)

	rc := mounter.fused_rmdir("/")
	expect_errno(t, rc, .EBUSY)

	// Root still resolves afterward.
	_, _, _, _, rerr := mounter.resolve_path_cached(&fsys, "/", context.temp_allocator)
	testing.expect_value(t, rerr, fs.FS_Error.None)
}

// test_mount_create_under_file_is_enotdir — create/mkdir/symlink under a
// regular file must report ENOTDIR instead of using the file's data chain
// as a directory.
@(test)
test_mount_create_under_file_is_enotdir :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)
	cleanup_root(&fsys, []string{"ndparent"})
	defer cleanup_root(&fsys, []string{"ndparent"})

	fi: fuse3.File_Info
	rc := mounter.fused_create("/ndparent", posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)
	if rc != 0 { return }

	rc = mounter.fused_create("/ndparent/child", posix.mode_t{.IRUSR, .IWUSR}, &fi)
	expect_errno(t, rc, .ENOTDIR)

	rc = mounter.fused_mkdir("/ndparent/dir", posix.mode_t{.IRUSR, .IWUSR, .IXUSR})
	expect_errno(t, rc, .ENOTDIR)

	rc = mounter.fused_symlink("target", "/ndparent/link")
	expect_errno(t, rc, .ENOTDIR)
}

// test_mount_symlink_multisector_roundtrip — a target spanning sectors
// must persist and read back exactly (was: only the first sector was
// written while file_size claimed the whole target, and readlink copied
// up to file_size bytes out of a 512-byte stack buffer).
@(test)
test_mount_symlink_multisector_roundtrip :: proc(t: ^testing.T) {
	fsys: mounter.FS
	ok := setup_mounter(t, &fsys)
	if !ok { return }
	defer teardown_mounter(&fsys)
	cleanup_root(&fsys, []string{"mlink"})
	defer cleanup_root(&fsys, []string{"mlink"})

	tlen := 1500
	tbuf := make([]u8, tlen)
	defer delete(tbuf)
	for i in 0 ..< tlen { tbuf[i] = u8(97 + (i % 26)) }
	target := make([]u8, tlen + 1)
	defer delete(target)
	copy(target, tbuf)
	target[tlen] = 0
	rc := mounter.fused_symlink(cstring(raw_data(target)), "/mlink")
	testing.expect_value(t, rc, 0)
	if rc != 0 { return }

	out := make([]u8, 2048)
	defer delete(out)
	n := mounter.fused_readlink("/mlink", ([^]c.char)(raw_data(out)), c.size_t(len(out)))
	testing.expect_value(t, n, 0)
	testing.expect(t, bytes_equal(out[:tlen], tbuf), "target round-trips")
	testing.expect_value(t, out[tlen], 0)
}
