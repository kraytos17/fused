# fused — Design Document

## Overview

fused is a FUSE filesystem daemon implemented in Odin. It provides a libfuse3
FFI binding, a cluster-based on-disk format (rev 8 with feature flags), and
read-write FUSE mounting (all 43 `fuse_operations` callbacks implemented).

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
| **`src/fs/`** | Filesystem logic operating on raw disk images. No FUSE dependency. `Volume` struct bundles disk fd, master record, and alloc cache. `format_image` owns image construction (shared by the format tool and tests). | `core:os` |
| **`src/mounter/`** | FUSE callbacks as `package mounter`. Mutating callbacks use `begin_op()`/`end_op()` for exclusive locking, read-only ones `begin_read_op()`/`end_read_op()` for shared locking. Translates `FS_Error` to negated errno via `fs_error_to_errno`. | `src/fs/`, `src/fuse3/` |
| **`cmd/mount/`** | Binary entry point — `package main`, calls `mounter.run()`. | `src/mounter/` |
| **`cmd/format/`** | Standalone image formatter. Produces valid disk images without libfuse3. | `src/fs/` |
| **`cmd/dump/`** | Read-only image dumper. Walks the image structure and prints it in human-readable or JSON form. | `src/fs/` |
| **`tests/`** | Odin unit tests (174), Python pytest integration (63), struct-size cross-checks, callback context/locking/logger/hygiene/attribute audits. | — |

## On-disk format (rev 8)

### MasterRecord (sector 0, 512 bytes)

| Offset | Field | Type | Description |
|---|---|---|---|
| 0 | `sig` | `[7]u8` | Filesystem identifier: `"FUSED\0\0"` |
| 7 | `rev_min` | `u8` | Minimum compatible format version declared by the image (8 as written; 7 minimum mountable) |
| 8 | `rev_max` | `u8` | Format version written by formatter (8) |
| 9 | `features` | `Features` | `bit_set[Feature_Flag; u64]` — bit 0 = `.Uid_Gid`, bit 1 = retired (rev-7 journal selector, rejected), bit 2 = `.XAttr` |
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
from 48 to 56 bytes (9 entries/sector vs 10). `.XAttr` grows it further to
64 bytes (8 entries/sector) and adds the `xattr_cluster` field. Bit 1 is
retired: it selected the rev-7 journal WAL when two journals existed, and
images carrying it are now rejected by validation (reformat to migrate). The mounter
reads `master.features` directly (it's a `bit_set` field, no transmute needed)
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
| 0 | `state` | `bit_set[Cluster_Entry_Flag; u8]` | Allocated(b0), Cluster_Map(b1), Directory(b2), File_Content(b3), LFN(b4), XAttr(b5) |
| 1 | `next_sector_index` | `u16` | Sector offset of the next ClusterEntry in the chain |
| 3 | `next_cluster` | `u64` | Cluster of the next ClusterEntry (0 terminates) |
| 11 | `allocation_size` | `u16` | Number of contiguous sectors in this run |
| 13 | `sector_start` | `u16` | Sector offset within the cluster where this run begins |
| 15 | `reserved` | `u8` | Zero |

### DirectoryEntry (48–64 bytes, 8–10 per sector)

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

V6 format (with `XAttr`): 64 bytes, 8 per sector. `xattr_cluster` appended after `atime_year`:

| Offset | Field | Type | Description |
|---|---|---|---|
| 56 | `xattr_cluster` | `u64` | Cluster containing the xattr blob chain (0 = none) |

### Extended attributes (rev 8)

Xattrs are packed into a self-describing blob stored in a dedicated `.XAttr`
cluster chain referenced by `Directory_Entry.xattr_cluster`. The chain head is
located by scanning the owning cluster's CE table for an entry whose state
carries `.XAttr` (mirrors LFN pointer resolution).

```
XAttr_Blob_Header (12 bytes)
  magic: u32 = "XATR" | count: u16 | _pad: u16 | total: u32
XAttr_Record_Header (6 bytes) × count
  name_len: u16 | value_len: u32
  followed by: name bytes, then value bytes
```

Limits follow Linux: name ≤ 255 (`XATTR_NAME_MAX`), value ≤ 65536
(`XATTR_SIZE_MAX`). Allocation and deallocation of xattr chains go through
the journal (WAL on rev-8 images).

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

**Format versioning with feature flags.** On-disk format rev 7–8. `validate_master`
checks `rev_max < SUPPORTED_REV_MIN` (too old), `rev_min > SUPPORTED_REV_MAX` (too new),
and validates feature flags (no unknown bits set, compared on the u64
representation so retired bits stay visible). `SUPPORTED_REV_MIN = 7`,
`SUPPORTED_REV_MAX = 8`. Rev 4 images can't be read by this layout (the
MasterRecord struct changed between rev 4 and 5); rev 6 images are rejected
as too old since the intent log was removed.

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

