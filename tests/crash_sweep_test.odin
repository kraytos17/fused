// crash_sweep_test.odin — T-05 slice 1: enumerated crash consistency.
//
// The late-fault sweep (single-shot) proves the rollback works when the
// disk keeps working. This sweep proves the other half: the process
// dies mid-op and the rollback never completes. A threshold fault at
// write n models process death between write n-1 and n — writes are
// pwrite to the host page cache, so every write that executed before
// the cut is durable, the nth and everything after never land, and the
// failing rollback writes never touch disk either. The FS shell is
// abandoned untrusted, the image re-opened through volume_open (journal
// recovery runs), and the crash window is judged:
//
//   recovery must succeed; the checker must be error-free (Orphan
//   warnings are expected crash residue — freed-in-window allocations
//   whose rollback never persisted); the entry state must be legal for
//   the op — exact end state if the op claimed success (an ignored
//   write such as the master rewrite can complete under a cut),
//   otherwise either durable outcome of the window, never a
//   half-applied one; and the recovered FS must still accept work.
//
// RENAME_EXCHANGE is the documented exception: two in-place slot writes
// are not one transaction, so the half-swap window is accepted (see
// fused_exchange_locked and the KNOWN_LIMITATIONS exchange entry); the
// structural rules (no checker errors, orphan-class findings only)
// still hold.
// scope: scratch image
#+build linux
package tests

import "core:c"
import "core:os"
import "core:sys/posix"
import "core:testing"
import "src:fs"
import "src:fuse3"
import "src:mounter"

CRASH_SWEEP_IMG :: "/dev/shm/fused_crash_sweep_test.img"

// Fixed per-op tree. The 4096/8192 sizes distinguish rename/exchange
// directions; the long names exercise the LFN path where D-06 found
// the leak-prone rollbacks.
CS_LONG_CREATE :: "/cs-create-long-name-0123456789"
CS_LONG_MKDIR :: "/cs-mkdir-long-name-0123456789"
CS_LONG_LINK :: "/cs-link-long-name-0123456789"
CS_FILE :: "/cs-file"
CS_DIR :: "/cs-dir"
CS_RSRC :: "/cs-rsrc"
CS_RDST :: "/cs-rdst"
CS_X1 :: "/cs-x1"
CS_X2 :: "/cs-x2"
CS_TEXT :: "/cs-text"
CS_TSHR :: "/cs-tshr"
CS_WFILE :: "/cs-wfile"
CS_RT :: "/cs-roundtrip"

// Crash_Op selects the mutating op under test.
Crash_Op :: enum {
	Create,
	Mkdir,
	Symlink,
	Unlink,
	Rmdir,
	Rename,
	Rename_Exchange,
	Truncate_Extend,
	Truncate_Shrink,
	Write,
}

// crash_make_file creates a file and fills it with a known pattern.
// The create assigns the file handle into fi, which the write reuses.
crash_make_file :: proc(path: cstring, bytes: int) -> bool {
	fi: fuse3.File_Info
	if mounter.fused_create(path, posix.mode_t{.IRUSR, .IWUSR}, &fi) != 0 {
		return false
	}
	if bytes == 0 { return true }
	data := make([]u8, bytes)
	defer delete(data)
	for i in 0 ..< len(data) {
		data[i] = u8(i & 0xff)
	}
	return mounter.fused_write(path, raw_data(data), c.size_t(len(data)), 0, &fi) == c.int(len(data))
}

// crash_setup builds the pre-op tree with faults off (uncounted
// writes): the op's write budget must measure the op alone.
crash_setup :: proc(op: Crash_Op) -> bool {
	fi: fuse3.File_Info
	switch op {
	case .Create, .Mkdir, .Symlink:
		return true
	case .Unlink:
		return mounter.fused_create(CS_FILE, posix.mode_t{.IRUSR, .IWUSR}, &fi) == 0
	case .Rmdir:
		return mounter.fused_mkdir(CS_DIR, posix.mode_t{.IRUSR, .IWUSR, .IXUSR}) == 0
	case .Rename:
		return crash_make_file(CS_RSRC, 4096) && crash_make_file(CS_RDST, 8192)
	case .Rename_Exchange:
		return crash_make_file(CS_X1, 4096) && crash_make_file(CS_X2, 8192)
	case .Truncate_Extend:
		return crash_make_file(CS_TEXT, 8192)
	case .Truncate_Shrink:
		return crash_make_file(CS_TSHR, 16384)
	case .Write:
		return crash_make_file(CS_WFILE, 0)
	}
	return false
}

