# KNOWN_LIMITATIONS — what fused does not do yet (M-0)

Linked from README. Each item names the epic that fixes it. Updated
2026-11-18 (commits through D-17).

## Correctness scope

- **WAL covers allocation tables only (E-03).** The redo-log journals
  `Cluster_Entry` writes. Directory entries, LFN/xattr/file-data sectors,
  master seq/watermark, and `free_sectors` are not transactional. Power
  loss between a data write and its entry write can leak or expose stale
  bytes. `fsync` durability = backing-file sync only.
- **No per-record CRC (E-03).** Journal record sectors carry no checksum;
  only the header is CRC'd. Bit-rot in a record is caught only if replay
  writes garbage into a CE table (checker flags it after the fact).
- **Master rewritten per transaction.** `journal_finish` rewrites sector 0
  every commit. No backup master, no master CRC (E-02).
- **Persistent-fault rollback is best-effort.** Failure paths free what
  they allocated, but under a fault that never clears (threshold
  injection models a dead disk) the rollback's own I/O fails too and
  leaks. Single-shot injection covers the transient case: every write
  of create/mkdir/symlink is cut exactly once and each rollback
  completes clean (late_fault_test.odin), and the crash sweep cuts
  every write of every mutating op with the shell abandoned and the
  image re-opened through recovery (crash_sweep_test.odin), and real
  process death mid-op is anchored by the FUSED_DIE_AFTER_WRITES
  kill -9 knob against the live daemon (tests/fuse/test_crash.py).
  What remains of T-05 is broader live-daemon coverage of the
  enumerated cut points.
- **RENAME_EXCHANGE crash window is half-applied (E-03).** Two in-place
  slot writes are not one transaction: a cut between them leaves one
  slot exchanged and the other not, orphaning the not-yet-moved content
  (structurally sound, repairable, but not a legal POSIX outcome). The
  crash sweep pins this documented shape (crash_sweep_test.odin); full
  atomicity needs the E-03 journal transaction over entry writes.
- **Corrupt timestamps fail `stat` (E-09).** Out-of-range date fields make
  `getattr` return EIO instead of clamping + warning. `check` reports the
  finding; repair clamps it.

## POSIX gaps

Rev-9 decisions ADR-016 (inode table: links, modes, stable ino) and
ADR-017 (monotonic ino allocation, sec+nsec timestamps) close the
entries below for rev-9 images; rev-8 keeps exactly these semantics
until reformatted.

- **No hard links (E-05).** `link` → `EPERM`. Directory `nlink` is a
  constant 2, not 2 + subdirs.
- **No stable inode numbers (E-02).** `st_ino` is 0; `use_ino` off. Do not
  fabricate ino from the slot — it moves on cross-directory rename.
- **Permissions are lossy (E-01).** 3 flag bits, no mode bits, no exec
  files, `access` ignores uid/gid. Mount without `default_permissions`
  semantics; do not rely on this for isolation.
- **Timestamps are 1-second (E-02).** No nsec, `ctime == mtime`,
  `time_gran = 1e9` advertises the truth. Parent dir times never update.
- **Rename is complete for flags 0/NOREPLACE/EXCHANGE** (E-04 steps
  2–3): full errno matrix, same-name no-op, handle/lock swap on
  EXCHANGE (dir ancestor/descendant → EINVAL, matching the kernel).
  Still missing: orphan persistence for unlinked-but-open fds (E-04
  full) and whiteout (EINVAL, needs overlay support).
- **Locks never block (E-08).** `F_SETLKW` / blocking `flock` → `EAGAIN`.
- **No sparse files (E-12).** `truncate(1T)` allocates and zeroes.
  `SEEK_DATA/HOLE` over a logically-contiguous chain is cosmetic.
- **Statfs inode counters are in-memory (D-13 partial).** `f_ffree/
  f_favail` now track a live `used_entries` counter (mount walk +
  create/remove maintenance), but it is not persisted: it re-seeds from
  a walk at every mount, and `f_fsid` stays 0 until E-02 adds a UUID.
  `f_bsize = 4096`, `f_frsize = 512`.
- **Xattr/blob limits (E-10).** Whole-blob rewrite per `setxattr`,
  64 KB value cap, no ACLs, `ioctl` → `ENOTTY`, `poll` always-ready.
  One live blob chain per cluster (locate keys by cluster only), so a
  volume holds at most `cluster_map_size` live xattr sets before honest
  `ENOSPC`; rev ≤ 7 images have no xattr field at all (`EOPNOTSUPP`).

## Performance profile

- **Coarse global lock.** Most ops take `FS.mu` exclusively; `getattr`
  and `open` included. Expect serial metadata throughput (E-06).
- **Linear directories (E-07).** No name index; create storms are O(n²)
  per directory. No `readdirplus`.
- **`flush` is a no-op; `fsync` syncs the whole image.** Per-close cost
  is gone, per-fsync cost is a full file sync (E-03 group commit fixes).

## Scale and format

- **512-byte sectors only.** 4 Kn block devices unsupported (image files
  only). `cluster_size` ≤ 65536, file-handle packs `dir_cluster` in
  32 bits, cluster map is single-sector (E-12 documents exact caps).
- **Rev 7–8 only.** Older/newer refused with reformat message. No
  migrator yet (E-02 `migrate --output`).
- **Check is read-only.** No `--repair`, no fsck exit codes, no JSON
  machine output (E-09).
