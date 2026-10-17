# ADR-013: Truncate-to-Zero Clears the Chain Head

Date: 2026-10-17
Status: accepted

## Context

`fused_truncate` shrinking a file frees the tail via
`truncate_chain_at` and persists the smaller `file_size`, but when the
file shrank to zero it left `stored_cluster`/`sector_index` pointing
at the now-freed chain head. The next grow then walked a freed chain:
in the best case `ensure_chain_covers` failed with ENOENT (a file
that was just truncated to zero could never grow again); in the
worst case the freed sectors had meanwhile been reallocated to
another file, so the stale head aliased live foreign sectors and a
grow could expose or overwrite another file's data. The randomized
property test caught the ENOENT form (truncate 59 to 0, then
truncate 59 to 15 → ENOENT); the aliasing form is the same bug one
reallocation later.

## Decision

1. **Full free clears the head.** When `new_sectors == 0`,
   `fused_truncate` zeroes `stored_cluster`/`sector_index` before
   persisting the entry (`src/mounter/write.odin`). The entry then
   matches a never-allocated file, and the next grow takes the
   designed fresh-allocation path in `ensure_chain_covers` (which
   already handles a zero head by recording the new head in the
   entry).
2. **No crash-ordering change.** The head clear persists in the same
   entry write as the zero size, so the existing shrink discipline
   (free tail, then persist entry) is unchanged in shape: a crash
   between the free and the entry write leaves the pre-existing
   shrink window, neither widened nor narrowed.
3. **Single site.** `truncate_chain_at` has exactly one caller, and
   only a shrink to zero frees the entire chain; hole-punch and
   partial shrinks keep their heads by construction.

## Scope (explicit non-goals)

- No change to partial-shrink ordering (tail free before entry
  persist is the documented persist-first shape; the remaining
  crash window belongs to the journal, ADR-001).
- No resurrection of open-handle semantics: per ADR-003, handles
  name slots; truncate-to-zero does not move the slot, so open
  handles stay valid across it.

## Consequences

- Any future path that frees an entire chain must clear the head in
  the same entry write; a whole-chain free with a retained head is
  always a use-after-free.
- The property generator now truncates to zero regularly (shrink
  covers the full range including 0), pinning this path under churn.

## Tests enforcing this

- `tests/mounter_test.odin::test_mount_truncate_zero_then_grow`:
  write, truncate to 0, grow to 8 (zero-filled), rewrite and read
  back. Mutation-checked: fails with the head clear reverted.
- `tests/property_test.odin::test_prop_random_ops`: 300-op model run
  with subdirectories, cross-directory moves, LFN names, and readdir
  verification; caught the original ENOENT on seed 0x12345678.
