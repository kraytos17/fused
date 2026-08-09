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

	fsys^ = mounter.init_fs_for_test(vol)
	ctx := fuse3.Context{
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
		buf := make([]u8, 1 + len(name))
		buf[0] = '/'
		copy(buf[1:], name)
		path := string(buf)
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

collect_filler :: proc "c" (buf: rawptr, name: cstring, stbuf: ^fuse3.Stat, off: posix.off_t, flags: c.int) -> c.int {
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
@test
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
@test
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
	found_dot   := false
	found_dotdot := false
	found_kernel := false
	for e in list {
		switch e {
		case ".":  found_dot = true
		case "..": found_dotdot = true
		case "Kernel": found_kernel = true
		}
	}
	
	testing.expect(t, found_dot, "has .")
	testing.expect(t, found_dotdot, "has ..")
	testing.expect(t, found_kernel, "has Kernel")
}

// test_mount_create_write_read_unlink — full file lifecycle.
@test
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
@test
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
@test
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
@test
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
@test
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
@test
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
@test
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
@test
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

	// CREATE on existing → EEXIST.
	rc = mounter.fused_setxattr("/Kernel", "user.color", raw_data(blue), 4, fuse3.XATTR_CREATE)
	expect_errno(t, rc, .EEXIST)

	// REPLACE on missing → ENODATA.
	rc = mounter.fused_setxattr("/Kernel", "user.nope", raw_data(one_char), 1, fuse3.XATTR_REPLACE)
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
@test
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
@test
test_mount_fs_error_to_errno :: proc(t: ^testing.T) {
	// (FS_Error, expected c.int) pairs.
	Cases :: struct { err: fs.FS_Error, want: c.int }
	cases := []Cases{
		{fs.FS_Error.None, c.int(0)},
		{fs.FS_Error.Entry_Not_Found, c.int(-int(posix.ENOENT))},
		{fs.FS_Error.Not_A_Directory, c.int(-int(posix.ENOTDIR))},
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
