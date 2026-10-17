# ADR-001: Journal Transaction Contract (CE-metadata WAL)

Date: 2026-10-17
Status: accepted (implementation in stages; §4.1 closes it)
Context: audit §4.1–§4.4; commits db51ea7 (slots/replay/chunking)

## Context

Allocation and deallocation mutate home Cluster-Entry tables while
journaling. Historically the home writes landed *before* the journal
commit (`allocate_sectors`/`deallocate_sectors` wrote CE tables during
the scan, committed the `Journal_Txn` after). For process crashes
(`kill -9`, page cache survives) that degrades to leaks; for power loss
(unordered page-cache eviction) a surviving subset of home writes with
a discarded (uncommitted) log — or a lost home subset under an advanced
watermark — can double-own sectors or walk into stale links.

## Decision

1. **Log before home, per bounded chunk.** Each chunk: build the full
   CE-write plan in memory → persist journal records + commit header +
   `sync` → apply home writes → `sync` → advance checkpoint.
2. **Plan-first collection.** Scans collect `(cluster, table-index,
   new-entry)` writes without touching home (fresh-cluster init stays
   eager: marking a fresh cluster Allocated + zeroing its table is
   idempotent and benign with or without a following commit).
3. **Chunking preserved** (`MAX_JOURNAL_ENTRIES` per commit). Mid-scan
   flush keeps memory bounded; same-slot repeats collapse to the final
   value inside a chunk (e.g. a link patch supersedes the initial
   write); across chunks each chunk is independently replayable.
4. **Sequence always advances; watermark only on applied success.**
   Commit failure → abort, home untouched, error out. Apply failure →
   checkpoint holds (slot preserved for replay, which completes the
   home writes), error out. Recovery therefore never skips a committed
   transaction and never replays past an incomplete one (db51ea7).
5. **CME flags are derived, not journaled.** `Allocated`/`Full` and the
   table sector follow from the CE tables; recovery reconciles them
   rather than replaying them (the `Journal_Entry` format is frozen —
   no on-disk change). `used` intentionally lags the bitmap by the
   shared table sector (see `alloc_cache.odin`); the Full heuristic is
   calibrated for that lag.
6. **Sync policy.** `sync` after journal records, after the commit
   header, and after home-apply — in that order. The checkpoint write
   itself is unsynced: home is already durable when it persists, and a
   lost checkpoint only causes (idempotent) re-replay. What must never
   happen is the watermark overtaking undurable home tables.
7. **Recovery I/O failure policy (2026-10-17 amendment).** A
   journal-region header that cannot be *read* is a disk failure, not
   an empty slot: `journal_recover` returns the error and
   `volume_open` refuses the mount — the committed set is unknowable,
   so scanning past is unsound. A failed checkpoint write likewise
   errors out. A held watermark (incomplete/torn slot, unreadable
   replay target) is routine and returns `.None`: the slot is
   preserved and the next mount converges from the log.

## Scope (explicit non-goals)

- The WAL covers **CE-table writes only** (allocation metadata), as
  before. Directory entries, xattr pointers/blobs, file data, and the
  file-size publication step are NOT journaled; a crash between data
  write and size publication, or mid-rename, can still leak (never
  silently corrupt via the paths hardened since).
- No orphan reclamation: unreachable-but-allocated chains after a crash
  are leaks for the checker (Phase 6 scrub), not silent reuse.
- No format change: `Journal_Entry`/`Journal_Record`/`Journal_Header`
  layouts, slot stride, and rev range are untouched.

## Consequences

- More I/O per mutating op (journal + home + syncs). Every stage lands
  only with a before/after `make bench` comparison and zero
  correctness-test regression.
- `Journal_Backend.commit` persists records only; a new `finish`
  advances seq/watermark. Callers never split the pair except through
  the shared chunk-flush helper.
- Crash behavior per op becomes: committed chunk = applied-or-replayed;
  uncommitted chunk = home untouched (nothing to repair).

## Tests enforcing this

- `tests/journal_txn_test.odin`: slot non-overlap, replay stops at
  first incomplete, chunked large allocations.
- `tests/test_crash.py` (kill -9 matrix): extend to power-loss-ordering
  simulation (reordered home-apply) once plan-first lands.
- Torn-log fixtures: torn header/record, bad CRC/counts, short home
  apply followed by recover must converge to the logged state.
- `tests/fault_test.odin`: scan-header read failure returns the error
  with the watermark unmoved; replay-abort paths return the failed
  checkpoint write while the in-memory hold stands.
- `make bench` before/after each stage.
