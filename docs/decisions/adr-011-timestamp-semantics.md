# ADR-011: Timestamp Semantics (No ctime, Coarse mtime/atime)

Date: 2026-10-17
Status: accepted

## Context

`Directory_Entry` stores two timestamps: modification time
(`year`/`date_time`) and access time (`atime_year`/`atime_date_time`),
each at one-second granularity with no timezone or sub-second fields.
There is no change-time field and no stored permission mode (see
ADR-006). The audit asked for an explicit table of when each timestamp
changes, since silent staleness (notably mtime) breaks incremental
backup, `make`-style rebuilds, and cache invalidation.

## Decision

1. **mtime advances on every successful content or allocation change.**
   `fused_write`/`fused_write_buf` bump it whenever `bytes_written >
   0` — including pure overwrites that do not grow the file (a
   same-size write that skipped the bump would hide changes from
   `make` and friends). `fused_truncate` bumps unconditionally (even
   for a same-size truncate), as does `fused_fallocate` including
   `PUNCH_HOLE` and no-growth extents, and `copy_file_range` on a
   successful copy.
2. **Zero-length writes touch nothing.** `fused_write` returns early on
   `size == 0` before any metadata handling (kernel parity: a
   zero-count `pwrite` is a no-op).
3. **Renames bump both timestamps.** `set_entry_name` refreshes mtime
   and atime (documented deviation from POSIX, which would leave
   mtime alone; there is no ctime to record the rename itself).
4. **Reads never touch atime.** `getattr`, `readdir`, and `read` leave
   both timestamps alone — effectively `noatime`. Deliberate: atime
   updates on every read would journal a metadata write per read on a
   system whose only durability story is the CE journal.
5. **Unset means epoch; anything else invalid is corruption.** An
   all-zero stamp (the synthetic mount-root entry carries no date)
   reports the Unix epoch. Any other out-of-range field fails closed
   with EIO instead of surfacing a garbage time.
6. **No ctime exists.** `st_ctim` reports the mtime value. Ownership
   and mode changes (`chmod`/`chown`) correctly leave mtime/atime
   alone; there is nowhere to record them.
6. **`utimens` is the escape hatch.** A null time argument sets both
   to now; `UTIME_NOW`/`UTIME_OMIT`/explicit values are honored per
   field, and explicit values accept any `time_t` the on-disk
   year/month/day/hour/minute/second fields can represent.

## Scope (explicit non-goals)

- No sub-second resolution, no timezones, no birth time.
- No relatime/atime knob: reads never update atime, unconditionally.
- No ctime without a format revision adding the field.

## Consequences

- Incremental tools (`make`, `rsync`, tiered caches) see every
  mutation through mtime, including overwrites and hole punches.
- Anything that needs "last status change" must approximate it with
  mtime (documented limitation).
- A future ctime field needs a format revision, golden fixtures, and
  the same per-op table updated here.

## Tests enforcing this

- `tests/mounter_test.odin:test_mount_mtime_advances_on_mutation`:
  backdates via utimens, then asserts mtime advances on same-size
  overwrite, hole punch, and no-grow fallocate (each bump
  mutation-checked by removal).
- `tests/mounter_test.odin:test_getattr_corrupt_date_fails`,
  `test_getattr_corrupt_atime_fails`: out-of-range on-disk fields
  return EIO instead of garbage (mutation-checked by removing the
  validation).
- `tests/mounter_test.odin:test_mount_getattr`: asserts the synthetic
  root (no stored dates) stats successfully with an epoch timestamp.
- `tests/test_rw.py:test_utimens`: explicit timestamps round-trip.
