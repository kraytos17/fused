# fused — Design Document

## Overview

fused is a FUSE filesystem daemon implemented in Odin. It provides a libfuse3
FFI binding, a cluster-based on-disk format, and read-write FUSE mounting.

The project is split into two independent halves that meet at `src/mounter/`:

```
┌─────────────┐     ┌──────────────────┐     ┌──────────────┐
│  libfuse3.so│────▶│  src/fuse3/      │────▶│ src/mounter/ │
│  (system)   │     │  FFI binding     │     │ FUSE glue    │
└─────────────┘     └──────────────────┘     └──────┬───────┘
                                                    │
┌─────────────┐     ┌──────────────────┐            │
│  fused.img  │────▶│  src/fs/         │────────────┘
│  (raw disk) │     │  filesystem core │
└─────────────┘     └──────────────────┘
```

- **`src/fuse3/`** — FFI binding to libfuse3. 39 `fuse_operations` callbacks,
  12 cross-FFI structs with compile-time `#assert(size_of)`, 43 callback offsets
  verified against C ground truth.
- **`src/fs/`** — Filesystem logic operating on raw disk images through
  `sector_read`/`sector_write`. No FUSE dependency.
  - `alloc_cache.odin` — in-memory bitmap cache for the sector allocator
  - `validate.odin` — Mount-time MasterRecord validation
  - `display.odin` — Human-readable flag/struct string formatters
- **`src/mounter/`** — FUSE callbacks (21 implemented) that delegate to `src/fs/`. Translates
  `FS_Error` to negated errno values.
- **`src/disker/`** — Standalone image formatter. Produces valid disk images
  without libfuse3.
- **`tools/imgdump/`** — Read-only image dumper. Walks the image structure and
  prints it in human-readable form.

## On-disk format

### MasterRecord (sector 0, 512 bytes packed)

| Offset | Field | Type | Description |
|---|---|---|---|
| 0 | `sig` | `[7]u8` | Filesystem identifier: `"FUSED\0\0"` |
| 7 | `rev` | `u8` | Format version (currently 4) |
| 8–14 | reserved | — | Zero |
| 15 | `cluster_map_offset` | `u64` | Sector index of the first ClusterMapEntry (always 1) |
| 23 | `cluster_map_size` | `u64` | Number of ClusterMapEntry records |
| 31 | `cluster_size` | `u64` | Sectors per cluster (default 16, max 65536) |
| 39 | `root_sector_index` | `u16` | Sector offset within root_cluster for root directory data |
| 41 | `root_cluster` | `u64` | Cluster index of the root directory |
| 49–54 | reserved | — | Zero |
| 55 | `resv` | `[455]u8` | Zero padding |
| 510 | `end_sig` | `u16` | Magic sentinel: `0x0BB0` |

### ClusterMapEntry (8 bytes packed, 64 per sector)

Each entry tracks one cluster. Indexed by cluster number.

| Offset | Field | Type | Description |
|---|---|---|---|
| 0 | `sector_index` | `u16` | Sector offset within this cluster holding the ClusterEntry table |
| 2 | `flags` | `bit_set[Cluster_Map_Flag; u16]` | Allocated(b0), Reserved(b1), Full(b2) |
| 4 | `reserved` | `u32` | Zero |

### ClusterEntry (16 bytes packed, 32 per sector)

Describes a contiguous allocation run within a cluster. Runs are chained via
`next_cluster`/`next_sector_index`.

| Offset | Field | Type | Description |
|---|---|---|---|
| 0 | `state` | `bit_set[Cluster_Entry_Flag; u8]` | Allocated(b0), Cluster_Map(b1), Directory(b2), File_Content(b3), LFN(b4) |
| 1 | `next_sector_index` | `u16` | Sector offset of the next ClusterEntry in the chain |
| 3 | `next_cluster` | `u64` | Cluster of the next ClusterEntry (0 terminates) |
| 11 | `allocation_size` | `u16` | Number of contiguous sectors in this run |
| 13 | `sector_start` | `u16` | Sector offset within the cluster where this run begins |
| 15 | `reserved` | `u8` | Zero |

### DirectoryEntry (48 bytes packed, 10 per sector)

| Offset | Field | Type | Description |
|---|---|---|---|
| 0 | `flags` | `bit_set[Dir_Flag; u16]` | Allocated(b0), LFN(b1), Directory(b2), Read_Only(b3), Link(b4), Exists(b5), No_Write(b6), No_Read(b7), No_Execute(b8) |
| 2 | `file_name` | `[16]u8` | Inline name (≤16 bytes, null-terminated). If LFN flag is set, reinterpreted as LFN_Pointer |
| 18 | `sector_index` | `u16` | Sector offset of the first data ClusterEntry |
| 20 | `stored_cluster` | `u64` | Cluster containing the first data ClusterEntry |
| 28 | `year` | `u16` | Year (e.g. 2026) |
| 30 | `date_time` | `bit_field u32` | Month(4), Date(5), Hour(5), Minute(6), Second(6), Reserved(6) |
| 34 | `file_size` | `u64` | File size in bytes |
| 42 | `atime_date_time` | `bit_field u32` | atime: Month(4), Date(5), Hour(5), Minute(6), Second(6), Reserved(6) |
| 46 | `atime_year` | `u16` | atime year (e.g. 2026) |

