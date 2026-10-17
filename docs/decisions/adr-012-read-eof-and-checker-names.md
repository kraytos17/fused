# ADR-012: Read EOF Clamping and Checker Name-Scan Soundness

Date: 2026-10-17
Status: accepted

## Context

Two latent bugs surfaced together while building the first
model-based property test (200 randomized ops against an in-memory
oracle, `tests/property_test.odin`):

1. `fused_read` returned the tail sector's slack zeros as file data
   whenever a read crossed EOF inside the last sector (e.g. 10 bytes
   at offset 39 of a 40-byte file returned 10 instead of 1).
   `fused_read_buf` had the same hole, and additionally reported
   ENOENT for reads fully past the runs.
2. The checker's duplicate-name scan reported `DupName` on every
   directory with 2+ entries: the short name was derived from `&e`,
   a per-iteration stack copy of the entry at a reused address, so
   every stored name aliased stack and read back as whatever entry
   was visited last. Existing checker tests never caught it because
   no healthy-scan fixture had two entries in one directory.

## Decision

1. **Reads clamp to EOF before touching runs.** Both `fused_read`
   and `fused_read_buf` (`src/mounter/read.odin`) clamp the request
   to `file_size - off`; `off >= file_size` returns 0 immediately.
   A short count at EOF and a clean 0 past EOF are the POSIX
   contract; slack zeros are never file data, and EOF is never an
   error. `read_buf` at EOF leaves `*bufp` NULL, which libfuse
   treats as an empty read.
2. **Checker names borrow from the chain buffer, never the stack.**
   The duplicate-detection scan in `src/fs/check.odin` derives
   short names (and LFN resolution input) from `ep`, the pointer
   into the frame's chain buffer that outlives the slot loop —
   never from `&e`, the per-iteration stack copy.
3. **Property test pins both.** `tests/property_test.odin` runs a
   deterministic PRNG (fixed seed, unique names, hermetic scratch
   image) through create/write/truncate/rename/unlink/xattr with an
   in-memory model: every read is verified immediately, all files
   re-verified at the end, and the final `check_image` scan must
   report 0 errors *and* 0 warnings. Caller buffers are stack or
   heap, never temp-arena: `begin_op` resets the temp arena on
   entry, so a temp caller buffer would be clobbered by the
   callee's own allocations.

## Scope (explicit non-goals)

- No readahead/clamping changes in `read_range_from_runs` itself:
  the helper stays sector-granular; the EOF contract lives at the
  callback boundary where `file_size` is known.
- No multi-directory or LFN-heavy property workloads yet; names
  stay short and everything lives in the root. Extending the
  generator (subdirectories, long names, symlinks) is future work.

## Consequences

- Any new read path must clamp to `file_size` the same way; the
  audit's storage rules are the place to pin that if a third path
  appears.
- Any checker scan that stores entry-derived strings across loop
  iterations must borrow from a buffer that outlives the loop.
- The property test is deterministic: to explore, change
  `PROP_SEED`; the op log printed on failure replays the scenario.

## Tests enforcing this

- `tests/mounter_test.odin::test_mount_read_past_eof_is_short`:
  straddling read returns a short count with exact tail bytes,
  at/past-EOF reads return 0, `read_buf` mirrors both (NULL bufp
  at EOF). Mutation-checked: fails with the clamp reverted.
- `tests/property_test.odin::test_prop_random_ops`: 200-op model
  run with a clean final scan. Caught both bugs (slack-zero
  reads; 7 false `DupName` findings on 8 live files).