// crash_op_ok reports whether the op completed: mutating callbacks
// return 0 on success, but write returns the transferred byte count.
crash_op_ok :: proc(op: Crash_Op, rc: c.int) -> bool {
	if op == .Write {
		return rc == 8192
	}
	return rc == 0
}

// crash_run_op performs the op once.
crash_run_op :: proc(op: Crash_Op) -> c.int {
	fi: fuse3.File_Info
	switch op {
	case .Create:
		return mounter.fused_create(CS_LONG_CREATE, posix.mode_t{.IRUSR, .IWUSR}, &fi)
	case .Mkdir:
		return mounter.fused_mkdir(CS_LONG_MKDIR, posix.mode_t{.IRUSR, .IWUSR, .IXUSR})
	case .Symlink:
		return mounter.fused_symlink("/Kernel", CS_LONG_LINK)
	case .Unlink:
		return mounter.fused_unlink(CS_FILE)
	case .Rmdir:
		return mounter.fused_rmdir(CS_DIR)
	case .Rename:
		return mounter.fused_rename(CS_RSRC, CS_RDST, 0)
	case .Rename_Exchange:
		return mounter.fused_rename(CS_X1, CS_X2, transmute(c.uint)(fuse3.Rename_Flags{.Exchange}))
	case .Truncate_Extend:
		return mounter.fused_truncate(CS_TEXT, 32768, nil)
	case .Truncate_Shrink:
		return mounter.fused_truncate(CS_TSHR, 0, nil)
	case .Write:
		fi2: fuse3.File_Info
		if mounter.fused_open(CS_WFILE, &fi2) != 0 {
			return fuse3.nix(.ENOENT)
		}
		wbuf: [8192]u8
		for i in 0 ..< len(wbuf) {
			wbuf[i] = u8(i & 0xff)
		}
		return mounter.fused_write(CS_WFILE, raw_data(wbuf[:]), c.size_t(len(wbuf)), 0, &fi2)
	}
	return -1
}

// crash_path_exists resolves a path against the recovered volume.
crash_path_exists :: proc(vol: ^fs.Volume, path: cstring) -> bool {
	_, rerr := fs.resolve_path(vol, string(path))
	return rerr == .None
}

// crash_size_of stats a path through the recovered mount.
crash_size_of :: proc(path: cstring) -> (size: i64, ok: bool) {
	st: fuse3.Stat
	if mounter.fused_getattr(path, &st, nil) != 0 {
		return 0, false
	}
	return i64(st.st_size), true
}

// crash_check_added — a creator's entry: must exist with the right kind
// when the op claimed success, may exist or not otherwise, and if it
// exists it must be complete (kind intact, link target intact).
crash_check_added :: proc(
	t: ^testing.T,
	op: Crash_Op,
	fsys: ^mounter.FS,
	path: cstring,
	want: posix.Mode_Bits,
	completed: bool,
	n: u64,
) -> bool {
	exists := crash_path_exists(&fsys.vol, path)
	testing.expectf(t, exists || !completed, "%v cut %d: claimed success but entry missing", op, n)
	if !exists && completed { return false }
	if !exists { return true }

	st: fuse3.Stat
	gerr := mounter.fused_getattr(path, &st, nil)
	testing.expectf(t, gerr == 0, "%v cut %d: entry present but getattr fails", op, n)
	if gerr != 0 { return false }
	testing.expectf(t, want in st.st_mode, "%v cut %d: entry present with wrong kind", op, n)
	if want not_in st.st_mode { return false }

	// A symlink must read back with its target intact.
	if want == .IFCHR {
		out: [256]u8
		nread := mounter.fused_readlink(path, raw_data(out[:]), c.size_t(len(out)))
		testing.expectf(t, nread == len("/Kernel"), "%v cut %d: link target torn (read %d)", op, n, nread)
		if nread != len("/Kernel") { return false }
		testing.expectf(t, string(out[:nread]) == "/Kernel", "%v cut %d: link target wrong", op, n)
		if string(out[:nread]) != "/Kernel" { return false }
	}
	return true
}