### LFN_Pointer (16 bytes, packed into file_name[16])

Long filenames (>16 bytes) are stored packed sequentially within an LFN sector
via a bump allocator (up to ~25 names per sector instead of one). The `_pad`
field stores the byte offset within the data sector; old-format images have
`_pad = 0` and are read correctly (backward compatible).

| Offset | Field | Type |
|---|---|---|
| 0 | `cluster` | `u64` |
| 8 | `size` | `u32` |
| 12 | `sector` | `u16` |
| 14 | `_pad` | `u16` — byte offset within LFN data sector (0 for legacy) |

### Two-level indirection

```
MasterRecord (sector 0)
  │
  └─▶ ClusterMapEntry array (sector 1+, 64 entries/sector)
       │
       └─▶ ClusterEntry table for cluster N
            (one sector, 32 entries)
             │
             ├─ entry[0] → run of contiguous sectors
             │   └─ next_cluster → entry in another cluster's table
             │
             └─ entry[1] → another run
```

File read path:
1. Locate the DirectoryEntry via `read_directory_entries`
2. Resolve `(stored_cluster, sector_index)` via `find_cluster_entry`
3. Walk the `next_cluster`/`next_sector_index` chain via `resolve_extents`
4. Read the resulting `[]Extent_Run{ sector, count }` with `sector_read`

### Cluster size tuning

Every allocated cluster reserves its first sector for a `ClusterEntry` table.
At `cluster_size = N`, the metadata overhead is `1/N`. The
`disker --cluster-size=N` flag controls this trade-off:

| `--cluster-size` | Metadata overhead | Internal fragmentation | Best for |
|---|---|---|---|
| 16 (8 KB, default) | 6.25% | ~4 KB average tail waste per file | Many small files |
| 64 (32 KB) | 1.56% | ~16 KB average tail waste per file | Mixed workloads |
| 128 (64 KB) | 0.78% | ~32 KB average tail waste per file | Few large files |

## Architecture

### Package dependencies

```
src/disker ──▶ src/fs ──▶ core:os
                  ▲
tools/imgdump ────┘

src/mounter ──▶ src/fs ──▶ core:os
     │
     └──────▶ src/fuse3 ──▶ libfuse3.so (system)
```

### Design decisions

**Format versioning.** On-disk format version 4. `validate_master` checks the
revision field and rejects images with an incompatible version.

**`bit_set` for flag fields.** `ClusterMapEntry.flags`, `ClusterEntry.state`,
and `DirectoryEntry.flags` use `bit_set[Enum; uN]`. The compiler enforces
correct bit positions. No magic number typos.

**`distinct` types for disk addressing.** `Sector :: distinct u64`,
`Cluster :: distinct u64`, `Sector_Offset :: distinct u16`. Assigning a
`Cluster` to a `Sector` is a compile-time type error.

**High-level FUSE API.** The binding exposes `fuse_operations` (path-based
callbacks). Low-level `fuse_lowlevel_ops` (inode-based) is deferred.

**`#assert(size_of(T) == N)` on every struct.** Cross-FFI structs in
`src/fuse3/types.odin` and on-disk structs in `src/fs/structure.odin` have
compile-time size checks. A field reordering that changes layout fails the
build.

**Explicit state via FS struct.** All mount state (disk handle, master record,
bitmap cache, path cache, logger) lives in a single `FS` struct allocated in
`main.odin` and threaded through callbacks via `fuse_get_context().private_data`.
No package-level globals: the `fs` package is fully stateless, and the mounter
owns exactly one mutable `FS` instance per mount. This eliminates a class of
concurrency races and makes the test surface explicit — every `fs` function
takes its dependencies as parameters.

**Thread safety.** The `FS` struct carries a `sync.Mutex` field. Cache-mutating
FUSE callbacks (getattr, readdir, open, write, create, mkdir, unlink, rmdir,
truncate, utimens, rename, access) acquire the mutex at the top of the callback
and release it on return via `defer`. Read-only callbacks (read, statfs) and
no-op callbacks (flush, release, opendir, releasedir, fsync) run lock-free.
The `-s` (single-threaded) flag is available but not forced — multi-threaded
dispatch is the default.

