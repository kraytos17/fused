// lock_test.odin — Unit tests for POSIX fcntl locks (fused_lock) and BSD
// flock (fused_flock).
#+build linux
package tests

import "core:c"
import "core:sys/posix"
import "core:testing"
import "src:fuse3"
import "src:mounter"

// setup_lock_file creates a test file and returns its file info (fh set).
setup_lock_file :: proc(t: ^testing.T, fsys: ^mounter.FS, name: string) -> (fi: fuse3.File_Info, ok: bool) {
	fi = {}
	path := cstring(raw_data(name))
	rc := mounter.fused_create(path, posix.mode_t{.IRUSR, .IWUSR}, &fi)
	if rc != 0 {
		testing.expect_value(t, rc, 0)
		return {}, false
	}
	return fi, true
}

// test_lock_setlk_unlock — F_SETLK acquires, F_UNLCK releases.
@test
test_lock_setlk_unlock :: proc(t: ^testing.T) {
	fsys: mounter.FS
	if !setup_mounter(t, &fsys) { return }
	defer teardown_mounter(&fsys)

	fi, ok := setup_lock_file(t, &fsys, "/lock1")
	if !ok { return }

	fl: posix.flock
	fl.l_start = 0
	fl.l_len = 100
	fl.l_type = posix.Lock_Type.WRLCK
	fi.lock_owner = 1001

	rc := mounter.fused_lock("/lock1", &fi, c.int(posix.F_SETLK), &fl)
	testing.expect_value(t, rc, 0)

	// Same owner can replace.
	fl.l_len = 200
	rc = mounter.fused_lock("/lock1", &fi, c.int(posix.F_SETLK), &fl)
	testing.expect_value(t, rc, 0)

	// Unlock.
	fl.l_type = posix.Lock_Type.UNLCK
	rc = mounter.fused_lock("/lock1", &fi, c.int(posix.F_SETLK), &fl)
	testing.expect_value(t, rc, 0)
	mounter.fused_unlink("/lock1")
}

// test_lock_conflict_eagain — a different owner's exclusive lock conflicts.
@test
test_lock_conflict_eagain :: proc(t: ^testing.T) {
	fsys: mounter.FS
	if !setup_mounter(t, &fsys) { return }
	defer teardown_mounter(&fsys)

	fi, ok := setup_lock_file(t, &fsys, "/lock2")
	if !ok { return }

	// Owner A: exclusive lock on [0, 100).
	fla: posix.flock
	fla.l_start = 0
	fla.l_len = 100
	fla.l_type = posix.Lock_Type.WRLCK
	fi.lock_owner = 1001
	rc := mounter.fused_lock("/lock2", &fi, c.int(posix.F_SETLK), &fla)
	testing.expect_value(t, rc, 0)

	// Owner B: overlapping exclusive → EAGAIN.
	fib := fi
	fib.lock_owner = 1002
	flb: posix.flock
	flb.l_start = 50
	flb.l_len = 50
	flb.l_type = posix.Lock_Type.WRLCK
	rc = mounter.fused_lock("/lock2", &fib, c.int(posix.F_SETLK), &flb)
	testing.expect_value(t, rc, c.int(-int(posix.EAGAIN)))

	// Owner B: non-overlapping region succeeds.
	flb.l_start = 200
	flb.l_len = 50
	rc = mounter.fused_lock("/lock2", &fib, c.int(posix.F_SETLK), &flb)
	testing.expect_value(t, rc, 0)
	mounter.fused_unlink("/lock2")
}

// test_lock_getlk — F_GETLK reports a conflicting owner's lock.
@test
test_lock_getlk :: proc(t: ^testing.T) {
	fsys: mounter.FS
	if !setup_mounter(t, &fsys) { return }
	defer teardown_mounter(&fsys)

	fi, ok := setup_lock_file(t, &fsys, "/lock3")
	if !ok { return }

	fla: posix.flock
	fla.l_start = 0
	fla.l_len = 100
	fla.l_type = posix.Lock_Type.WRLCK
	fi.lock_owner = 1001
	rc := mounter.fused_lock("/lock3", &fi, c.int(posix.F_SETLK), &fla)
	testing.expect_value(t, rc, 0)

	// Owner B queries the same region.
	fib := fi
	fib.lock_owner = 1002
	flq: posix.flock
	flq.l_start = 0
	flq.l_len = 100
	rc = mounter.fused_lock("/lock3", &fib, c.int(posix.F_GETLK), &flq)
	testing.expect_value(t, rc, 0)
	testing.expect(t, flq.l_type == posix.Lock_Type.WRLCK, "GETLK reports WRLCK")
	testing.expect_value(t, flq.l_pid, fla.l_pid)

	// Owner A queries its own region → UNLCK (no conflict).
	rc = mounter.fused_lock("/lock3", &fi, c.int(posix.F_GETLK), &flq)
	testing.expect_value(t, rc, 0)
	testing.expect(t, flq.l_type == posix.Lock_Type.UNLCK, "same owner: UNLCK")
	mounter.fused_unlink("/lock3")
}

// test_flock_ex_unlock — LOCK_EX acquires, LOCK_UN releases, conflict EAGAIN.
@test
test_flock_ex_unlock :: proc(t: ^testing.T) {
	fsys: mounter.FS
	if !setup_mounter(t, &fsys) { return }
	defer teardown_mounter(&fsys)

	fi, ok := setup_lock_file(t, &fsys, "/flock1")
	if !ok { return }

	fi.lock_owner = 2001
	rc := mounter.fused_flock("/flock1", &fi, mounter.LOCK_EX)
	testing.expect_value(t, rc, 0)

	// Same owner can re-lock (upgrade path).
	rc = mounter.fused_flock("/flock1", &fi, mounter.LOCK_SH)
	testing.expect_value(t, rc, 0)

	// Different owner conflicts.
	fib := fi
	fib.lock_owner = 2002
	rc = mounter.fused_flock("/flock1", &fib, mounter.LOCK_EX)
	testing.expect_value(t, rc, c.int(-int(posix.EAGAIN)))

	// Unlock, then other owner succeeds.
	rc = mounter.fused_flock("/flock1", &fi, mounter.LOCK_UN)
	testing.expect_value(t, rc, 0)
	rc = mounter.fused_flock("/flock1", &fib, mounter.LOCK_EX)
	testing.expect_value(t, rc, 0)
	mounter.fused_unlink("/flock1")
}