**Thread safety.** `FS.mu` is a `sync.RW_Mutex`. Callbacks that mutate shared
state (caches, lock tables, free count) take it exclusively via
`begin_op()`/`end_op()`; read-only callbacks share it via
`begin_read_op()`/`end_read_op()`. Multi-threaded FUSE dispatch is the
default (`-s` not forced). While shared-held, paths must use only
non-mutating cache access: `lru.peek` (unlike `lru.get`, it doesn't rewrite
recency) and the snapshot/upgrade helpers `resolve_extents_shared` /
`lfn_lookup_shared`, which clone results into the temp allocator so they
outlive the lock. `fused_read`/`fused_read_buf` resolve through the shared
helper; `readdir` resolves the path under the write lock, then re-takes the
read lock per entry and fills the kernel buffer unlocked; `fused_release`
takes the write lock (it mutates the lock tables); `statfs` takes the read
lock. Disk I/O itself needs no lock (pread/pwrite).

**Logger discipline.** `context` passes by value, so the
`context.logger = fsys.logger` assignment inside `begin_op()` /
`begin_read_op()` is callee-local and never reaches the caller: every
callback repeats the assignment itself after acquiring the lock, or its
`debugf` output goes nowhere (enforced by audit rule (g)). Callbacks
that bypass the lock helpers (`get_fs` + manual locking) set it the
same way.

**Stack-local scratch buffers.** All procedures use stack-local `[SECTOR_SIZE]u8`
arrays and fixed-capacity stack buffers (`[32]Extent_Run`) instead of
heap-backed dynamic arrays for the common case. Falls back to
`context.temp_allocator` for heavily fragmented chains.

**Zero-copy I/O.** `fused_read_buf` returns a `fuse_bufvec` with
`FUSE_BUF_IS_FD | FUSE_BUF_FD_SEEK` pointing directly to the backing file fd.
The kernel splices data from the disk fd → FUSE pipe without userspace
copying. `fused_write_buf` uses `linux.splice()` from the kernel-provided pipe
fd to the disk fd for the write side.

### Decision records

Binding contracts live in [`docs/decisions/`](decisions/):

- [ADR-001](decisions/adr-001-journal-transaction-contract.md): journal
  transaction contract (log-before-home, checkpoint rules, recovery
  failure policy).
- [ADR-004](decisions/adr-004-free-space-semantics.md): free means
  allocatable sectors (Reserved/Full excluded); statfs reports sectors
  with `bfree == bavail`; file counts are capacity, not survey.
- [ADR-006](decisions/adr-006-permission-model.md): constrained
  coarse-flag permissions (no stored mode matrix; ownership recorded
  but not enforced).
- [ADR-008](decisions/adr-008-error-mapping.md): central
  `FS_Error → errno` mapping (default EIO); absence vs. corruption
  discipline.
- [ADR-009](decisions/adr-009-checker-and-repair-model.md): read-only
  checker (errors fail, orphans warn); no repair; journal is reported,
  not replayed.
- [ADR-003](decisions/adr-003-file-identity.md): handles name
  directory slots (no stable nodes, no hard links, no POSIX
  open-unlink).
- [ADR-005](decisions/adr-005-lfn-lifecycle.md): one sector per long
  name; fail-closed resolution.
- [ADR-002](decisions/adr-002-format-and-compatibility.md): rev 7–8
  window, feature-gated layouts, no silent migration, no golden
  fixtures yet.
- [ADR-007](decisions/adr-007-cache-ownership-and-locking.md): one
  RW lock, shared holders never mutate, borrowed slices die at
  invalidation, explicit allocators.
- [ADR-010](decisions/adr-010-performance-objectives.md):
  correctness-gated optimization; informational bench harness, no
  thresholds.
- [ADR-011](decisions/adr-011-timestamp-semantics.md): coarse mtime /
  atime advance on every mutation, no ctime, zero stamp means epoch,
  corrupt stamps fail closed.

