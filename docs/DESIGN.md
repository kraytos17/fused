# fused — Design Document

## Overview

fused is a FUSE filesystem daemon implemented in Odin. It provides a libfuse3
FFI binding, a cluster-based on-disk format (rev 7 with feature flags), and
read-write FUSE mounting (35 of 43 `fuse_operations` callbacks implemented).

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

### Packages

| Package | Purpose | Depends on |
|---|---|---|
| **`src/fuse3/`** | FFI binding to libfuse3. 43 `fuse_operations` callbacks, 12 cross-FFI structs with compile-time `#assert(size_of)`, 43 callback offsets verified against C ground truth. | `libfuse3.so` (system) |
| **`src/fs/`** | Filesystem logic operating on raw disk images. No FUSE dependency. `Volume` struct bundles disk fd, master record, and alloc cache. | `core:os` |
| **`src/mounter/`** | FUSE callbacks (35 of 43 wired) as `package mounter`. Each `fused_*` callback uses `begin_op()`/`end_op()` for locking. Translates `FS_Error` to negated errno via `fs_error_to_errno`. | `src/fs/`, `src/fuse3/` |
| **`cmd/mount/`** | Binary entry point — `package main`, calls `mounter.run()`. | `src/mounter/` |
| **`cmd/format/`** | Standalone image formatter. Produces valid disk images without libfuse3. | `src/fs/` |
| **`cmd/dump/`** | Read-only image dumper. Walks the image structure and prints it in human-readable or JSON form. | `src/fs/` |
| **`tests/`** | Odin unit tests (63), Python pytest integration (48), struct-size cross-checks, context audit. | — |

## On-disk format (rev 7)

### MasterRecord (sector 0, 512 bytes)

| Offset | Field | Type | Description |
|---|---|---|---|
| 0 | `sig` | `[7]u8` | Filesystem identifier: `"FUSED\0\0"` |
| 7 | `rev_min` | `u8` | Minimum compatible format version (6) |
| 8 | `rev_max` | `u8` | Format version written by formatter (7) |
| 9 | `features` | `Features` | `bit_set[Feature_Flag; u64]` — bit 0 = `.Uid_Gid`, bit 1 = `.Journal_V2` |
| 17–22 | reserved | — | Zero |
| 23 | `cluster_map_offset` | `u64` | Sector index of the first ClusterMapEntry (always 1) |
| 31 | `cluster_map_size` | `u64` | Number of ClusterMapEntry records |
| 39 | `cluster_size` | `u64` | Sectors per cluster (default 16, max 65536) |
| 47 | `root_sector_index` | `u16` | Sector offset within root_cluster for root directory data |
| 49 | `root_cluster` | `u64` | Cluster index of the root directory |
| 57–62 | reserved | — | Zero |
| 63 | `resv` | `[453]u8` | Zero padding; sub-fields for journal seq, watermark, region size |
| 510 | `end_sig` | `u16` | Magic sentinel: `0x0BB0` |

