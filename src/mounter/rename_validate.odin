// rename_validate.odin — pure POSIX rename errno matrix.
//
// rename's dst/src type combinations have a POSIX-defined outcome table;
// encoding it once here (no I/O, no FUSE) lets the callback validate BEFORE
// any mutation and lets the table be tested exhaustively. The caller
// supplies dst emptiness only when the matrix needs it (dir over dir);
// for every other combination the field is ignored.
//
// Matrix (per POSIX rename(2):
//   src file:  dst absent → ok; dst file → replace; dst dir (either
//              emptiness) → EISDIR
//   src dir:   dst absent → ok; dst file → ENOTDIR; dst empty dir →
//              replace; dst non-empty dir → ENOTEMPTY
//   RENAME_NOREPLACE with dst existing → EEXIST regardless of types.
//   RENAME_WHITEOUT → EINVAL (not supported; renameat2(2) semantics for
//              an unsupported flag).
// RENAME_EXCHANGE bypasses this matrix entirely (fused_exchange_locked:
// type-agnostic content swap with its own cyclic guards).
#+build linux
package mounter

import "core:c"
import "src:fs"
import "src:fuse3"

Rename_Verdict :: enum {
	Ok,
	No_Replace_Exists, // RENAME_NOREPLACE, dst exists
	Src_Dir_Dst_File, // ENOTDIR
	Src_File_Dst_Dir, // EISDIR
	Dst_Not_Empty, // ENOTEMPTY
	Unsupported_Flag, // EINVAL (RENAME_WHITEOUT)
}

// rename_validate applies the matrix. dst_flags is meaningful only when
// dst_exists; dst_is_empty_dir only when both sides are directories.
@(require_results)
rename_validate :: proc(
	src_flags: fs.Dir_Flags,
	dst_exists: bool,
	dst_flags: fs.Dir_Flags,
	dst_is_empty_dir: bool,
	rflags: fuse3.Rename_Flags,
) -> Rename_Verdict {
	if .Whiteout in rflags {
		return .Unsupported_Flag
	}
	if !dst_exists {
		return .Ok
	}
	if .No_Replace in rflags {
		return .No_Replace_Exists
	}

	src_is_dir := .Directory in src_flags
	dst_is_dir := .Directory in dst_flags
	if !src_is_dir && dst_is_dir {
		return .Src_File_Dst_Dir
	}
	if src_is_dir && !dst_is_dir {
		return .Src_Dir_Dst_File
	}
	if src_is_dir && dst_is_dir && !dst_is_empty_dir {
		return .Dst_Not_Empty
	}
	return .Ok
}

// rename_verdict_rc maps a verdict to the FUSE callback return value
// (0 on Ok, negated errno otherwise — same convention as fuse3.nix).
@(require_results)
rename_verdict_rc :: proc(v: Rename_Verdict) -> c.int {
	switch v {
	case .Ok:
		return 0
	case .No_Replace_Exists:
		return fuse3.nix(.EEXIST)
	case .Src_Dir_Dst_File:
		return fuse3.nix(.ENOTDIR)
	case .Src_File_Dst_Dir:
		return fuse3.nix(.EISDIR)
	case .Dst_Not_Empty:
		return fuse3.nix(.ENOTEMPTY)
	case .Unsupported_Flag:
		return fuse3.nix(.EINVAL)
	}
	unreachable()
}
