# ADR-010: Performance Objectives and Benchmark Discipline

Date: 2026-10-17
Status: accepted (objectives; no gating thresholds)

## Context

Performance work must not weaken the correctness baseline. The repo
has a throughput harness but no tracked baselines, so the current need
is discipline, not optimization.

## Decision

1. **Correctness gates every optimization.** No cache-structure,
   allocator-scan, or lock-scope change lands without all gates green
   (vet, build, 158 Odin tests, pytest, strict audit, doctor, MT
   stress) plus an explicit before/after `make bench` comparison.
2. **The harness is informational, not gating.** `make bench`
   (`tests/fused_test/suites/bench.py`) measures write, read, 4K
   random read, statfs, readdir, and create-storm throughput against a
   live mount. It asserts only harness sanity (ops ran, storm cleaned
   up) — there are no tracked baselines and no pass/fail thresholds.
3. **Optimize in subsystem order when the time comes:** allocator
   scan policy first (with the slow reference scan as oracle),
   word-level bitmap scans, batched adjacent metadata writes (never
   across transaction durability boundaries), generation-based cache
   invalidation, then read/write fast paths and lock scope. One
   subsystem per change.
4. **Budgets stay explicit.** Cache capacities come from
   `Cache_Config` (defaults in `DEFAULT_CACHE_CONFIG`); total cache
   memory must stay measurable, and any new cache needs a stated
   bound plus hit/miss visibility before it is trusted.

## Scope (explicit non-goals)

- No latency SLOs, no IOPS targets, no regression thresholds in CI.
- No sparse-file, zero-copy, or lock-splitting commitments.
- Micro-optimizing `Bit_Array` or the LRU before the allocator has a
  baseline is explicitly deferred.

## Consequences

- Perf PRs without before/after numbers are rejected on process
  grounds, no matter how plausible the speedup.
- Adding thresholds later needs tracked history first, not an
  arbitrary number.

## Tests enforcing this

- `make bench` runs today; `make smoke-mt` proves concurrency safety
  is not traded for speed.