**Feature flags** enable runtime dispatch. `.Uid_Gid` grows `Directory_Entry`
from 48 to 56 bytes (9 entries/sector vs 10). `.Journal_V2` selects the
physical redo-log WAL over the legacy intent log. The mounter reads
`master.features` directly (it's a `bit_set` field, no transmute needed)
and selects the correct entry size at runtime via
`dir_entry_size()` / `dir_entries_per_sector()`.

### ClusterMapEntry (8 bytes, 64 per sector)

| Offset | Field | Type | Description |
|---|---|---|---|
| 0 | `sector_index` | `u16` | Sector offset within this cluster holding the ClusterEntry table |
| 2 | `flags` | `bit_set[Cluster_Map_Flag; u16]` | Allocated(b0), Reserved(b1), Full(b2) |
| 4 | `reserved` | `u32` | Zero |

### ClusterEntry (16 bytes, 32 per sector)

| Offset | Field | Type | Description |
|---|---|---|---|
| 0 | `state` | `bit_set[Cluster_Entry_Flag; u8]` | Allocated(b0), Cluster_Map(b1), Directory(b2), File_Content(b3), LFN(b4) |
| 1 | `next_sector_index` | `u16` | Sector offset of the next ClusterEntry in the chain |
| 3 | `next_cluster` | `u64` | Cluster of the next ClusterEntry (0 terminates) |
| 11 | `allocation_size` | `u16` | Number of contiguous sectors in this run |
| 13 | `sector_start` | `u16` | Sector offset within the cluster where this run begins |
| 15 | `reserved` | `u8` | Zero |

### DirectoryEntry (48–56 bytes, 9–10 per sector)

V4 format (no `Uid_Gid` feature): 48 bytes, 10 per sector.

| Offset | Field | Type | Description |
|---|---|---|---|
| 0 | `flags` | `bit_set[Dir_Flag; u16]` | Allocated/LFN/Directory/Read_Only/Link/Exists/No_Write/No_Read/No_Execute |
| 2 | `file_name` | `[16]u8` | Inline name (≤16 bytes). If LFN flag set, reinterpreted as `LFN_Pointer` |
| 18 | `sector_index` | `u16` | Sector offset of the first data ClusterEntry |
| 20 | `stored_cluster` | `u64` | Cluster containing the first data ClusterEntry |
| 28 | `year` | `u16` | Year (e.g. 2026) |
| 30 | `date_time` | `bit_field u32` | Month(4), Date(5), Hour(5), Minute(6), Second(6), Reserved(6) |
| 34 | `file_size` | `u64` | File size in bytes |
| 42 | `atime_date_time` | `bit_field u32` | atime: Month(4), Date(5), Hour(5), Minute(6), Second(6), Reserved(6) |
| 46 | `atime_year` | `u16` | atime year |

V5 format (with `Uid_Gid`): 56 bytes, 9 per sector. uid/gid inserted after `stored_cluster`, pushing subsequent fields:

| Offset | Field | Type |
|---|---|---|
| 28 | `uid` | `u32` |
| 32 | `gid` | `u32` |
| 36 | `year` | `u16` |
| 38 | `date_time` | `bit_field u32` |
| 42 | `file_size` | `u64` |
| 50 | `atime_date_time` | `bit_field u32` |
| 54 | `atime_year` | `u16` |

### LFN_Pointer (16 bytes, packed into `file_name[16]`)

Long filenames (>16 bytes) are stored in a bump-allocated data sector. The
`file_name` field is reinterpreted as an `LFN_Pointer` when the `.LFN` flag is set.

| Offset | Field | Type |
|---|---|---|
| 0 | `cluster` | `u64` |
| 8 | `size` | `u32` |
| 12 | `sector` | `u16` |
| 14 | `_pad` | `u16` — byte offset within LFN data sector |

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

Every allocated cluster reserves its first sector for a ClusterEntry table.
At `cluster_size = N`, the metadata overhead is `1/N`.

| `--cluster-size` | Overhead | Tail waste | Best for |
|---|---|---|---|
| 16 (8 KB, default) | 6.25% | ~4 KB avg | Many small files |
| 64 (32 KB) | 1.56% | ~16 KB avg | Mixed workloads |
| 128 (64 KB) | 0.78% | ~32 KB avg | Few large files |

## Architecture

### Design decisions

**Format versioning with feature flags.** On-disk format rev 6–7. `validate_master`
checks `rev_max < SUPPORTED_REV_MIN` (too old), `rev_min > SUPPORTED_REV_MAX` (too new),
and validates feature flags (no unknown bits set). `SUPPORTED_REV_MIN = 6`,
`SUPPORTED_REV_MAX = 7`. Rev 4 images can't be read by this layout (the
MasterRecord struct changed between rev 4 and 5).

**`bit_set` for flag fields.** `ClusterMapEntry.flags`, `ClusterEntry.state`,
and `DirectoryEntry.flags` use `bit_set[Enum; uN]`. The compiler enforces
correct bit positions. No magic number typos. `MasterRecord.features` is a
`Features` bit_set directly — no transmute needed at use sites.

**`distinct` types for disk addressing.** `Sector :: distinct u64`,
`Cluster :: distinct u64`, `Sector_Offset :: distinct u16`, `Journal_Seq :: distinct u64`,
`Byte_Offset :: distinct u64`. Assigning a `Cluster` to a `Sector` is a compile-time type error.

**`bit_field` for packed FFI values.** `File_Handle :: bit_field u64` packs
`dir_cluster | 32`, `dir_offset | 16`, `entry_index | 16` — no manual
shift-and-mask pack/unpack functions needed.

**Volume struct centralizes I/O.** `src/fs/` has no `(disk, master, cache)`
parameter threading. Every procedure takes `^Volume` as its first parameter,
enabling `vol->method(...)` call syntax.

**High-level FUSE API.** The binding exposes `fuse_operations` (path-based
callbacks). Low-level `fuse_lowlevel_ops` (inode-based) is deferred.

**`#assert(size_of(T) == N)` on every struct.** Cross-FFI structs in
`src/fuse3/types.odin` and on-disk structs in `src/fs/structure.odin` have
compile-time size checks. A field reordering that changes layout fails the
build.

**Thread safety.** A `sync.Mutex` on `FS` serializes cache-mutating callbacks.
Multi-threaded FUSE dispatch is the default (`-s` not forced). Read-only
callbacks (`read`, `read_buf`, `statfs`, `lseek`) run lock-free. `readdir`
releases the mutex after path resolution, before the I/O phase, to reduce
contention with concurrent writers.

**Stack-local scratch buffers.** All procedures use stack-local `[SECTOR_SIZE]u8`
arrays and fixed-capacity stack buffers (`[32]Extent_Run`) instead of
heap-backed dynamic arrays for the common case. Falls back to
`context.temp_allocator` for heavily fragmented chains.

**Zero-copy I/O.** `fused_read_buf` returns a `fuse_bufvec` with
`FUSE_BUF_IS_FD | FUSE_BUF_FD_SEEK` pointing directly to the backing file fd.
The kernel splices data from the disk fd → FUSE pipe without userspace
copying. `fused_write_buf` uses `linux.splice()` from the kernel-provided pipe
fd to the disk fd for the write side.

