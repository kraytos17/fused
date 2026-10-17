# ADR-007: Cache Ownership and Locking

Date: 2026-10-17
Status: accepted

## Context

One global `FS.mu` serializes the volume and all caches. Correctness
depends on two disciplines: exclusive holders may mutate, shared
holders must not — and cached values must be invalidated or
generation-checked before any read that could observe a mutation.

## Decision

1. **One lock, two modes.** Mutating callbacks take `FS.mu`
   exclusively (`begin_op`/`end_op`); read-only callbacks share it
   (`begin_read_op`/`end_read_op`). Disk I/O itself needs no lock
   (positional pread/pwrite). Lock pairing and the mandatory
   `context.logger` reset are enforced by audit rules (a) and (g).
2. **Caches and their owners.**
   - `path_cache` (LRU path → resolved entry): keyed by normalized
     path; cleared wholesale on mutation, single-path removal only.
   - `lfn_cache` (LRU key → name): values are owned strings;
     invalidated with the path/extent caches.
   - `extents` (map chain-head → owned run slice): slices are
     cache-owned — callers must not delete or retain them past
     invalidation. Cleared on any metadata mutation.
   - `alloc_cache` (per-cluster bitmaps + used counts, LRU):
     bitmaps derive from disk at build; `used` intentionally lags
     the bitmap by the table sector (calibrated into the Full
     heuristic).
   - `free_sectors`: recomputed via `reinit_free_sectors` after
     mutating ops, read under the shared lock by statfs.
   - `locks` / `flock_locks`: in-memory advisory state, lock-table
     guarded like any other shared map.
3. **Shared holders never mutate.** Under a read lock, only
   non-mutating access: `lru.peek` (no recency write, unlike
   `lru.get`) and snapshot/upgrade helpers (`resolve_extents_shared`,
   `lfn_lookup_shared`), which release shared, take exclusive,
   re-check, fill, and re-take shared. Never nest locks and never
   upgrade without re-checking.
4. **Borrowed slices die at invalidation.** Any routine returning a
   cache-borrowed slice documents the lifetime at its declaration;
   callers that outlive the lock must clone into the temp allocator
   first.
5. **Allocators are explicit at the boundary.** Anything stored into
   shared structures names `fsys.allocator`; nothing stored relies on
   `context` (callee-local, never propagates upward).

## Scope (explicit non-goals)

- No per-inode/cluster locking: the global lock stands until lock
  order and transaction order are testable (then a new ADR).
- No generation-based selective invalidation: conservative wholesale
  clears stay until benchmarks prove they dominate.

## Consequences

- Returning a cache-owned slice across an unlock is a use-after-free
  class bug; the audit stays syntactic, so lifetime review is manual
  at every new cache accessor.
- Clone failures are fail-closed (`.No_Space`), never empty results.

## Tests enforcing this

- Audit rules (a)/(g): lock presence + logger reset per callback.
- `tests/mounter_test.odin`: shared-resolver upgrade/fill/invalidate
  cycles; `test_extent_cache_clone_failure_no_space`.
- `make smoke-mt`: concurrent reader/writer stress.
