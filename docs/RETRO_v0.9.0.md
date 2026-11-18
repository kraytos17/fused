# Retrospective — v0.9.0 (M-0: Truth & baseline)

Date: 2026-11-18. Range: `30ca545` (phase 1 compat) through `d7b484f`
(CI green). Tag: `v0.9.0`.

## What M-0 set out to do (Appendix H, days 1–5, 10)

Make claims true or retract them; build the safety net's foundation;
do one honest baseline. No format changes, no new features.

## What landed

- **D-01** mkdir through the LFN path + name validation (`ENAMETOOLONG`/
  `EINVAL`, `.`/`..` → `EEXIST`) + `check_name_exists` LFN comparison +
  rollback on all failure paths + audit s13 + regression test.
- **D-03** `time_gran` 1 → 1e9 (storage is second-resolution).
- **D-05** stubs honest: `mknod` serves `S_IFREG`, `link` → `EPERM`,
  `ioctl` → `ENOTTY`, `poll` always-ready, `statx` stays `ENOSYS`.
- **D-06** leak rollback on create/symlink/mkdir/rename-persist/
  `lfn_bump_write`/`find_or_extend_dir` failure paths + early-fault and
  round-trip tests.
- **D-07** exhaustive `fs_error_to_errno` (`Cluster_Map_Full` → `ENOSPC`)
  + write/readdir/lseek site fixes.
- **D-08** `st_blocks` from extents, `st_blksize = 4096`, `st_ino` stays 0.
- **D-12** `flush` no-op, `fsync`/`fsyncdir` datasync-aware with `EIO`.
- **D-13 (partial)** `f_bsize = 4096`; inode counters documented as
  capacity until E-09.
- **D-17** journal hygiene: dead `valid`/`delete` gone, single-source
  header CRC (byte-identical), per-record CRC deferred to E-03.
- **Docs** README claims corrected (wired ops, coarse lock, 1-sector
  LFN, WAL scope), audit list `s1–s13`, `docs/KNOWN_LIMITATIONS.md`.
- **CI green** `make ci` 7/7; fixed two stale expectations found by the
  first full run (`f_bsize`, `CE[` prefix).

## What slipped (carried to M-1/M-2)

- **Late-fault enumeration** needs single-shot fault support; threshold
  faults fault the rollback too. Tracked as T-05 work.
- **Per-record CRC** is a format change; belongs to Journal v3 (E-03).
- **`df -i`** stays flat until E-09 `used_entries` accounting.
- **Parent mtime** untouched (root synthetic); needs txn (E-03) + rev 9
  `ctime` (E-02).
- **pjdfstest/fsx/bench baselines (T-01/T-02/T-10)** not yet wired —
  that is M-1's first work, starting now.

## Verification

`make ci` 7 passed 0 failed; `make doctor` coherent; 189 Odin tests;
`audit --strict`, `vet`, `check-trace` clean.