### In-memory caches

- **Bitmap cache** (`src/fs/alloc_cache.odin`): LRU cache (1024 entries) backed by
  `core:container/lru`. Eliminates redundant cluster-entry table reads. ~19 KB
  at default cluster size regardless of filesystem size.

- **Path-resolution cache** (`src/mounter/core.odin`): LRU cache (128 entries).
  Avoids tree walks on repeated `getattr`/`open`/`readdir` calls. Invalidated
  on all mutations.

### Error handling

`src/fs/` defines `FS_Error :: enum { None, Cluster_Not_Found, No_Space, ... }`.
Every I/O procedure returns `FS_Error` (or `(T, FS_Error)`) consistently.
Within `package fs`, `or_return`/`or_continue` propagates errors automatically.
At the FUSE boundary, `fs_error_to_errno` translates `FS_Error` to negated
errno via a `#partial switch`.

### Memory management

Functions producing variable-length results return `[dynamic]T` allocated on
`context.temp_allocator`. Callers own the allocation but don't need explicit
`delete` — the temp allocator is reset per FUSE callback via `free_all` in
`begin_op`. `cmd/mount/main.odin` wraps the mount lifecycle in a
`mem.Tracking_Allocator` guarded behind `when ODIN_DEBUG` — zero overhead in
release builds. Leaked allocations are reported at unmount time.

## FUSE callbacks (35 of 43 wired)

| Category | Callbacks |
|---|---|
| **Lifecycle** | `init`, `destroy` |
| **Metadata** | `getattr`, `access`, `statfs`, `chmod`, `chown`, `utimens`, `statx` |
| **Read** | `read`, `read_buf` (zero-copy), `readdir`, `readlink`, `lseek` (SEEK_HOLE/SEEK_DATA) |
| **Write** | `write`, `write_buf` (zero-copy), `create`, `truncate`, `fallocate`, `copy_file_range` |
| **Directory** | `mkdir`, `rmdir`, `opendir`, `releasedir`, `fsyncdir` |
| **File ops** | `open`, `release`, `flush`, `fsync`, `unlink`, `rename` |
| **Links** | `symlink`, `readlink`, `link` (returns ENOSYS) |
| **Stubs** | `mknod`, `ioctl` (return ENOSYS) |
| **Not yet** | `lock`, `flock`, `bmap`, `poll`, `setxattr`, `getxattr`, `listxattr`, `removexattr` |

## Testing

### Test suite structure

```
tests/
├── fused_test/                    Python test package
│   ├── suites/
│   │   └── stress.py              Multi-threaded stress test (reader + writer workers)
│   ├── mount.py                   FUSE mount context manager (contextlib.contextmanager)
│   ├── io.py                      Shared read(path)/write(path, data) helpers
│   └── result.py                  TestSuite/TestResult dataclasses
├── conftest.py                    Pytest fixtures: mounted_fs, fused_bin, disker_bin, imgdump_bin
├── pyproject.toml                 Pytest markers: tool, fuse
├── test_errors.py                 7 FUSE error path tests (pytest)
├── test_disker.py                 7 format tool CLI tests (pytest)
├── test_imgdump.py                10 imgdump tool tests (pytest)
├── test_basic.py                  11 FUSE smoke tests (pytest)
├── test_rw.py                     13 read-write tests (pytest)
├── ci.py                          CI orchestrator (calls make + pytest)
├── run_in_namespace.sh            Thin shell: exec unshare -rUm timeout "$@"
├── test_common.odin               Shared Odin test helpers
└── *.odin                         63 Odin unit tests (allocation, cache, directory, write,
                                    fs, validate, display, LFN, struct sizes)
```

### CI pipeline

| Phase | What it runs |
|---|---|
| 1. Build + static analysis | `make check` (struct sizes) + `make audit` (context) + `make vet` |
| 2. Unit tests | `make test` (63 Odin tests) |
| 3. Tool integration | `make pytest -m tool` (17 format + imgdump tests) |
| 4. FUSE basic | `make smoke` inside `unshare -rUm` (pytest: basic + error tests) |
| 5. FUSE rw | `make smoke-rw` inside `unshare -rUm` (pytest: read-write tests) |
| 6. FUSE stress | `make smoke-mt` inside `unshare -rUm` (stress.py) |

### Test isolation

FUSE tests run inside an isolated mount namespace (`unshare -rUm`) so that any
FUSE mount created during testing is automatically torn down when the process
exits — even if killed. The `run_in_namespace.sh` wrapper (6 lines of bash) is
the only shell script that survives; everything else is Python or Odin.

### Diagnostics

**imgdump --json** produces valid JSON even with corrupted or garbage directory
entries. Entry names with non-printable bytes are escaped as `\uXXXX`. The JSON
master record includes `rev_min`, `rev_max`, and `features` fields.

## Remaining work

8 of 43 `fuse_operations` callbacks are not yet wired:
`lock`, `flock`, `bmap`, `poll`, `setxattr`, `getxattr`, `listxattr`,
`removexattr`.