### In-memory caches

- **Bitmap cache** (`src/fs/alloc_cache.odin`): LRU cache (1024 entries) backed by
  `core:container/lru`. Eliminates redundant cluster-entry table reads. ~19 KB
  at default cluster size regardless of filesystem size. Clusters without an
  allocated table (fresh, reserved) resolve to empty bitmaps and are *not*
  counted as free by `statfs`; only genuine I/O failures propagate as errors.
- **Directory listing cache** (`src/fs/dir_cache.odin`): LRU cache (128
  directories) of assembled `[dynamic]Indexed_Entry` arrays keyed by chain
  start. `read_directory_entries` (once per path component in `resolve_path`)
  pays a lookup plus a clone on hits instead of a chain walk plus sector I/O.
  Sound because slots never shift (no compaction); invalidation lives in the
  two fs entry-write procs, which every slot mutation funnels through.

### Mounter helpers (`src/mounter/`)

Shared call-site plumbing so FUSE callbacks stay thin:

- `init_fs_state` — one initialisation for the caches, lock tables, and
  free-sector count, used by both the daemon (`run`) and the test harness
  (`init_fs_for_test`), so the two can't drift.
- `prepare_parent_slot` — the create/mkdir/symlink preamble (resolve parent
  → check name → find or extend a slot) returns a `Prepare_Slot_Result`
  (Ok / Parent_Not_Found / Name_Exists / Dir_Full / Not_A_Directory /
  Io_Error) so each caller maps the exact errno.
- `fh_parts` — unpacks the packed file handle into its identity fields
  (dir cluster, offset, entry index); `fh_pack` is its pack twin, so the
  `u64`↔`File_Handle` transmute has a single home. `remove_directory_entry`
  (see below) and the lock table key off the same identity.
- `ce_find_by_offset` / `ce_find_by_state` (`src/fs/clustermap.odin`) — the
  "scan a CE table for an entry" loop, shared by allocation, deallocation,
  LFN resolution, and xattr chain location.
- `mutate_entry_at` — the read-modify-write wrapper for `chmod`/`chown`/
  `utimens` (and xattr entry writes), resolving, calling a caller-supplied
  mutator, writing back, and invalidating.
- `truncate_chain_at` (`src/fs/clustermap.odin`) — the CE-chain walk for
  `fused_truncate`'s shrink path, shared out of the file-truncation logic.

### Advisory locks (`src/mounter/lock.odin`)

`lock` and `flock` are tracked entirely in memory per mount — no on-disk
format change, matching advisory-lock semantics (state is process-lifetime and
lost on unmount).

- **POSIX region locks** (`lock`, F_SETLK/F_SETLKW/F_GETLK): a per-file list
  of `Region_Lock{owner, pid, start, len, exclusive}` keyed by a stable
  `File_Identity` derived from the packed file handle
  `(dir_cluster, dir_offset, entry_index)`. A write request conflicts with any
  overlapping other-owner lock; a read request only with another owner's
  exclusive lock. F_GETLK reports the first conflicting exclusive lock or
  returns UNLCK. F_SETLKW is treated as non-blocking F_SETLK because a
  blocking wait would deadlock the single-threaded callback.
- **BSD flock** (`flock`): per-file holder list; any number of owners may hold
  LOCK_SH, LOCK_EX excludes all others. Conflicts always return EAGAIN (the
  callback cannot sleep, so LOCK_NB is the only viable behavior). The op word
  is parsed once at the boundary into `Flock_Cmd` + `nonblock`
  (`flock_parse_op`); the state machine switches on the enum. The `LOCK_*`
  constants stay `c.int` ABI values (deliberately not a `bit_set`).
- **Cleanup**: `fused_release` drops the releasing owner's locks (the kernel
  releases a process's locks when its last fd closes); `unlink`/`rmdir`
  drop all lock state for the removed entry. The kernel only forwards lock
  ops when the INIT handshake advertises `FUSE_POSIX_LOCKS | FUSE_FLOCK_LOCKS`
  (set in `fused_init`).

- **Path-resolution cache** (`src/mounter/core.odin`): LRU cache (128 entries).
  Avoids tree walks on repeated `getattr`/`open`/`readdir` calls. Invalidated
  on all mutations.

### Chain helpers (`src/fs/extents.odin`, `src/fs/directory.odin`)

