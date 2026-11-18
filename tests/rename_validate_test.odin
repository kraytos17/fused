// rename_validate_test.odin — E-04 step 2: POSIX rename errno matrix.
//
// The pure matrix (rename_validate) is tested table-driven over the full
// combination space; the callback (fused_rename) is tested through the
// errno contract that the kernel surfaces. Deliberate non-goal: mode-bit
// fidelity (E-01) and EXCHANGE (E-04 step 3).
// scope: scratch image
#+build linux
package tests

import "core:c"
import "core:fmt"
import "core:sys/posix"
import "core:testing"
import "src:fs"
import "src:fuse3"
import "src:mounter"

// test_rename_matrix_pure — every (src dir?, dst exists?, dst dir?,
// dst empty?, rflags) combination maps to the documented verdict.
@(test)
test_rename_matrix_pure :: proc(t: ^testing.T) {
	FILE: fs.Dir_Flags = {.Allocated, .Exists}
	DIR: fs.Dir_Flags = {.Allocated, .Directory, .Exists}

	Case :: struct {
		name:      string,
		src:       fs.Dir_Flags,
		dst_exist: bool,
		dst:       fs.Dir_Flags,
		dst_empty: bool,
		rflags:    fuse3.Rename_Flags,
		want:      mounter.Rename_Verdict,
	}
	cases := []Case {
		// dst absent: always Ok (both kinds).
		{"file->absent", FILE, false, {}, true, {}, .Ok},
		{"dir->absent", DIR, false, {}, true, {}, .Ok},
		// src file over dst dir: EISDIR regardless of emptiness.
		{"file->empty dir", FILE, true, DIR, true, {}, .Src_File_Dst_Dir},
		{"file->full dir", FILE, true, DIR, false, {}, .Src_File_Dst_Dir},
		// src dir over dst file: ENOTDIR.
		{"dir->file", DIR, true, FILE, true, {}, .Src_Dir_Dst_File},
		// src dir over dst dir: replace iff empty.
		{"dir->empty dir", DIR, true, DIR, true, {}, .Ok},
		{"dir->full dir", DIR, true, DIR, false, {}, .Dst_Not_Empty},
		// NOREPLACE wins as soon as dst exists, regardless of types.
		{"noreplace file->file", FILE, true, FILE, true, {.No_Replace}, .No_Replace_Exists},
		{"noreplace dir->absent", DIR, false, {}, true, {.No_Replace}, .Ok},
		{"noreplace file->dir", FILE, true, DIR, true, {.No_Replace}, .No_Replace_Exists},
		// WHITEOUT unsupported → EINVAL even when dst absent.
		{"whiteout absent", FILE, false, {}, true, {.Whiteout}, .Unsupported_Flag},
		{"whiteout exists", FILE, true, FILE, true, {.Whiteout}, .Unsupported_Flag},
		// EXCHANGE is short-circuited by the callback (ENOSYS); the pure
		// matrix is flag-agnostic for it (dst absent → Ok).
		{"exchange absent", FILE, false, {}, true, {.Exchange}, .Ok},
	}
	for &c in cases {
		got := mounter.rename_validate(c.src, c.dst_exist, c.dst, c.dst_empty, c.rflags)
		testing.expectf(t, got == c.want, "%s: got %v, want %v", c.name, got, c.want)
	}
}

