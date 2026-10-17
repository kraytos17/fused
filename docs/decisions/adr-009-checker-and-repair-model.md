# ADR-009: Checker and Repair Model

Date: 2026-10-17
Status: accepted (Stage A+B implemented; no repair yet)

## Context

`fused-check` must distinguish integrity violations (refuse to call the
image healthy) from reclaimable leaks, without ever "repairing" the
image as a side effect of looking at it. The audit asked for a
read-only scanner, stable diagnostics, and explicit repair policy.

## Decision

1. **Read-only scan.** `check_image` (`src/fs/check.odin`) performs
   only `sector_read`. The single exception is documented, not hidden:
   `cmd/check` opens via `volume_open`, which runs journal recovery
   (replay + possible checkpoint write). A fully read-only open mode
   is future work; until then the checker never writes *except* through
   the standard mount-time recovery path.
2. **Two stages, one report.** Stage A validates the allocation
   substrate straight from disk (CME/CE flags, table bounds, data-range
   ownership with double-ownership detection, chain links mirroring
   `_chain_step`, journal/CME region bounds, free-count agreement
   against the alloc cache). Stage B walks every directory from the
   root (entry/slot validity, name resolution with duplicate detection,
   data-chain heads, xattr/LFN references, cycle and sharing detection)
   and marks all reachable chains rooted.
3. **Errors fail; orphans warn.** Integrity violations (overlap,
   dangling/bad links, cycles, bad references, out-of-range extents)
   are errors: `cmd/check` exits non-zero. Allocated-but-unreachable
   entries are `Orphan` *warnings*: they are reclaimable leaks
   (ADR-001 scope), not corruption, and crash tests legitimately leave
   them behind. Exit status depends only on errors.
4. **No repair.** The checker reports; it never mutates metadata to
   "fix" anything. Orphan reclamation and any future repair belong to a
   separate explicit mode with image backup (not implemented).
5. **Stable codes.** Every finding carries a machine-readable code
   (`DoubleOwnership`, `DirCycle`, `FreeMismatch`, …); the CLI prints
   `code + cluster/index locator + detail`. New checks add codes,
   never repurpose them.
6. **Journal is reported, not replayed.** `check_journal_report`
   lists committed slots with pending state (`seq >= watermark`,
   i.e. what recovery would replay) using the same header validation
   as the recover scan. Torn headers are skipped silently here, exactly
   as in recovery.

## Scope (explicit non-goals)

- No directory-entry content validation beyond structure/references
  (no name-policy or timestamp checks).
- No duplicate-name resolution across case or normalization: exact
  byte equality only.
- No free-space *repair*: `FreeMismatch` means the cache disagrees
  with the disk scan (stale cache or build-rule drift), not a number
  to overwrite.

## Consequences

- Seeded-corruption fixtures must keep every code covered; a rule
  without a failing test is deleted.
- Crash-test harnesses run `check` after kills: warnings are expected
  (leaked in-flight chains), errors are release blockers.
- Any future `--repair` mode needs its own ADR amendment with
  backup/copy semantics.

## Tests enforcing this

- `tests/check_test.odin`: 19 seeded-corruption tests (ownership,
  links, bounds, free agreement; reachability, orphans, journal
  report), each rule mutation-checked.
- `make doctor`: healthy image reports 0 errors, 0 warnings, exit 0.