All extent-chain I/O goes through four shared helpers so sector arithmetic
exists in one place instead of being re-derived at every call site:

- `read_chain` / `write_chain` — whole-chain read/write of a contiguous byte
  buffer (used by `xattr_load`/`xattr_store`/`read_directory_entries`).
  `write_chain` zero-pads the final sector.
- `walk_chain_sectors` — iterates a chain's sectors with a per-sector visitor
  (used by `find_free_slot_in_extent`, `check_name_exists`, `fused_readdir`).
- `read_entry_at_index` / `write_entry_at_index` — locate a directory entry by
  chain-relative index with pure run arithmetic, reading only the target
  sector (used by `read_entry_from_fh` and `write_entry_back`).

### Directory-entry removal

`remove_directory_entry` (`src/mounter/create.odin`) is the single
implementation of the removal sequence (deallocate content chain → clear
xattr chain → drop lock state → clear flags → write entry back), shared by
`fused_unlink`, `fused_rmdir`, and both `fused_rename` overwrite branches. It
also closes the stale-lock leak where rename-overwrite previously skipped
lock cleanup, and unifies error mapping (`fs_error_to_errno`) across all four
call sites.

### Directory-entry layout dispatch

`dir_entry_size` / `dir_entries_per_sector` are table-driven from
`DIR_ENTRY_LAYOUTS` (a `Dir_Entry_Layout{feature, size, per_sector}` row per
layout change, highest-revision feature first, V4 fallback). A future
revision that changes the entry layout adds one table row instead of editing
two parallel `if` chains.

### Journal (`src/fs/journal.odin`)

Crash consistency comes from a single journal: the physical redo-log WAL
in a dedicated journal region, exposed as the `JOURNAL_BACKEND` procedure
table (`begin` / `add` / `commit` / `finish` / `abort` / `recover`).
The full transaction contract lives in
[`docs/decisions/adr-001-journal-transaction-contract.md`](decisions/adr-001-journal-transaction-contract.md):

- `allocate_sectors`, `deallocate_sectors`, and `volume_open` call through
  the table. The table is kept (rather than direct calls) so a future
  journal format only adds a new backend value.
- **Log before home**: scans collect CE writes into a bounded plan;
  chunks flush (records + header durable, then home tables, then
  checkpoint). `commit` persists the log only; `finish` checkpoints
  (sequence always advances, watermark only on applied success).
  `abort` discards pre-commit entries only.
- `Journal_Entry` construction from a `Cluster_Entry` write is centralized in
  `journal_entry_from_cluster_entry`.
- Recovery collects valid ring slots, sorts by seq, and replays oldest-first
  so a wrapped-around older transaction can't overwrite a newer one.
  It stops at the first incomplete slot without advancing past it.
- Ring slots reserve header + maximum record sectors (non-overlapping);
  headers carry CRC/count/shape validation.

### Write path (`src/mounter/write_data.odin` + `src/mounter/write.odin`)

File-data writes share one range engine plus per-source providers, so the
run-walk bookkeeping (skip runs before the write offset, partial head /
whole-sector bulk / partial tail per run) exists once instead of three
near-identical loops:

- `write_range_to_runs` / `read_range_from_runs` — the shared loops.
  Iterates cached extent runs; each run does a partial-head RMW sector,
  whole-sector bulk, and a partial-tail RMW sector. `write_range_to_runs`
  consumes from a `Buf_Source`, `read_range_from_runs` delivers into a
  `Read_Sink`. A partial sector never spans source/sink segments.
- `Buf_Source` / `Read_Sink` — `copy`/`copy_to` (partial sector), `bulk`
  (whole sectors; the provider owns the I/O, including splice for
  `FUSE_BUF_IS_FD`), `remaining`. Providers:
  - `Mem_Source` / `Mem_Read_Sink` — one contiguous buffer (`fused_write` /
    `fused_read`).
  - `Bufvec_Source` — a FUSE bufvec with per-buf advance and splice to the
    raw disk fd for `FUSE_BUF_IS_FD` bufs (`fused_write_buf`);
    `fused_read_buf` now uses `collect_read_slices` to avoid the double walk.
    fd-backed bufs at unaligned offsets set a sticky error flag mapped to
    EIO (callbacks must never unwind through C).
  - `Zero_Source` — zero-fill (`zero_file_range`, used by fallocate).