// test_rename_matrix_callback — the errno contract through fused_rename.
@(test)
test_rename_matrix_callback :: proc(t: ^testing.T) {
	fsys: mounter.FS
	if !scratch_fs(t, "/dev/shm/fused_rename_matrix.img", &fsys) { return }
	defer close_scratch_fs(&fsys, "/dev/shm/fused_rename_matrix.img")

	expect_ok :: proc(t: ^testing.T, rc: c.int, what: string) {
		testing.expectf(t, rc == 0, "%s: rc=%d", what, rc)
	}

	// Fixtures: /fa (content "A"), /fb (content "B"), /d_empty, /d_full
	// (with child), plus /da, /db dirs for dir-over-dir moves.
	mkfile :: proc(t: ^testing.T, fsys: ^mounter.FS, path: cstring, data: string) {
		fi: fuse3.File_Info
		testing.expect_value(t, mounter.fused_create(path, posix.mode_t{.IRUSR, .IWUSR}, &fi), 0)
		testing.expect_value(
			t,
			mounter.fused_write(path, raw_data(data), c.size_t(len(data)), 0, &fi),
			c.int(len(data)),
		)
	}
	mkdir :: proc(t: ^testing.T, fsys: ^mounter.FS, path: cstring) {
		testing.expect_value(t, mounter.fused_mkdir(path, posix.mode_t{.IRUSR, .IWUSR, .IXUSR}), 0)
	}

	mkfile(t, &fsys, "/fa", "AAA")
	mkfile(t, &fsys, "/fb", "BBB")
	mkdir(t, &fsys, "/d_empty")
	mkdir(t, &fsys, "/d_full")
	mkfile(t, &fsys, "/d_full/child", "C")
	mkdir(t, &fsys, "/d_src")

	exists :: proc(t: ^testing.T, fsys: ^mounter.FS, path: string) -> bool {
		_, _, _, _, err := mounter.resolve_path_cached(fsys, path, context.temp_allocator)
		return err == fs.FS_Error.None
	}
	content_is :: proc(t: ^testing.T, fsys: ^mounter.FS, path: string, want: string) {
		res, rerr := fs.resolve_path(&fsys.vol, path, context.temp_allocator)
		testing.expect_value(t, rerr, fs.FS_Error.None)
		if rerr != .None { return }
		raw, xerr := fs.read_chain(&fsys.vol, fs.data_chain_of(res.entry), context.temp_allocator)
		testing.expect_value(t, xerr, fs.FS_Error.None)
		if xerr != .None { return }
		got := raw[:min(len(raw), int(res.entry.file_size))]
		testing.expectf(t, string(got) == want, "%s: content %q != %q", path, string(got), want)
	}
	NOREPLACE := transmute(c.uint)(fuse3.Rename_Flags{.No_Replace})
	WHITEOUT := transmute(c.uint)(fuse3.Rename_Flags{.Whiteout})

	// file → file replace: dst's old content is gone, src content moves.
	expect_ok(t, mounter.fused_rename("/fa", "/fb", 0), "file->file")
	testing.expect(t, exists(t, &fsys, "/fb"), "fb exists")
	testing.expect(t, !exists(t, &fsys, "/fa"), "fa gone")
	content_is(t, &fsys, "/fb", "AAA")

	// file → dir: EISDIR, both survive intact.
	expect_errno(t, mounter.fused_rename("/fb", "/d_empty", 0), .EISDIR)
	testing.expect(
		t,
		exists(t, &fsys, "/fb") && exists(t, &fsys, "/d_empty"),
		"both intact after EISDIR",
	)

	// dir → file: ENOTDIR, both survive intact.
	expect_errno(t, mounter.fused_rename("/d_src", "/fb", 0), .ENOTDIR)
	testing.expect(t, exists(t, &fsys, "/d_src"), "d_src intact after ENOTDIR")

	// dir → non-empty dir: ENOTEMPTY, both survive intact.
	expect_errno(t, mounter.fused_rename("/d_src", "/d_full", 0), .ENOTEMPTY)
	testing.expect(t, exists(t, &fsys, "/d_full/child"), "child intact")

	// dir → empty dir: replace (the old code's blanket EISDIR case).
	expect_ok(t, mounter.fused_rename("/d_src", "/d_empty", 0), "dir->empty dir")
	testing.expect(t, !exists(t, &fsys, "/d_src"), "d_src moved")
	testing.expect(t, exists(t, &fsys, "/d_empty"), "d_empty is now d_src")

	// NOREPLACE over existing → EEXIST; nothing changed.
	expect_errno(t, mounter.fused_rename("/fb", "/d_full", NOREPLACE), .EEXIST)
	testing.expect(
		t,
		exists(t, &fsys, "/fb") && exists(t, &fsys, "/d_full/child"),
		"both intact after NOREPLACE EEXIST",
	)

	// NOREPLACE to absent → plain rename.
	expect_ok(t, mounter.fused_rename("/fb", "/fb2", NOREPLACE), "noreplace absent")
	testing.expect(t, exists(t, &fsys, "/fb2") && !exists(t, &fsys, "/fb"), "moved")

	// WHITEOUT → EINVAL.
	expect_errno(t, mounter.fused_rename("/fb2", "/fb", WHITEOUT), .EINVAL)

	// Same-name no-op: success without touching the file (the old code
	// would clear the entry, free its chains, and write freed pointers
	// back — corruption).
	before := fs.alloc_cache_count_free(&fsys.vol)
	expect_ok(t, mounter.fused_rename("/fb2", "/fb2", 0), "same-name no-op")
	testing.expect_value(t, fs.alloc_cache_count_free(&fsys.vol), before)
	content_is(t, &fsys, "/fb2", "AAA")

	// Root and name guards.
	expect_errno(t, mounter.fused_rename("/", "/nope", 0), .EBUSY)
	expect_errno(t, mounter.fused_rename("/fb2", "/", 0), .EBUSY)
	expect_errno(t, mounter.fused_rename("/fb2", "/.", 0), .EINVAL)
	expect_errno(t, mounter.fused_rename("/fb2", "/..", 0), .EINVAL)

	// ENAMETOOLONG at 256; 255 works (LFN path). Distinct buffers: the
	// two tpath results must not alias.
	long_255_buf: [256]u8
	for i in 0 ..< 255 { long_255_buf[i] = 'x' }
	long_255 := string(long_255_buf[:255])
	old_buf: [300]u8
	old_path := tpath(old_buf[:], "/%s", long_255)
	expect_ok(t, mounter.fused_rename("/fb2", old_path, 0), "rename to 255")
	testing.expect(t, exists(t, &fsys, string(old_path)), "255-char name resolves")
	long_256_buf: [256]u8
	for i in 0 ..< 256 { long_256_buf[i] = 'y' }
	new_buf: [300]u8
	new_path := tpath(new_buf[:], "/%s", string(long_256_buf[:256]))
	expect_errno(t, mounter.fused_rename(old_path, new_path, 0), .ENAMETOOLONG)
	testing.expect(t, exists(t, &fsys, string(old_path)), "old name intact after ENAMETOOLONG")
}

