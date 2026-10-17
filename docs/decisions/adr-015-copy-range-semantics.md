# ADR-015: copy_file_range Copies Short and Zero-Fills Gaps

Date: 2026-10-17
Status: accepted

## Context

`fused_copy_file_range` had two fail-open defects around extent
granularity, both caught by the randomized property test:

1. No source-EOF clamp: the run walker is sector-granular, so a copy
   crossing the source EOF copied slack zeros as file data and
   over-reported (copying 100 bytes from an 11-byte file returned
   100). POSIX requires a short count; reads at/past src EOF copy
   nothing.
2. No destination gap zero-fill: a copy landing past dst EOF left
   reused sectors' stale bytes visible in the gap (a poisoned sector
   read back 0xAA where zeros were required). The write and
   truncate paths already zeroed their gaps; copy did not.

A third, quieter deviation: mtime only advanced when the copy grew
the file. ADR-011 pins mtime advance on every mutating write, and
same-size overwrite copies are mutations (the d5438e9 write-path
fix established this for `fused_write`).

## Decision

1. **Clamp to src EOF before touching runs.** `size` is replaced by
   `min(size, file_size - src_off)` throughout (span computation,
   allocation, copy loop); `src_off >= file_size` copies zero bytes
   and returns 0 — never an error.
2. **Zero the dst gap `[old EOF, dst_off)`** via the shared
   `zero_file_range` after allocation, before the copy lands — the
   same ordering as the write/truncate paths.
3. **mtime advances on any successful copy** (`bytes_copied > 0`),
   mirroring `write_finish`: bump-then-persist in the same entry
   write, so the timestamp and size stay atomic.

## Scope (explicit non-goals)

- No change to same-file (intra-file) copies: the model only
  exercises distinct files; overlapping same-file ranges keep the
  existing sector-step behavior.
- Hole-punch past EOF stays unspecified (the generator only punches
  clamped in-range spans); the punch path returns whatever
  `zero_file_range` reports for an uncovered tail.

## Consequences

- Any future extent-run consumer must clamp to a known byte size
  before walking runs and must zero-fill any gap it exposes; the
  audit's storage rules are the place to pin that if a third path
  appears.
- The property generator now drives `copy_file_range`
  (cross-file, short-count oracle), `fused_write_buf` (mem-backed
  single bufvec routed through the write model), and `fallocate`
  (grow / keep-size / in-range punch) — 300 ops, 7/7 seeds green.

## Tests enforcing this

- `tests/mounter_test.odin::test_mount_copy_range_clamps_and_zeroes`:
  short count with exact content at src EOF, zero reads at src EOF,
  poisoned-sector gap zeroing, mtime advance on a same-size copy.
  Mutation-checked: all three aspects fail with the fix reverted.
- `tests/property_test.odin::test_prop_random_ops`: new copy /
  write_buf / fallocate ops verified against the model on every run.
