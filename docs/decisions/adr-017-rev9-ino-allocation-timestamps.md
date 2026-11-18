# ADR-017: Inode Number Allocation and Timestamp Precision

Date: 2026-11-18
Status: accepted (design; implementation pending E-02, builds on ADR-016)

## Context

With the rev-9 inode table (ADR-016), two questions remain about what
the table's identity and time fields actually are:

1. **How are inode numbers allocated?** The table gives every inode a
   persistent number; the allocator must be crash-safe and must not
   resurrect a freed inode under a live name.
2. **What precision do timestamps get?** Rev 8 stores packed 1-second
   date fields (year + packed date/time; atime added later), which
   forces `ctime == mtime`, `time_gran = 1e9`, and — the D-06 finding
   — an EIO on stat when a stored field is corrupt (E-09) rather than
   a clamped value.

## Decision

1. **Monotonic bump, never reused.** `Master_Record.next_ino` is a
   u64; allocation is `next_ino += 1` under the write lock, assigned
   to the freshly created table record. Numbers are never reused —
   a freed inode's number is retired forever.
2. **The master copy is advisory; the table is the truth.**
   `journal_finish` already rewrites the master per transaction, so
   `next_ino` rides along. Recovery re-derives it:
   `next_ino = max(next_ino, max_table_ino + 1)` — a crash that lost
   the master rewrite costs at most a gap in the number space, never
   a collision, because the table holds every allocated ino. No
   bitmap, no free list, nothing else to persist.
3. **u64 exhaustion is not a case.** A 100k-inodes-per-second image
   runs for ~5.8 million years.
4. **Timestamps move to the table as real fields**: `mtime`, `atime`,
   `ctime` each `{unix_sec: u64, nsec: u32}`. `time_gran` drops from
   1e9 to 1. The packed year/date/time entry fields are gone on rev-9
   images (the entry carries no time fields at all).
5. **ctime is real.** chmod, chown, link, truncate, and write paths
   bump `ctime`; `getattr`/`statx` report it directly.
6. **Corrupt timestamps can no longer fail `stat` (closes the E-09
   gap for rev-9 images).** The validation layer is `sec` being a
   plausible unix second; repair clamps out-of-range values instead of
   rejecting the read. Rev-8 images keep the packed fields and their
   current behavior.
7. **Parent-directory mtime/ctime on child changes remains coupled to
   E-03's transaction support** — unchanged limitation, now the last
   timestamp gap.

## Consequences

- `st_ino` is dense-ish but unbounded — fine for `df -i`, which counts
  the table occupancy, not the number space.
- Recovery gains one cheap idempotent pass over the table (max ino) —
  the same walk Stage B needs anyway.
- The goldens pin the master layout change (one-byte master changes
  already fail the format-twice determinism check).

## Alternatives rejected

- **Free-list/bitmap reuse** — bounded, extra journaling, and nothing
  requires reuse; gaps are free.
- **Slot-derived identity** — rejected since ADR-003: the slot moves
  on cross-directory rename, which is the property stable inos exist
  to fix.
- **Keep 1-second packed times in the table** — the table is new
  space; carrying the old shape forward to save 12 bytes per record
  would bake the E-09 and nsec gaps into the new format forever.