// crash_check_removed — an unlink/rmdir target: must be gone when the
// op claimed success, gone or intact otherwise.
crash_check_removed :: proc(
	t: ^testing.T,
	op: Crash_Op,
	fsys: ^mounter.FS,
	path: cstring,
	completed: bool,
	n: u64,
) -> bool {
	exists := crash_path_exists(&fsys.vol, path)
	testing.expectf(t, !exists || !completed, "%v cut %d: claimed success but entry still present", op, n)
	if exists && completed { return false }
	return true
}

// crash_check_rename — overwrite rename: target always exists; source
// present means not applied (target untouched) or the destruction-last
// transient (the moved entry took over the target slot, both names on
// one chain); source gone means applied. A cleared source with an
// un-updated target — silent data loss — stays illegal.
crash_check_rename :: proc(
	t: ^testing.T,
	op: Crash_Op,
	fsys: ^mounter.FS,
	src: cstring,
	dst: cstring,
	src_size: i64,
	dst_size: i64,
	completed: bool,
	n: u64,
) -> bool {
	dsz, dok := crash_size_of(dst)
	testing.expectf(t, dok, "%v cut %d: target missing", op, n)
	if !dok { return false }

	src_present := crash_path_exists(&fsys.vol, src)
	testing.expectf(
		t,
		!(completed && src_present),
		"%v cut %d: claimed success but source still present",
		op,
		n,
	)
	if completed && src_present { return false }

	if src_present {
		// Either not applied (target untouched) or the destruction-last
		// transient: the moved entry already took over the target slot
		// while the old source name still resolves to the same chain.
		// A cleared source with an un-updated target would be silent
		// data loss and stays illegal.
		legal := dsz == dst_size || dsz == src_size
		testing.expectf(
			t,
			legal,
			"%v cut %d: source present but target in an impossible state (size %d)",
			op, n, dsz,
		)
		if !legal { return false }
	} else {
		testing.expectf(
			t,
			dsz == src_size,
			"%v cut %d: source gone but target not updated (size %d)",
			op, n, dsz,
		)
		if dsz != src_size { return false }
	}
	return true
}

// crash_check_exchange — RENAME_EXCHANGE: both entries always exist and
// the size pair must be the originals, the swap, or the documented
// half-swap window (one slot exchanged, the other not — two in-place
// writes are not one transaction until E-03; fused_exchange_locked's
// crash-window note and KNOWN_LIMITATIONS pin this). The half-swap
// orphans the not-yet-moved content: structurally sound, no checker
// error, nothing dangling — but not a legal POSIX outcome, hence the
// separate, explicit acceptance here rather than in the strict rule.
crash_check_exchange :: proc(
	t: ^testing.T,
	op: Crash_Op,
	fsys: ^mounter.FS,
	a: cstring,
	b: cstring,
	sa: i64,
	sb: i64,
	completed: bool,
	n: u64,
) -> bool {
	s1, ok1 := crash_size_of(a)
	s2, ok2 := crash_size_of(b)
	testing.expectf(t, ok1 && ok2, "%v cut %d: exchange lost an entry", op, n)
	if !(ok1 && ok2) { return false }

	swapped := s1 == sb && s2 == sa
	original := s1 == sa && s2 == sb
	half_a_got_b := s1 == sb && s2 == sb
	half_b_got_a := s1 == sa && s2 == sa
	testing.expectf(
		t,
		swapped || original || half_a_got_b || half_b_got_a,
		"%v cut %d: impossible exchange state (sizes %d/%d)",
		op, n, s1, s2,
	)
	if !(swapped || original || half_a_got_b || half_b_got_a) { return false }
	testing.expectf(t, !completed || swapped, "%v cut %d: claimed success but not swapped", op, n)
	if completed && !swapped { return false }
	return true
}

