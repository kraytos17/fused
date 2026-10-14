// lock.odin — POSIX fcntl (lock) and BSD flock (flock) advisory locks.
//
// Both lock types are in-memory only — no on-disk format change.  Lock state
// is per-mount and lost on unmount, matching advisory-lock semantics (locks
// are process-lifetime state).  fused_lock/fused_flock serialize on the write
// lock via begin_op/end_op (and fused_release, which mutates the tables on
// close, does too), so a plain map + dynamic arrays is thread-safe.
#+build linux
package mounter

import "base:runtime"
import "core:c"
import "core:log"
import "core:sys/posix"
import "src:fuse3"

// LOCK_* constants for the BSD flock() op (sys/file.h).
LOCK_SH :: c.int(1) // shared lock
LOCK_EX :: c.int(2) // exclusive lock
LOCK_NB :: c.int(4) // don't block when locking
LOCK_UN :: c.int(8) // unlock

// FUSE_CAP_* capability flags (linux/fuse.h) advertised in the INIT handshake
// so the kernel forwards lock requests to userspace.
FUSE_POSIX_LOCKS :: c.uint32_t(1 << 1) // remote POSIX fcntl locks
FUSE_FLOCK_LOCKS :: c.uint32_t(1 << 10) // remote BSD flock

// Region_Lock is one POSIX (fcntl) lock record.
Region_Lock :: struct {
	owner: u64, // fi.lock_owner
	pid:   posix.pid_t, // flock.l_pid (for F_GETLK reporting)
	start: i64, // byte offset
	len:   i64, // length in bytes (0 = to EOF)
	mode:  Lock_Mode, // .Exclusive = F_WRLCK, .Shared = F_RDLCK
}

// Flock_State is one BSD flock holder on a file (whole-file).  A file may
// have many shared holders or a single exclusive holder.
Flock_State :: struct {
	owner: u64, // fi.lock_owner
	mode:  Lock_Mode, // .Exclusive = LOCK_EX, .Shared = LOCK_SH
}

// Lock_Mode is the shared/exclusive distinction shared by POSIX region locks
// and BSD flock holders (both previously carried it as an `exclusive` bool).
Lock_Mode :: enum {
	Shared,
	Exclusive,
}

// Flock_Cmd is the parsed BSD flock operation: the base command plus the
// non-blocking modifier. Parsed once at the FUSE boundary (fused_flock) so
// the holder state machine below switches on an enum instead of re-testing
// raw LOCK_* bits. (The LOCK_* constants themselves stay c.int — they are
// ABI values, not a bit_set — only the parse is typed.)
Flock_Cmd :: enum {
	Unlock,
	Shared,
	Exclusive,
}

// flock_parse_op splits a flock op word into its base command and modifier.
// Precedence matches flock(2): UN dominates, then EX, anything else reads as
// Shared (preserving the historical fallthrough for op words with no base
// bits set). LOCK_NB is reported but needs no branch: conflicts always
// return EAGAIN since FUSE callbacks cannot block (documented limitation).
flock_parse_op :: proc(op: c.int) -> (cmd: Flock_Cmd, nonblock: bool) {
	nonblock = op & LOCK_NB != 0
	switch {
	case op & LOCK_UN != 0:
		return .Unlock, nonblock
	case op & LOCK_EX != 0:
		return .Exclusive, nonblock
	case:
		return .Shared, nonblock
	}
}

// lock_mode_from_type maps a POSIX flock type to a Lock_Mode. UNLCK never
// reaches here (callers filter it first); treat it as Shared defensively.
lock_mode_from_type :: proc(t: posix.Lock_Type) -> Lock_Mode {
	return .Exclusive if t == posix.Lock_Type.WRLCK else .Shared
}

// locks_remove_identity drops all lock state for an identity.
locks_remove_identity :: proc(fsys: ^FS, id: File_Identity) {
	if recs, ok := fsys.locks[id]; ok {
		delete(recs)
		delete_key(&fsys.locks, id)
	}
	if fls, ok := fsys.flock_locks[id]; ok {
		delete(fls)
		delete_key(&fsys.flock_locks, id)
	}
}

