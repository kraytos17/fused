# ADR-004: Free-Space Semantics

Date: 2026-10-17
Status: accepted

## Context

`statfs`, capacity planning, and the allocator need one shared meaning
of "free". The audit flagged the bitmap build for marking
`cme.sector_index` before checking CME state, and the counter for
including reserved/full clusters.

## Decision

1. **"Free" means allocatable user sectors.** `alloc_cache_count_free`
   (`src/fs/alloc_cache.odin`) counts unset bitmap bits and skips
   clusters flagged `.Reserved` or `.Full` entirely, so neither
   contributes (reserved clusters and full/invalid CMEs count as zero).
2. **statfs reports sectors, not blocks.** `fused_statfs`
   (`src/mounter/misc.odin`) sets `f_bsize = f_frsize = SECTOR_SIZE`
   (512), `f_blocks` to image sectors, and
   `f_bfree = f_bavail` to the cached free-sector count. There is no
   root-reserved distinction: `bfree == bavail` always.
3. **File counts are capacity, not survey.** `f_files`/`f_ffree`/
   `f_favail` report `cluster_map_size × dir_entries_per_buf` — the
   directory-slot capacity, not a surveyed free-inode count. Do not
   use them to detect a full filesystem; `ENOSPC` comes from the
   allocator (`No_Space`), not from these fields.
4. **The count is cached per mount.** `FS.free_sectors` is recomputed
   by `reinit_free_sectors` after mutating operations (create, dir
   mutations, xattr store/remove). Readers (`fused_statfs`) take the
   read lock and never recompute.

## Scope (explicit non-goals)

- No byte-granularity accounting: partial-sector tails are not free.
- No reserved-for-root policy and no separate `bfree`/`bavail` split.
- The CE-table sector cost inside allocated clusters follows the
  bitmap; see the allocator code, not this ADR, for per-cluster layout.

## Consequences

- `df` output matches what the allocator can actually place.
- Any new mutation path that changes allocation must call
  `reinit_free_sectors` otherwise `statfs` goes stale (audit
  candidate: a storage rule listing the call sites).

## Tests enforcing this

- `tests/free_space_test.odin`: exact counts against a slow reference
  scan, including reserved/full exclusion.
- `tests/mounter_test.odin:test_mount_statfs`: statfs geometry.
- `make doctor`: image coherence after every workload.