// crash_check_resize — truncate/write: the size must be the old or the
// new value, never anything between; success claims the new value.
crash_check_resize :: proc(
	t: ^testing.T,
	op: Crash_Op,
	fsys: ^mounter.FS,
	path: cstring,
	old_size: i64,
	new_size: i64,
	completed: bool,
	n: u64,
) -> bool {
	sz, ok := crash_size_of(path)
	testing.expectf(t, ok, "%v cut %d: file missing", op, n)
	if !ok { return false }
	testing.expectf(
		t,
		sz == old_size || sz == new_size,
		"%v cut %d: torn size %d",
		op, n, sz,
	)
	if sz != old_size && sz != new_size { return false }
	testing.expectf(
		t,
		!completed || sz == new_size,
		"%v cut %d: claimed success but size %d",
		op, n, sz,
	)
	if completed && sz != new_size { return false }
	return true
}

// crash_check_invariant judges the crash window for one op on the
// recovered mount.
crash_check_invariant :: proc(
	t: ^testing.T,
	op: Crash_Op,
	fsys: ^mounter.FS,
	completed: bool,
	n: u64,
) -> bool {
	switch op {
	case .Create:
		return crash_check_added(t, op, fsys, CS_LONG_CREATE, .IFREG, completed, n)
	case .Mkdir:
		return crash_check_added(t, op, fsys, CS_LONG_MKDIR, .IFDIR, completed, n)
	case .Symlink:
		return crash_check_added(t, op, fsys, CS_LONG_LINK, .IFCHR, completed, n)
	case .Unlink:
		return crash_check_removed(t, op, fsys, CS_FILE, completed, n)
	case .Rmdir:
		return crash_check_removed(t, op, fsys, CS_DIR, completed, n)
	case .Rename:
		return crash_check_rename(t, op, fsys, CS_RSRC, CS_RDST, 4096, 8192, completed, n)
	case .Rename_Exchange:
		return crash_check_exchange(t, op, fsys, CS_X1, CS_X2, 4096, 8192, completed, n)
	case .Truncate_Extend:
		return crash_check_resize(t, op, fsys, CS_TEXT, 8192, 32768, completed, n)
	case .Truncate_Shrink:
		return crash_check_resize(t, op, fsys, CS_TSHR, 16384, 0, completed, n)
	case .Write:
		return crash_check_resize(t, op, fsys, CS_WFILE, 0, 8192, completed, n)
	}
	return false
}

// crash_count_writes runs a clean op on a fresh volume with setup and
// reports the op's write count. A fresh volume per run keeps the write
// sequence deterministic: every cut run follows the same path until the
// cut lands.
crash_count_writes :: proc(t: ^testing.T, op: Crash_Op) -> (writes: u64, ok: bool) {
	fsys: mounter.FS
	if !scratch_fs(t, CRASH_SWEEP_IMG, &fsys) { return }
	defer close_scratch_fs(&fsys, CRASH_SWEEP_IMG)

	if !crash_setup(op) {
		testing.expectf(t, false, "%v: setup failed", op)
		return
	}

	fsys.vol.fault = fs.IO_Fault {
		enabled           = true,
		fail_reads_after  = max(u64),
		fail_writes_after = max(u64),
		fail_syncs_after  = max(u64),
	}
	rc := crash_run_op(op)
	testing.expectf(t, crash_op_ok(op, rc), "%v: discovery run must succeed (rc=%d)", op, rc)
	if !crash_op_ok(op, rc) { return }

	writes = fsys.vol.fault.writes
	testing.expect(t, writes > 0, "a mutating op must write")
	ok = writes > 0
	return
}

