// used_entries_test.odin — D-13: statfs inode accounting.
//
// used_entries is seeded by a mount-time tree walk, incremented on
// create/mkdir/symlink/mknod success, decremented by
// remove_directory_entry after the cleared entry persists (covers
// unlink/rmdir/rename-overwrite). EXCHANGE and plain renames are
// entry-count-neutral. The checker cross-check pins the counter against
// an independent fs-level walk.
// scope: scratch image
#+build linux
package tests

import "core:c"
import "core:sys/posix"
import "core:testing"
import "src:fs"
import "src:fuse3"
import "src:mounter"

// statfs_free_entries reads f_ffree through the callback.
statfs_free_entries :: proc(t: ^testing.T, fsys: ^mounter.FS) -> u64 {
	st: posix.statvfs_t
	testing.expect_value(t, mounter.fused_statfs("/", &st), 0)
	return u64(st.f_ffree)
}

// expect_used asserts used_entries == want via both the counter and an
// independent fs-level walk (the checker-style cross-check).
expect_used :: proc(t: ^testing.T, fsys: ^mounter.FS, want: u64, what: string) {
	testing.expectf(
		t,
		fsys.used_entries == want,
		"%s: counter %d != %d",
		what,
		fsys.used_entries,
		want,
	)
	walked, werr := fs.count_tree_entries(&fsys.vol)
	testing.expect_value(t, werr, fs.FS_Error.None)
	testing.expectf(
		t,
		walked == want,
		"%s: walk %d != %d (counter drifted from disk)",
		what,
		walked,
		want,
	)
	// And the statfs projection agrees.
	cap :=
		fsys.vol.master.cluster_map_size *
		u64(mounter.dir_entries_per_buf(fsys.vol.master.features))
	free := statfs_free_entries(t, fsys)
	testing.expectf(t, free == cap - want, "%s: statfs ffree %d != %d", what, free, cap - want)
}

@(test)
test_used_entries_lifecycle :: proc(t: ^testing.T) {
	fsys: mounter.FS
	if !scratch_fs(t, "/dev/shm/fused_used_entries.img", &fsys) { return }
	defer close_scratch_fs(&fsys, "/dev/shm/fused_used_entries.img")

	cap :=
		fsys.vol.master.cluster_map_size *
		u64(mounter.dir_entries_per_buf(fsys.vol.master.features))
	testing.expect(t, cap > 8, "capacity sanity")

	fi: fuse3.File_Info
	expect_used(t, &fsys, 0, "fresh image")

	// create → +1
	testing.expect_value(t, mounter.fused_create("/a", posix.mode_t{.IRUSR, .IWUSR}, &fi), 0)
	expect_used(t, &fsys, 1, "create a")

	// mkdir → +1; nested create → +1
	testing.expect_value(t, mounter.fused_mkdir("/d", posix.mode_t{.IRUSR, .IWUSR, .IXUSR}), 0)
	expect_used(t, &fsys, 2, "mkdir d")
	testing.expect_value(t, mounter.fused_create("/d/b", posix.mode_t{.IRUSR, .IWUSR}, &fi), 0)
	expect_used(t, &fsys, 3, "create d/b")

	// symlink → +1
	testing.expect_value(t, mounter.fused_symlink("/a", "/slink"), 0)
	expect_used(t, &fsys, 4, "symlink")

	// mknod regular → +1
	testing.expect_value(t, mounter.fused_mknod("/n", posix.mode_t{.IFREG, .IRUSR, .IWUSR}, 0), 0)
	expect_used(t, &fsys, 5, "mknod")

	// unlink → -1
	testing.expect_value(t, mounter.fused_unlink("/d/b"), 0)
	expect_used(t, &fsys, 4, "unlink d/b")

	// rmdir (empty) → -1; rmdir non-empty is refused (no count change).
	testing.expect_value(t, mounter.fused_rmdir("/d"), 0)
	expect_used(t, &fsys, 3, "rmdir d")
	expect_errno(t, mounter.fused_rmdir("/d_full_x"), .ENOENT)
	expect_used(t, &fsys, 3, "failed rmdir unchanged")

	// cross-dir rename: count-neutral.
	testing.expect_value(t, mounter.fused_mkdir("/m", posix.mode_t{.IRUSR, .IWUSR, .IXUSR}), 0)
	testing.expect_value(t, mounter.fused_rename("/a", "/m/a2", 0), 0)
	expect_used(t, &fsys, 4, "cross-dir rename")

	// same-dir rename: count-neutral.
	testing.expect_value(t, mounter.fused_rename("/m/a2", "/m/a3", 0), 0)
	expect_used(t, &fsys, 4, "same-dir rename")

	// EXCHANGE: count-neutral (both entries persist).
	testing.expect_value(
		t,
		mounter.fused_rename("/m/a3", "/slink", transmute(c.uint)(fuse3.Rename_Flags{.Exchange})),
		0,
	)
	expect_used(t, &fsys, 4, "exchange")

	// rename-overwrite removes the dst → -1.
	testing.expect_value(t, mounter.fused_rename("/n", "/m/a3", 0), 0)
	expect_used(t, &fsys, 3, "rename overwrite dst")

	// failed create (name exists) → no change.
	expect_errno(t, mounter.fused_create("/m/a3", posix.mode_t{.IRUSR, .IWUSR}, &fi), .EEXIST)
	expect_used(t, &fsys, 3, "failed create unchanged")

	// drain to zero. (/n was consumed by the overwrite rename above: its
	// slot was cleared and its content renamed to /m/a3. /m is still a
	// dir and must be removed too.)
	testing.expect_value(t, mounter.fused_unlink("/m/a3"), 0)
	testing.expect_value(t, mounter.fused_unlink("/slink"), 0)
	testing.expect_value(t, mounter.fused_rmdir("/m"), 0)
	expect_used(t, &fsys, 0, "drained")

	// Checker: whole-image coherence after the churn.
	rep := fs.check_image(&fsys.vol)
	defer fs.check_report_destroy(&rep)
	testing.expect_value(t, rep.errors, 0)
	testing.expect_value(t, rep.warnings, 0)
}

// test_used_entries_seeded_from_disk — the mount walk picks up entries
// that already exist on the image (not just mount-session creations):
// create, tear down the FS shell (volume stays open), re-init a new FS
// shell on the same volume, and verify the counter.
@(test)
test_used_entries_seeded_from_disk :: proc(t: ^testing.T) {
	fsys: mounter.FS
	if !scratch_fs(t, "/dev/shm/fused_used_seed.img", &fsys) { return }
	defer close_scratch_fs(&fsys, "/dev/shm/fused_used_seed.img")

	fi: fuse3.File_Info
	testing.expect_value(t, mounter.fused_create("/keep", posix.mode_t{.IRUSR, .IWUSR}, &fi), 0)
	testing.expect_value(t, mounter.fused_mkdir("/kdir", posix.mode_t{.IRUSR, .IWUSR, .IXUSR}), 0)
	testing.expect_value(
		t,
		mounter.fused_create("/kdir/inner", posix.mode_t{.IRUSR, .IWUSR}, &fi),
		0,
	)
	expect_used(t, &fsys, 3, "pre-teardown")

	// Drop the FS shell (caches + counter) but keep the volume open.
	// destroy_fs_for_test zeroes the whole struct, so the volume comes
	// out first (the documented caller pattern).
	v := fsys.vol
	mounter.destroy_fs_for_test(&fsys)
	mounter.init_fs_for_test(&fsys, v)
	expect_used(t, &fsys, 3, "re-seeded from disk")
}