- `ensure_chain_covers` — the shared "resolve → count → extend if short →
  invalidate → re-resolve" preamble for write/write_buf/truncate/fallocate/
  copy_file_range. Invalidates only the given chain's extent-cache entry so
  borrowed runs of other chains stay valid; `extended` reports whether
  allocation ran. `chain_sector_count` sums a run list.

### Image construction (`src/fs/format.odin`)

`format_image(fd, Format_Params)` owns the whole image layout — geometry
(cluster map, journal region, reserved/root clusters), MasterRecord, cluster
map, zeroed journal region, and the root cluster (CE table, root directory
entry, optional `/Kernel` demo file). The `format` tool (`cmd/format`) and
the test harness both drive it;
`features`/`rev` are parameters, so a future revision-variant image is a
parameter rather than a code fork.

### Error handling

`src/fs/` defines `FS_Error :: enum { None, Cluster_Not_Found, No_Space, ... }`.
Every I/O procedure returns `FS_Error` (or `(T, FS_Error)`) consistently.
Within `package fs`, `or_return`/`or_continue` propagates errors automatically.
At the FUSE boundary, `fs_error_to_errno` translates `FS_Error` to negated
errno via a `#partial switch`.

### Conversions and casts

`T(v)` for value conversions, `cast` for pointer casts only, `transmute`
only for bit-pattern views (`u8`/`u64` reps of flag domains, so retired bits
stay visible), `string`↔`[]u8` aliasing, and `u64`↔`File_Handle` packing.
`auto_cast` is never used (prototyping-only per the language docs). All three
forms are explicit by design (unlike C assignment conversion); `transmute`
is additionally compiler size-checked, but same-size is not same-meaning.
Untyped constants implicitly convert where lossless (e.g. `1 << 10`
into `c.uint32_t` flag consts); narrowing conversions (`u16`, `u32`) must
cite a domain bound or go through a saturating helper.

### Memory management

Functions producing variable-length results return `[dynamic]T` allocated on
`context.temp_allocator`. Callers own the allocation but don't need explicit
`delete` — the temp allocator is reset per FUSE callback via `free_all` in
`begin_op`. `src/mounter/main.odin` wraps the mount lifecycle in a
`mem.Tracking_Allocator` guarded behind `when ODIN_DEBUG` — zero overhead in
release builds. Leaked allocations are reported at unmount time.

`context` assignments are frame-local: they propagate downward to callees,
never upward to callers. A `context.allocator = ...` line inside `begin_op`
therefore affects only that frame — callers keep their own allocator. So
anything stored into shared structures (extent slices, path keys, LFN
strings) must name `fsys.allocator` explicitly on **both** allocation and
free; relying on `context` pairs heap allocs against tracking frees (or vice
versa) and crashes teardown. LRU eviction callbacks receive `fsys` as
`user_data` for exactly this reason.

## FUSE callbacks

| Category | Callbacks |
|---|---|
| **Lifecycle** | `init`, `destroy` |
| **Metadata** | `getattr`, `access`, `statfs`, `chmod`, `chown`, `utimens`, `statx` |
| **Read** | `read`, `read_buf` (zero-copy), `readdir`, `readlink`, `lseek` (SEEK_HOLE/SEEK_DATA) |
| **Write** | `write`, `write_buf` (zero-copy), `create`, `truncate`, `fallocate`, `copy_file_range` |
| **Directory** | `mkdir`, `rmdir`, `opendir`, `releasedir`, `fsyncdir` |
| **File ops** | `open`, `release`, `flush`, `fsync`, `unlink`, `rename` |
| **Links** | `symlink`, `readlink`, `link` (returns ENOSYS) |
| **Locks** | `lock` (POSIX region locks), `flock` (BSD whole-file) |
| **xattr** | `setxattr`, `getxattr`, `listxattr`, `removexattr` |
| **Stubs** | `mknod`, `ioctl` (return ENOSYS) |
| **Block/poll** | `bmap` (sector mapping), `poll` (returns POLLERR) |

## Testing

### Test suite structure