// crash_cut kills the op at write n, abandons the shell, reopens with
// recovery, and judges the crash window.
crash_cut :: proc(t: ^testing.T, op: Crash_Op, n: u64) -> bool {
	fsys: mounter.FS
	if !scratch_fs(t, CRASH_SWEEP_IMG, &fsys) { return false }
	if !crash_setup(op) {
		testing.expectf(t, false, "%v cut %d: setup failed", op, n)
		close_scratch_fs(&fsys, CRASH_SWEEP_IMG)
		return false
	}

	// Process death between write n-1 and n: writes 1..n-1 are durable
	// (pwrite to the host page cache), the nth and everything after
	// never land. Reads and syncs keep working in-process; their
	// results die with the shell abandoned below.
	fsys.vol.fault = fs.IO_Fault {
		enabled           = true,
		fail_reads_after  = max(u64),
		fail_writes_after = n - 1,
		fail_syncs_after  = max(u64),
	}
	rc := crash_run_op(op)

	// Abandon the shell untrusted; the disk keeps writes 1..n-1.
	v := fsys.vol
	mounter.destroy_fs_for_test(&fsys)
	close_test_volume(&v)

	// Reopen: recovery replays the committed log.
	vol2, oerr := fs.volume_open(CRASH_SWEEP_IMG)
	testing.expectf(t, oerr == .None, "%v cut %d: recovery failed: %v", op, n, oerr)
	if oerr != .None {
		os.remove(CRASH_SWEEP_IMG)
		return false
	}

	fsys2 := new(mounter.FS)
	mounter.init_fs_for_test(fsys2, vol2)
	ctx := fuse3.Context {
		uid          = 1000,
		gid          = 1000,
		private_data = fsys2,
	}
	fuse3.set_test_context(&ctx)
	defer free(fsys2)
	defer close_scratch_fs(fsys2, CRASH_SWEEP_IMG)

	// Checker: errors are never legal; only Orphan warnings are.
	rep := fs.check_image(&fsys2.vol)
	defer fs.check_report_destroy(&rep)
	testing.expectf(t, rep.errors == 0, "%v cut %d: %d checker errors", op, n, rep.errors)
	if rep.errors != 0 { return false }
	for &f in rep.findings {
		testing.expectf(t, f.code == "Orphan", "%v cut %d: non-orphan finding %s", op, n, f.code)
		if f.code != "Orphan" { return false }
	}

	completed := crash_op_ok(op, rc)
	if !crash_check_invariant(t, op, fsys2, completed, n) { return false }

	// The recovered FS must still accept work: a fresh create+unlink
	// round trip returns the free count to its post-recovery baseline.
	base := fs.alloc_cache_count_free(&fsys2.vol)
	fi: fuse3.File_Info
	rrc := mounter.fused_create(CS_RT, posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expectf(t, rrc == 0, "%v cut %d: recovered FS refuses create", op, n)
	if rrc != 0 { return false }
	if mounter.fused_unlink(CS_RT) != 0 {
		testing.expectf(t, false, "%v cut %d: recovered FS refuses unlink", op, n)
		return false
	}
	free := fs.alloc_cache_count_free(&fsys2.vol)
	testing.expectf(t, free == base, "%v cut %d: round trip leaked (%d != %d)", op, n, free, base)
	if free != base { return false }
	return true
}

// test_crash_sweep_all_write_cuts — for every mutating op, cut every
// write of a successful run: recovery must converge, the image must be
// structurally sound, the entry state must be legal, and the recovered
// FS must keep working. This is the kill -9 crash-consistency property
// the T-05 crash simulator exists to prove, in-process and
// deterministic.
@(test)
test_crash_sweep_all_write_cuts :: proc(t: ^testing.T) {
	ops := [10]Crash_Op{
		.Create,
		.Mkdir,
		.Symlink,
		.Unlink,
		.Rmdir,
		.Rename,
		.Rename_Exchange,
		.Truncate_Extend,
		.Truncate_Shrink,
		.Write,
	}

	for op in ops {
		writes_total, ok := crash_count_writes(t, op)
		if !ok { return }

		for n in 1 ..= writes_total {
			if !crash_cut(t, op, n) { return }
		}
	}
}