**Stack-local scratch buffers.** All procedures use stack-local `[32]T` arrays
and fixed-capacity inline arrays (`[dynamic; 32]Extent_Run`) instead of
heap-backed dynamic arrays. Trivially reentrant, zero runtime allocation in the
common case. `read_directory_entries` uses a plain `[dynamic]Directory_Entry`
(no explicit capacity) to allow growth beyond the initial 10-entry sector.

**In-memory caches.** The mounter maintains two caches:

- A per-cluster bitmap cache (`src/fs/alloc_cache.odin`) backed by
  `core:container/lru` with a fixed capacity of 1024 entries, eliminating
  redundant cluster-entry table reads from the allocator hot path. Memory
  consumption is bounded (~19 KB at default cluster size) regardless of
  filesystem size — no per-cluster `cluster_map_size`-scaled arrays.
  Each entry holds a stack-allocated sector bitmap and a cached used-sector
  count computed during bitmap build, eliminating a redundant table read on
  every allocation scan.

- An LRU path-resolution cache (`core:container/lru` in `src/mounter/ops.odin`,
  capacity 128) that avoids tree walks on repeated `getattr`/`open`/`readdir`
  calls. Invalidation calls `lru.clear` — no heap allocation, no prefix scan.

Both are invalidated on mutations (allocations, creates, unlinks, renames)
and transparent to callers.

### Memory management

Functions producing variable-length results (`read_directory_entries`,
`resolve_extents`) return `[dynamic]T`. Callers own the allocation.

Functions accepting allocators take an `allocator := context.allocator`
parameter. Callers pass `context.temp_allocator` for short-lived results.

`src/mounter/main.odin` wraps the mount lifecycle in a
`mem.Tracking_Allocator` guarded behind `when ODIN_DEBUG`
(compile-time — zero overhead in release builds). Leaked allocations from FUSE
callbacks are reported at unmount time in debug builds.

FUSE callbacks use stack-local buffers (e.g. `[fs.SECTOR_SIZE]u8`) for scratch
space. Long-lived allocations are explicitly freed with `defer`.

### Error handling

`src/fs/` defines `FS_Error :: enum { None, Cluster_Not_Found, No_Space, ... }`.
Public procedures return either `(T, bool)` or `(T, FS_Error)`. At the FUSE
boundary, `FS_Error` is translated to negated errno via `fuse3.nix(.ENOENT)`.

## Testing

| Layer | Approach |
|---|---|
| FFI struct layout | Compile-time `#assert(size_of)` + C cross-check |
| On-disk struct layout | Compile-time `#assert(size_of)` |
| FUSE binding | mount + ls + cat + stat + write + unmount |
| Read-write FUSE | create, write, append, cp, dd, mkdir, unlink, rmdir, remount, df/statvfs |
| FS core integration | Open golden image, walk FS tree, byte-for-byte content assert |
| Context safety | Audit every `proc "c"` for context + logger restoration |
| Allocator | Fresh alloc, no-overlap, free-reuse, chain consistency, multi-cluster chain, extension |
| Write path | Allocate → write → read → verify, grow-shrink cycle, extend from non-zero |
| Bitmap cache | Init/destroy, bitmap matches disk, used count matches disk, invalidation rebuilds, count free, alloc with cache, hint advance, multi-cluster stress, chain extension, many small cycles |
| Directory entries | Create, delete, recreate, timestamp persistence, growth beyond 10 entries |
| Directory extents | Many entries across sectors, free-slot reuse in extended sector, cross-directory rename to extended target |
| Rename | Overwrite simulation (free old entries, update parent) |
| Image cache | Shared `/dev/shm` image with mtime + format-version cache invalidation |
| Disk er tool | 8 integration tests (size, cluster-size, output, help, force-guard, size validation, imgdump readability) |
| Imgdump tool | 12 integration tests (master, clusters, Kernel, JSON validation, hex dump, hex-on-dir error, help, missing/invalid path) |
| FUSE smoke | Isolated mount namespace via `unshare -rUm`, harness with timeout |
| CI pipeline | Build + struct check + context audit + vet + unit tests + tool integration + smoke + smoke-rw + smoke-mt (9 phases) |

### Test count

- 47 unit tests in `tests/`
- 8 disker integration tests + 12 imgdump integration tests in `tests/disker_test.sh`
- 14-check FUSE smoke test in `tests/smoke.sh` (read-only, multi-sector, subdir, df/statvfs)
- 25-step read-write FUSE smoke test in `tests/smoke_rw.sh` (create, write, append, cp, dd, mkdir, unlink, rmdir, remount, persistence, statvfs)
- Multi-threaded stress test in `tests/smoke_mt.sh` (concurrent reader/writer/dir/io workers, 15s)
- Struct size cross-check: 12 structs, 43 callback offsets
- Context audit: 21 callbacks checked
- CI pipeline: 9 phases — build, struct check, context audit, vet, unit tests, tool integration, smoke, smoke-rw, smoke-mt