// _retain_owner_mismatch rebuilds a holder list without one owner's entries.
// Both holder structs carry `owner: u64`, so one parametric proc serves both
// lock tables (resolved per instantiation). The fresh list takes the
// caller's allocator explicitly; dynamics carry it, so later deletes stay
// paired regardless of the freeing caller's context.
@(private = "file")
_retain_owner_mismatch :: proc(
	old: [dynamic]$T,
	owner: u64,
	allocator := context.allocator,
) -> (
	kept: [dynamic]T,
) {
	kept = make([dynamic]T, 0, len(old), allocator)
	for r in old {
		if r.owner == owner { continue }
		append(&kept, r)
	}
	return kept
}

// locks_remove_owner drops one owner's locks for an identity (used on
// release — the kernel releases a process's locks when its last fd closes).
locks_remove_owner :: proc(fsys: ^FS, id: File_Identity, owner: u64) {
	if old, has := fsys.locks[id]; has {
		recs := _retain_owner_mismatch(old, owner, fsys.allocator)
		delete(old)
		if len(recs) == 0 {
			delete(recs)
			delete_key(&fsys.locks, id)
		} else {
			fsys.locks[id] = recs
		}
	}
	if old, has := fsys.flock_locks[id]; has {
		fls := _retain_owner_mismatch(old, owner, fsys.allocator)
		delete(old)
		if len(fls) == 0 {
			delete(fls)
			delete_key(&fsys.flock_locks, id)
		} else {
			fsys.flock_locks[id] = fls
		}
	}
}

// locks_remove_file drops all lock state for an entry (used on unlink/rmdir).
locks_remove_file :: proc(fsys: ^FS, fh: u64) {
	locks_remove_identity(fsys, fh_parts(fh))
}

// lock_range_overlaps reports whether two ranges [a_start, a_end) and
// [b_start, b_end) overlap.  len == 0 means "to EOF".
lock_range_overlaps :: proc(a_start, a_len, b_start, b_len: i64) -> bool {
	a_end := i64(max(i64) if a_len == 0 else a_start + a_len)
	b_end := i64(max(i64) if b_len == 0 else b_start + b_len)
	return a_start < b_end && b_start < a_end
}

// lock_mutate applies a F_SETLK/F_SETLKW request to the file's region-lock
// list, swapping a fresh list into the map and freeing the old one.
lock_mutate :: proc(fsys: ^FS, id: File_Identity, owner: u64, fl: ^posix.flock) -> c.int {
	start := i64(fl.l_start)
	length := i64(fl.l_len)
	old, has_old := fsys.locks[id]
	recs := make([dynamic]Region_Lock, 0, 4)
	if has_old {
		append(&recs, ..old[:])
	}
	// F_UNLCK: remove matching records for this owner.
	if fl.l_type == posix.Lock_Type.UNLCK {
		kept := 0
		for i in 0 ..< len(recs) {
			r := recs[i]
			if r.owner == owner && r.start == start && r.len == length {
				continue
			}
			recs[kept] = r
			kept += 1
		}
		if kept == 0 {
			delete(recs)
			delete_key(&fsys.locks, id)
		} else {
			resize(&recs, kept)
			fsys.locks[id] = recs
		}

		if has_old {
			delete(old)
		}
		return 0
	}

	// Conflict check.  A write (exclusive) request conflicts with any
	// overlapping lock from another owner (shared or exclusive); a read
	// (shared) request conflicts only with another owner's exclusive lock.
	req_mode := lock_mode_from_type(fl.l_type)
	for r in recs {
		if r.owner == owner { continue }
		if lock_range_overlaps(r.start, r.len, start, length) &&
		   (req_mode == .Exclusive || r.mode == .Exclusive) {
			delete(recs)
			return fuse3.nix(.EAGAIN)
		}
	}

	// Replace any same-owner overlapping record, else append.
	replaced := false
	for &r in recs {
		if r.owner == owner && lock_range_overlaps(r.start, r.len, start, length) {
			r.start = start
			r.len = length
			r.pid = fl.l_pid
			r.mode = lock_mode_from_type(fl.l_type)
			replaced = true
			break
		}
	}
	if !replaced {
		append(
			&recs,
			Region_Lock {
				owner = owner,
				pid = fl.l_pid,
				start = start,
				len = length,
				mode = lock_mode_from_type(fl.l_type),
			},
		)
	}

	fsys.locks[id] = recs
	if has_old {
		delete(old)
	}
	return 0
}