// test_rename_exchange — E-04 step 3: RENAME_EXCHANGE swaps contents
// between two existing entries (any type mix); each path keeps its name,
// fds and advisory locks follow the content, cyclic dir relationships →
// EINVAL, missing → ENOENT, same slot → no-op.
@(test)
test_rename_exchange :: proc(t: ^testing.T) {
	fsys: mounter.FS
	if !scratch_fs(t, "/dev/shm/fused_rename_exchange.img", &fsys) { return }
	defer close_scratch_fs(&fsys, "/dev/shm/fused_rename_exchange.img")

	EXCHANGE := transmute(c.uint)(fuse3.Rename_Flags{.Exchange})

	mkfile :: proc(t: ^testing.T, fsys: ^mounter.FS, path: cstring, data: string) -> fuse3.File_Info {
		fi: fuse3.File_Info
		testing.expect_value(t, mounter.fused_create(path, posix.mode_t{.IRUSR, .IWUSR}, &fi), 0)
		testing.expect_value(
			t,
			mounter.fused_write(path, raw_data(data), c.size_t(len(data)), 0, &fi),
			c.int(len(data)),
		)
		return fi
	}
	mkdir :: proc(t: ^testing.T, fsys: ^mounter.FS, path: cstring) {
		testing.expect_value(
			t,
			mounter.fused_mkdir(path, posix.mode_t{.IRUSR, .IWUSR, .IXUSR}),
			0,
		)
	}
	exists :: proc(t: ^testing.T, fsys: ^mounter.FS, path: string) -> bool {
		_, _, _, _, err := mounter.resolve_path_cached(fsys, path, context.temp_allocator)
		return err == fs.FS_Error.None
	}
	content_at :: proc(t: ^testing.T, fsys: ^mounter.FS, path: string, want: string) {
		res, rerr := fs.resolve_path(&fsys.vol, path, context.temp_allocator)
		testing.expect_value(t, rerr, fs.FS_Error.None)
		if rerr != .None { return }
		raw, xerr := fs.read_chain(
			&fsys.vol,
			fs.data_chain_of(res.entry),
			context.temp_allocator,
		)
		testing.expect_value(t, xerr, fs.FS_Error.None)
		if xerr != .None { return }
		got := raw[:min(len(raw), int(res.entry.file_size))]
		testing.expectf(t, string(got) == want, "%s: %q != %q", path, string(got), want)
	}

	fi_a := mkfile(t, &fsys, "/fa", "AAAA")
	_ = fi_a
	mkfile(t, &fsys, "/fb", "BB")
	mkdir(t, &fsys, "/d1")
	mkdir(t, &fsys, "/d2")
	mkfile(t, &fsys, "/d1/one", "1")
	mkfile(t, &fsys, "/d2/two", "22")

	// file ↔ file: contents swap, names stay.
	testing.expect_value(t, mounter.fused_rename("/fa", "/fb", EXCHANGE), 0)
	content_at(t, &fsys, "/fa", "BB")
	content_at(t, &fsys, "/fb", "AAAA")

	// dir ↔ dir with children: children follow their (swapped) parents.
	testing.expect_value(t, mounter.fused_rename("/d1", "/d2", EXCHANGE), 0)
	testing.expect(t, exists(t, &fsys, "/d1/two"), "d1 now holds two")
	testing.expect(t, exists(t, &fsys, "/d2/one"), "d2 now holds one")
	content_at(t, &fsys, "/d1/two", "22")
	content_at(t, &fsys, "/d2/one", "1")

	// file ↔ dir (the old blanket-EISDIR case): type-agnostic by POSIX.
	testing.expect_value(t, mounter.fused_rename("/fa", "/d1", EXCHANGE), 0)
	// /fa is now the dir formerly known as d1 (holds "two").
	testing.expect(t, exists(t, &fsys, "/fa/two"), "fa is now the dir")
	// /d1 is now the file formerly known as fa (holds "BB").
	res, rerr := fs.resolve_path(&fsys.vol, "/d1", context.temp_allocator)
	testing.expect_value(t, rerr, fs.FS_Error.None)
	if rerr == .None {
		testing.expect(t, .Directory not_in res.entry.flags, "d1 is now a file")
	}

	// fds follow the content: the handle opened on /fa (before the two
	// exchanges) must still read AAAA — which now lives at /d1.
	buf := make([]u8, 8)
	defer delete(buf)
	n := mounter.fused_read("/fa", raw_data(buf), 4, 0, &fi_a)
	testing.expect_value(t, n, 4)
	testing.expect_value(t, string(buf[:n]), "AAAA")

	// Missing → ENOENT both ways.
	expect_errno(t, mounter.fused_rename("/nope", "/fb", EXCHANGE), .ENOENT)
	expect_errno(t, mounter.fused_rename("/fb", "/nope", EXCHANGE), .ENOENT)

	// Same path → no-op.
	testing.expect_value(t, mounter.fused_rename("/fb", "/fb", EXCHANGE), 0)

	// Root → EBUSY.
	expect_errno(t, mounter.fused_rename("/", "/fb", EXCHANGE), .EBUSY)
	expect_errno(t, mounter.fused_rename("/fb", "/", EXCHANGE), .EBUSY)

	// Cyclic: dir with its own descendant, both directions → EINVAL
	// (the child's slot lives inside the parent's chain, which the swap
	// would strand). Legal cross-subtree exchanges still work.
	mkdir(t, &fsys, "/dsub")
	mkdir(t, &fsys, "/dsub/deep")
	testing.expect_value(t, mounter.fused_rename("/d2", "/d2", EXCHANGE), 0) // self
	expect_errno(
		t,
		mounter.fused_rename("/dsub", "/dsub/deep", EXCHANGE),
		.EINVAL,
	)
	expect_errno(t, mounter.fused_rename("/dsub/deep", "/dsub", EXCHANGE), .EINVAL)
	// /d2 and /dsub/deep are in different subtrees: legal, succeeds.
	// (At this point /d2 holds "one"; /dsub/deep is empty.)
	testing.expect_value(
		t,
		mounter.fused_rename("/d2", "/dsub/deep", EXCHANGE),
		0,
	)
	testing.expect(t, exists(t, &fsys, "/dsub/deep/one"), "deep got d2's child")
	testing.expect(t, !exists(t, &fsys, "/d2/one"), "d2 now empty")

	// Checker: whole-run coherence (both subtrees intact, no orphans).
	rep := fs.check_image(&fsys.vol)
	defer fs.check_report_destroy(&rep)
	testing.expect_value(t, rep.errors, 0)
	testing.expect_value(t, rep.warnings, 0)
	if rep.errors != 0 || rep.warnings != 0 {
		for &fnd in rep.findings {
			fmt.println(fnd.code, fnd.detail)
		}
	}
}
