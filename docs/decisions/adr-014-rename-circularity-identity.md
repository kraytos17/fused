# ADR-014: Directory-Move Circularity Uses Slot Identity

Date: 2026-10-17
Status: accepted

## Context

`fused_rename` supports cross-directory moves of directories, with a
guard that must reject moves into the moved directory's own subtree
(walking the new parent chain up to the root and refusing on a match).
The guard compared each visited ancestor's **data-chain head**
(`stored_cluster`/`sector_index`) against the source's **parent
directory chain** — the wrong identity in both directions:

- Legal moves under the source's parent were rejected with EINVAL
  (the walk always reaches the parent, whose data head trivially
  matches its own chain).
- Circular moves rooted at `/` were allowed (the walk ends before
  comparing `/`, so nothing ever matched), creating a real directory
  cycle: the moved entry's subtree then contains itself.

## Decision

1. **Compare slot identities, not chain heads.** The walk compares
   each visited directory's own slot `(cluster, offset, index)` —
   what `resolve_path_cached` returns — against the source's
   `(old_cluster, old_offset, old_idx)`. The walk fires if and only
   if it reaches the source directory itself.
2. **Fail-closed contract.** A move into the source's own subtree
   (including into itself) returns EINVAL with the tree untouched;
   a same-parent no-op rename onto the existing directory keeps the
   existing EISDIR behavior. The property model pins both, plus
   getattr-still-resolves after each rejection.
3. **Single site.** Only `fused_rename` moves directories; the
   same-dir fast path returns before the walk, so the check runs
   exclusively for cross-directory directory moves.

## Scope (explicit non-goals)

- No POSIX rename-onto-self no-op success: renaming a directory onto
  its own existing name keeps EISDIR (rename-overwrite applies to
  non-directories only).
- No change to the `/`-terminated walk: the root can never be the
  move source through a real entry, so skipping it is sound.

## Consequences

- Any future directory-relocation path must reuse the slot-identity
  comparison; data-chain heads identify directory *contents*, never
  the entry, and must not stand in for entry identity.
- The property generator now nests directories (depth-capped) and
  moves them with a circularity oracle; a regression that re-allows
  cycles fails loudly (EINVAL expected, plus the final scan flags
  any DirCycle the move would create).

## Tests enforcing this

- `tests/property_test.odin::test_prop_random_ops` (+`_b`/`_c` seed variants): 300-op model run
  with nested mkdir, directory moves (legal, circular, same-parent
  no-op) verified by return code and resolution checks.
  Mutation-checked: the old head comparison fails the run (a
  circular move succeeds where EINVAL is required).
