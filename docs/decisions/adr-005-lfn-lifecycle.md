# ADR-005: LFN Storage Lifecycle (One Sector Per Name)

Date: 2026-10-17
Status: accepted

## Context

Long names are referenced by `LFN_Pointer` packed into
`file_name[16]`. The original design packed several names into one
bump-allocated sector, which made per-entry deallocation unsafe (freeing
one name corrupted others sharing its sector). The audit required one
of: append-only shared sectors, or independent per-name allocations.

## Decision

1. **One sector per name.** `lfn_bump_write` (`src/fs/volume.odin`)
   allocates a dedicated one-sector `.LFN` chain per name and returns
   its pointer. Entries own their name storage exclusively, so rename
   and unlink can free it independently. The bump state is retained
   but no longer accumulates multiple names per sector.
2. **Freeing follows the entry.** `free_entry_lfn`
   (`src/mounter/dir.odin`) deallocates the referenced chain on
   rename-overwrite, unlink, and rmdir paths. A zero `ptr.cluster`
   means "no long name" and is a no-op.
3. **Resolution is fail-closed.** `resolve_lfn` validates before
   touching disk bytes: non-zero cluster, readable table, allocated
   non-empty target entry, `byte offset < SECTOR_SIZE` (an out-of-range
   offset would index past the sector buffer), bounded output reserve,
   and full declared length present (a short chain is torn, not a
   truncation — returning a prefix would misidentify the file).
4. **Old packed images still read.** Resolution honors a nonzero byte
   offset within the entry's sector, so pre-change bump-packed names
   resolve; only new writes use the one-sector form.

## Scope (explicit non-goals)

- No offline LFN compaction or garbage collection (nothing shared, so
  nothing to compact).
- No name-policy enforcement at the FS layer (length caps live at the
  setxattr/create boundary; see ADR-008 for the mapping).

## Consequences

- One sector per long name (internal fragmentation for short long
  names); acceptable until directory compaction exists.
- Corrupt pointers (dangling cluster, bad offset, short chain) resolve
  to "no name" and are flagged by the checker (`LfnPtr`), never
  returned as a wrong name.

## Tests enforcing this

- `tests/lfn_ext_test.odin`, `tests/lfn_lifetime_test.odin`:
  multi-sector names, rename/unlink isolation across entries.
- `tests/check_test.odin`: corrupt LFN pointers fail closed
  (including the out-of-range offset guard).