```
tests/
├── fused_test/                    Python test package
│   ├── suites/
│   │   ├── stress.py              Multi-threaded stress test (reader + writer workers)
│   │   └── bench.py               Throughput benchmark (write/read/statfs/readdir/create-storm)
│   ├── mount.py                   FUSE mount context manager (contextlib.contextmanager)
│   └── io.py                      read/write helpers, run_cli, make_file/make_dir context managers
├── conftest.py                    Pytest fixtures: mounted_fs, fused_bin, disker_bin, imgdump_bin
├── pyproject.toml                 Pytest markers: tool, fuse
├── test_basic.py                  7 FUSE smoke tests (pytest)
├── test_crash.py                  5 kill -9 crash-consistency tests (pytest: data, truncate-extend/shrink, unlink, long-name rename)
├── test_disker.py                 7 format tool CLI tests (pytest)
├── test_errors.py                 6 FUSE error path tests (pytest)
├── test_imgdump.py                12 imgdump tool tests (pytest: 10 dump + 2 corrupt-image guards)
├── test_lock.py                   6 lock/flock tests (pytest, cross-process)
├── test_rw.py                     13 read-write tests (pytest)
├── test_xattr.py                  7 xattr tests (pytest)
├── ci.py                          CI orchestrator (calls make + pytest)
├── run_in_namespace.sh            Thin shell: exec unshare -rUm timeout "$@"
├── test_common.odin               Shared Odin test helpers (image open, scratch volumes)
├── mounter_test.odin              41 mounter-callback unit tests
├── rmdir_test.odin                1 rmdir-on-unreadable-listing test (isolated image)
├── lock_test.odin                 5 lock/flock unit tests (direct fused_lock/fused_flock calls)
├── journal_test.odin              3 journal-backend tests (rev-8 WAL image)
├── journal_txn_test.odin          5 journal transaction-bounds tests (slots/replay/chunking/collapse, isolated images)
├── io_error_test.odin             2 fault-injection tests (truncated + read-only images)
├── fault_test.odin                12 deterministic fault tests (Nth read/write/sync fails, isolated images)
├── invalidation_test.odin         6 cache-invalidation tests
├── dir_op_test.odin               9 directory-operation tests
├── dir_test.odin                  6 directory tests
├── lfn_ext_test.odin              4 LFN tests
├── lfn_lifetime_test.odin         2 LFN storage-lifetime tests (rename/unlink, isolated images)
├── alloc_test.odin                8 allocator property tests
├── alloc_write_test.odin          17 allocator + write-path tests
├── ce_identity_test.odin          1 CE slot-identity test (stale-duplicate clear, isolated image)
├── check_test.odin                19 checker tests (Stage A ownership/links/bounds/free + Stage B reachability/orphans/journal, isolated images)
├── truncate_test.odin             3 truncate-boundary tests (fragmented chain + journal pins, isolated image)
├── zero_fill_test.odin            5 extension zero-fill + zero-length-write tests (poison-reuse images)
├── free_space_test.odin           3 free-space oracle tests (Reserved/Full accounting, isolated images)
├── cache_test.odin                10 cache tests
├── fs_test.odin                   5 filesystem core tests
├── xattr_test.odin                6 xattr unit tests
└── size_check.odin                1 struct-size test (12 FUSE structs vs C ground truth)
```

### CI pipeline

| Phase | What it runs |
|---|---|
| 1. Build + static analysis | `make check` (struct sizes) + `make audit` (context) + `make vet` |
| 2. Unit tests | `make test` (174 Odin tests) |
| 3. Tool integration | `make pytest -m tool` (17 format + imgdump tests) |
| 4. FUSE basic | `make smoke` inside `unshare -rUm` (pytest: basic + error tests) |
| 5. FUSE rw | `make smoke-rw` inside `unshare -rUm` (pytest: read-write tests) |
| 6. FUSE stress | `make smoke-mt` inside `unshare -rUm` (stress.py) |
| 7. Benchmark | `make bench` (bench.py — write/read/statfs/readdir/create-storm MB/s) |

### Test isolation

FUSE tests run inside an isolated mount namespace (`unshare -rUm`) so that any
FUSE mount created during testing is automatically torn down when the process
exits — even if killed. The `run_in_namespace.sh` wrapper is the only shell
script that survives; everything else is Python or Odin.

### Diagnostics

**imgdump --json** produces valid JSON even with corrupted or garbage directory
entries. Entry names with non-printable bytes are escaped as `\uXXXX`. The JSON
master record includes `rev_min`, `rev_max`, and `features` fields.

## Remaining work

All 43 `fuse_operations` callbacks are wired.

### Deferred refactors

- **`vfsops` domain layer** — only if a second front-end (CLI tool, NFS
  export, headless fuzz harness) is planned; otherwise deferred indefinitely.
