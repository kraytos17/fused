// late_fault_test.odin — late-fault enumeration with single-shot faults.
//
// Threshold faults cannot express "fail exactly once, then let the
// rollback's own I/O succeed" — everything after the cut fails, so a
// late failure's best-effort rollback always faulted too and its clean
// unwind was unverifiable (the D-06 / T-05 gap). Single-shot injection
// (IO_Fault.fail_once_class / fail_once_at) closes it: the sweep cuts
// every write of a successful create/mkdir/symlink run one at a time
// and requires each op to fail AND roll back completely — free count
// restored, no residue entry, checker clean.
//
// Rename-overwrite late faults are not in this sweep yet: rename's
// rollback spans two directory entries and is covered by the E-04
// matrix; it joins this enumeration with the T-05 crash simulator.
// scope: scratch image
#+build linux
package tests

import "core:c"
import "core:sys/posix"
import "core:testing"
import "src:fs"
import "src:fuse3"
import "src:mounter"

LATE_FAULT_SCRATCH :: "/dev/shm/fused_late_fault_test.img"
LATE_FAULT_LONG_NAME :: "late-fault-long-name-0123456789"

// Late_Fault_Op selects the creator under test.
Late_Fault_Op :: enum {
	Create,
	Mkdir,
	Symlink,
}

// late_fault_run_op runs the selected creator on a fresh long-name
// path (the LFN path, where D-06 found the leak-prone rollbacks).
late_fault_run_op :: proc(op: Late_Fault_Op, path: cstring) -> c.int {
	fi: fuse3.File_Info
	switch op {
	case .Create:
		return mounter.fused_create(path, posix.mode_t{.IRUSR, .IWUSR}, &fi)
	case .Mkdir:
		return mounter.fused_mkdir(path, posix.mode_t{.IRUSR, .IWUSR, .IXUSR})
	case .Symlink:
		return mounter.fused_symlink("/Kernel", path)
	}
	return -1
}

// late_fault_count_only arms counting without failure: all thresholds
// at max, so every op is counted and none fails.
late_fault_count_only :: proc(vol: ^fs.Volume) {
	vol.fault = fs.IO_Fault {
		enabled           = true,
		fail_reads_after  = max(u64),
		fail_writes_after = max(u64),
		fail_syncs_after  = max(u64),
	}
}

// late_fault_count_writes runs a clean op on a fresh volume and reports
// how many sector writes a successful run performs. A fresh volume per
// run keeps the write sequence deterministic across the sweep: every
// cut run follows the same path until the shot lands.
late_fault_count_writes :: proc(t: ^testing.T, op: Late_Fault_Op) -> (writes: u64, ok: bool) {
	fsys: mounter.FS
	if !scratch_fs(t, LATE_FAULT_SCRATCH, &fsys) { return }
	defer close_scratch_fs(&fsys, LATE_FAULT_SCRATCH)

	buf: [128]u8
	path := tpath(buf[:], "/%s", LATE_FAULT_LONG_NAME)

	late_fault_count_only(&fsys.vol)
	rc := late_fault_run_op(op, path)
	testing.expect_value(t, rc, 0)
	if rc != 0 { return }

	writes = fsys.vol.fault.writes
	testing.expect(t, writes > 0, "a successful creator must write")
	ok = writes > 0
	return
}

// late_fault_cut arms a single-shot write fault at n on a fresh volume,
// runs the op, and verifies failure plus a complete rollback: the op
// reports an error, the free count is restored, no entry remains, and
// the checker is clean.
late_fault_cut :: proc(t: ^testing.T, op: Late_Fault_Op, n: u64) -> bool {
	fsys: mounter.FS
	if !scratch_fs(t, LATE_FAULT_SCRATCH, &fsys) { return false }
	defer close_scratch_fs(&fsys, LATE_FAULT_SCRATCH)

	buf: [128]u8
	path := tpath(buf[:], "/%s", LATE_FAULT_LONG_NAME)
	f0 := fs.alloc_cache_count_free(&fsys.vol)

	fsys.vol.fault = fs.IO_Fault {
		enabled           = true,
		fail_reads_after  = max(u64),
		fail_writes_after = max(u64),
		fail_syncs_after  = max(u64),
		fail_once_class   = .Writes,
		fail_once_at      = n,
	}
	rc := late_fault_run_op(op, path)
	fsys.vol.fault.enabled = false
	testing.expectf(t, rc != 0, "%v: cut at write %d must fail the op", op, n)
	if rc == 0 { return false }

	// Rollback completed: every sector the op consumed is free again.
	free := fs.alloc_cache_count_free(&fsys.vol)
	testing.expect_value(t, free, f0)
	if free != f0 { return false }

	// No residue entry: the failed op left nothing behind.
	_, rerr := fs.resolve_path(&fsys.vol, string(path))
	testing.expectf(t, rerr != .None, "%v: cut at write %d left an entry", op, n)
	if rerr == .None { return false }

	// Checker clean: rollback I/O succeeded, so the image is coherent.
	rep := fs.check_image(&fsys.vol)
	defer fs.check_report_destroy(&rep)
	testing.expectf(
		t,
		rep.errors == 0,
		"%v: cut at write %d: %d checker errors",
		op,
		n,
		rep.errors,
	)
	if rep.errors != 0 { return false }
	testing.expectf(
		t,
		rep.warnings == 0,
		"%v: cut at write %d: %d checker warnings",
		op,
		n,
		rep.warnings,
	)
	if rep.warnings != 0 { return false }
	return true
}

// test_late_fault_rollback_enumeration — for each creator, cut every
// write of a successful run with a single-shot fault: the op must fail
// at that write and its rollback must complete cleanly (no leak, no
// residue, checker clean). This is the late-fault enumeration D-06
// deferred; threshold faults fault the rollback too and could not
// verify the unwind.
@(test)
test_late_fault_rollback_enumeration :: proc(t: ^testing.T) {
	ops := [3]Late_Fault_Op{.Create, .Mkdir, .Symlink}

	for op in ops {
		writes_total, ok := late_fault_count_writes(t, op)
		if !ok { return }

		for n in 1 ..= writes_total {
			if !late_fault_cut(t, op, n) { return }
		}
	}
}
