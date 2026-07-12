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
- **`src/mounter/`** — FUSE callbacks that delegate to `src/fs/`. Translates
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
| 7 | `rev` | `u8` | Format version (currently 2) |
| 8–14 | reserved | — | Zero |
| 15 | `cluster_map_offset` | `u64` | Sector index of the first ClusterMapEntry (always 1) |
| 23 | `cluster_map_size` | `u64` | Number of ClusterMapEntry records |
| 31 | `cluster_size` | `u64` | Sectors per cluster (default 16, max 65536) |
| 39 | `root_sector_index` | `u16` | Sector offset within root_cluster for root directory data |
| 41 | `root_cluster` | `u64` | Cluster index of the root directory |
| 49–54 | reserved | — | Zero |
| 55 | `resv` | `[455]u8` | Zero padding |
| 510 | `end_sig` | `u16` | Magic sentinel: `0x0BB0` |

### ClusterMapEntry (16 bytes packed, 32 per sector)

Each entry tracks one cluster. Indexed by cluster number.

| Offset | Field | Type | Description |
|---|---|---|---|
| 0 | `sector_index` | `u16` | Sector offset within stored_cluster for this cluster's ClusterEntry table |
| 2 | `stored_cluster` | `u64` | Cluster index containing the ClusterEntry table |
| 10 | `flags` | `bit_set[Cluster_Map_Flag; u16]` | Allocated(b0), Reserved(b1), Full(b2) |
| 12 | `reserved` | `u32` | Zero |

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
| 42–47 | reserved | — | Zero |

### LFN_Pointer (16 bytes, packed into file_name[16])

| Offset | Field | Type |
|---|---|---|
| 0 | `cluster` | `u64` |
| 8 | `size` | `u32` |
| 12 | `sector` | `u16` |
| 14 | `_pad` | `u16` |

### Two-level indirection

```
MasterRecord (sector 0)
  │
  └─▶ ClusterMapEntry array (sector 1+)
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

**Format versioning.** On-disk format version 2. `validate_master` checks the
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

**Stack-local scratch buffers.** All procedures use stack-local `[32]T` arrays
instead of file-scope globals. Trivially reentrant, zero runtime allocation.

### Memory management

Functions producing variable-length results (`read_directory_entries`,
`resolve_extents`) return `[dynamic]T`. Callers own the allocation.

Functions accepting allocators take an `allocator := context.allocator`
parameter. Callers pass `context.temp_allocator` for short-lived results.

`src/mounter/main.odin` wraps the mount lifecycle in a
`mem.Tracking_Allocator` in debug builds. Leaked allocations from FUSE
callbacks are reported at unmount time.

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
| FS core integration | Open golden image, walk FS tree, byte-for-byte content assert |
| Context safety | Audit every `proc "c"` for context + logger restoration |
| Allocator | Property tests: fresh alloc, no-overlap, free-reuse, chain consistency |
| Write path | Direct allocator I/O tests without FUSE (allocate → write → read → verify) |