// fused_lock implements POSIX fcntl-style region locks (F_SETLK/F_SETLKW/F_GETLK).
//   cmd: F_GETLK(7), F_SETLK(8), F_SETLKW(9)
//   lock: ^posix.flock (l_start, l_len, l_pid, l_type, l_whence)
// F_SETLKW is treated as non-blocking F_SETLK (a blocking wait would deadlock
// the single-threaded-per-mount callback; documented limitation).
fused_lock :: proc "c" (path: cstring, fi: ^fuse3.File_Info, cmd: c.int, lock: rawptr) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)
	if lock == nil {
		return fuse3.nix(.EINVAL)
	}

	fl := (^posix.flock)(lock)
	id := fh_parts(fi.fh)
	owner := fi.lock_owner
	#partial switch posix.FCNTL_Cmd(cmd) {
	case posix.FCNTL_Cmd.GETLK:
		// Report the first conflicting exclusive lock from another owner.
		if recs, ok := fsys.locks[id]; ok {
			for &r in recs {
				if r.owner == owner { continue }
				if r.mode == .Exclusive &&
				   lock_range_overlaps(r.start, r.len, i64(fl.l_start), i64(fl.l_len)) {
					fl.l_type = posix.Lock_Type.WRLCK
					fl.l_pid = r.pid
					fl.l_start = posix.off_t(r.start)
					fl.l_len = posix.off_t(r.len)
					return 0
				}
			}
		}
		fl.l_type = posix.Lock_Type.UNLCK
		return 0
	case posix.FCNTL_Cmd.SETLK, posix.FCNTL_Cmd.SETLKW:
		return lock_mutate(fsys, id, owner, fl)
	case:
		log.debugf("lock: %s unsupported cmd=%d", path, cmd)
		return fuse3.nix(.EINVAL)
	}
}

// fused_flock implements BSD flock-style whole-file locks.
//   op: LOCK_SH | LOCK_EX | LOCK_UN, optionally LOCK_NB
// Multiple owners may hold LOCK_SH simultaneously; LOCK_EX excludes everyone
// else.  Without LOCK_NB a conflict would block; FUSE callbacks can't wait, so
// a conflict always returns EAGAIN (documented limitation).
fused_flock :: proc "c" (path: cstring, fi: ^fuse3.File_Info, op: c.int) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	defer end_op(fsys)

	id := fh_parts(fi.fh)
	owner := fi.lock_owner
	cmd, _ := flock_parse_op(op)
	// nonblock is discarded: conflicts always return EAGAIN (see parse).
	if cmd == .Unlock {
		locks_remove_owner(fsys, id, owner)
		return 0
	}

	mode := Lock_Mode.Shared if cmd == .Shared else .Exclusive
	// Snapshot current holders.
	old, has_old := fsys.flock_locks[id]
	holders := make([dynamic]Flock_State, 0, 4)
	if has_old {
		append(&holders, ..old[:])
	}
	if mode == .Exclusive {
		// LOCK_EX: conflicts with any other holder (SH or EX).
		for h in holders {
			if h.owner != owner {
				delete(holders)
				return fuse3.nix(.EAGAIN)
			}
		}

		// Same owner: upgrade/downgrade in place.
		found := false
		for &h in holders {
			if h.owner == owner {
				h.mode = .Exclusive
				found = true
				break
			}
		}
		if !found {
			append(&holders, Flock_State{owner = owner, mode = .Exclusive})
		}
	} else {
		// LOCK_SH: conflicts with another owner's exclusive lock.
		for h in holders {
			if h.owner != owner && h.mode == .Exclusive {
				delete(holders)
				return fuse3.nix(.EAGAIN)
			}
		}

		// Same owner: downgrade in place (or keep the shared hold).
		found := false
		for &h in holders {
			if h.owner == owner {
				h.mode = .Shared
				found = true
				break
			}
		}
		if !found {
			append(&holders, Flock_State{owner = owner, mode = .Shared})
		}
	}

	fsys.flock_locks[id] = holders
	if has_old {
		delete(old)
	}

	log.debugf("flock: %s owner=%d %s", path, owner, "EX" if mode == .Exclusive else "SH")
	return 0
}
