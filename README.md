# fused — FUSE filesystem in Odin

A FUSE filesystem daemon written in Odin, backed by a cluster-based on-disk
format (rev 8, feature flags, uid/gid support, journaling, extended
attributes). All 43 `fuse_operations` callbacks are implemented.
Multi-threaded by default, with a `sync.RW_Mutex` guarding shared state
(exclusive for mutations, shared for reads).
Zero-copy I/O via `splice(2)`.
Long filenames (up to 255 characters) are supported through bump-allocated
data sectors.

## Quick start

```
make all
make mount
ls mnt                   # Kernel
cat mnt/Kernel | head -c4 | od -tx1
make unmount
```

## Repository layout

```
cmd/
  mount/main.odin     FUSE mounter binary (package main, calls mounter.run())
  format/main.odin    Image formatter binary (standalone, no libfuse3)
  dump/               Image dumper (read-only, JSON/text/hex output)
  check/main.odin     Struct-size cross-check binary
src/
  fuse3/              FFI binding to libfuse3.so (api, types, constants, foreign)
  logflags/           Shared --log-level/--log-format parsing for the CLI tools
  fs/                 On-disk format + all volume logic
    structure.odin      Packed on-disk structs (rev 8, feature flags)
    volume.odin          Volume struct, volume_open/close, File_Handle pack
    diskio.odin          Sector read/write
    clustermap.odin       Cluster map + entry table reader/writer, chain walk
    extents.odin          Extent chain walker
    directory.odin        Directory entry iteration, LFN resolution
    allocate.odin          Sector allocator/deallocator
    alloc_cache.odin        Cache sizing + LRU bitmap cache
    dir_cache.odin          LRU directory-listing cache
    path.odin                 Unified path resolution
    journal.odin                Journal WAL (crash consistency)
    xattr.odin                  Extended-attribute blob read/write
    format.odin                 Image construction (format_image, shared with tests)
    validate.odin                 MasterRecord validation
    display.odin                    Human-readable flag formatters
  mounter/            FUSE callbacks, package mounter
    main.odin            run() daemon lifecycle, build_operations table
    core.odin            FS struct, locking, resolve + extent caches, fh pack/unpack
    dir.odin               Directory slot helpers
    read.odin                 fused_getattr, fused_readdir, fused_open,
                              fused_read, fused_read_buf, fused_readlink
    write.odin                  fused_write, fused_write_buf, fused_truncate,
                                fused_fallocate, fused_copy_file_range
    write_data.odin               shared range engines (write_range_to_runs /
                                read_range_from_runs) + Buf/Read sinks
                                (Mem/Bufvec/Zero) + ensure_chain_covers +
                                RunCursor + collect_read_slices
    create.odin                    fused_create, fused_mkdir, fused_symlink,
                                   fused_unlink, fused_rmdir, fused_rename,
                                   remove_directory_entry
    xattr.odin                     fused_setxattr, fused_getxattr, fused_listxattr, fused_removexattr
    lock.odin                      fused_lock (POSIX), fused_flock (BSD)
    misc.odin                        fused_utimens, fused_access, fused_chmod,
                                     fused_chown, fused_flush, fused_release,
                                     fused_opendir/releasedir, fused_fsync/fsyncdir,
                                     fused_lseek, fused_statfs, fused_mknod,
                                     fused_ioctl, fused_link, fused_statx,
                                     fused_bmap, fused_poll, fused_init/destroy
tools/
  audit/              Callback locking/logger/hygiene/attribute audit
demo/
  hello_main.odin     Minimal FUSE hello-world example
tests/                Odin unit tests (129) + Python pytest suite (61)
```

## Prerequisites

- Odin dev-2026-10-nightly or later
- libfuse3 >= 3.18
- Linux kernel with the fuse module loaded (`modprobe fuse`)

## Workflow

### 1. Build everything

```bash
make build       # debug build → build/fused
make format      # image formatter → build/format
make imgdump     # image inspector → build/imgdump
make all         # does all three + creates test image + runs tests
```

### 2. Create a disk image

```bash
make create-image               # 1 MB default → fused.img
build/format --force --output=my.img --size=16M   # custom
```

### 3. Inspect the image

```bash
build/imgdump fused.img                    # human-readable
build/imgdump --json fused.img              # machine-readable JSON
build/imgdump --hex=/Kernel fused.img       # hex dump of a file
```

### 4. Mount it

```bash
make mount                  # foreground, debug, creates mnt/ automatically
```

Or manually:

```bash
mkdir -p mnt
build/fused fused.img -f mnt
```

In another terminal:

```bash
ls mnt/                     # "Kernel" demo file
cat mnt/Kernel | head -c4 | od -tx1
```

FUSE flags:

| Flag | Purpose |
|---|---|
| `-f` | Foreground (default, added automatically) |
| `-s` | Single-threaded mode (default: multi-threaded) |
| `-d` | FUSE protocol debug output (stderr) |
| `--log-file=<path>` | Redirect Odin log messages to file (append) |
| `--log-level=<level>` | Filter: debug (default), info, warn, error |
| `--log-format=<fmt>` | Output format: long (default), short, full |

### 5. Unmount

```bash
make unmount                    # clean
fusermount3 -u mnt              # or by hand
```

### 6. Test

```bash
make test                       # Odin unit tests
make pytest                     # Python integration tests
make ci                         # full pipeline: build → check → audit → test → tool → FUSE smoke
make smoke                      # basic FUSE ops (isolated namespace, needs /dev/fuse)
make smoke-rw                   # read-write + persistence
make smoke-errors               # error path tests
make bench                      # throughput benchmark (write/read/statfs/readdir)
```

Two test layers: Odin unit tests (`make test`, 129 tests) exercise the `fs` library and
the `mounter` callbacks directly in-process (errno mapping, xattr semantics,
path resolution — no kernel). Python pytest tests (`make pytest`, 61 tests) mount the
real filesystem via `/dev/fuse` and verify end-to-end behavior through the
kernel, including errno translation on real syscalls.

## Production logging

```
./build/fused --log-level=warn fused.img mnt
./build/fused --log-level=error fused.img mnt
```

The daemon does not support SIGHUP log reopening. Use `copytruncate` in
logrotate, or pipe-based rotation:

```
./build/fused --log-level=warn fused.img mnt 2>&1 \
    | rotatelogs /var/log/fused/%Y%m%d.log 86400
```

## Makefile targets

| Target | Description |
|---|---|
| `all` | Build all binaries, format image, run tests |
| `build` | Debug build → `build/fused` |
| `format` | Image formatter → `build/format` |
| `imgdump` | Image dumper → `build/imgdump` |
| `create-image` | Format a 1 MB image → `fused.img` |
| `mount` | Build, then mount in foreground |
| `unmount` | `fusermount3 -u mnt` |
| `clean` | Remove `build/`, `logs/`, `mnt/`, `fused.img`; kill any running mount |
| `test` | Odin unit tests |
| `pytest` | Python integration tests |
| `check` | Struct-size cross-check (12 FUSE structs vs C ground truth) |
| `check-tool` | Struct-size cross-check binary → `build/check` |
| `audit` | Callback context/locking, logger discipline, src hygiene, attributes (`--strict` gates; unknown flags rejected) |
| `vet` | Build all binaries with vet, shadowing, strict-style, tabs, disallow-do |
| `smoke` | Basic FUSE smoke test in an isolated namespace (pytest) |
| `smoke-rw` | Read-write FUSE test (pytest) |
| `smoke-mt` | Multi-threaded stress test |
| `smoke-errors` | FUSE error-path tests (pytest) |
| `smoke-crash` | Kill -9 crash-consistency tests (pytest) |
| `doctor` | Audit-strict + vet + image coherence check |
| `bench` | Throughput benchmark (`bench.py`: write/read/statfs/readdir/create-storm) |
| `ci` | build + check + audit + test + pytest + all smoke tests |

The compiler defaults to `-thread-count:4` (override with `THREAD_COUNT=N`).
Set `SHOW_TIMINGS=1` for a compile-time breakdown.

## Format image

```
build/imgdump fused.img                           # human-readable dump
build/imgdump --json fused.img                     # machine-readable JSON
build/imgdump --hex=/Kernel fused.img               # hex dump of /Kernel
build/format --force --output=my.img --size=16M      # custom image
```

`imgdump --json` always produces valid JSON; strings are escaped per the
JSON spec (ASCII/UTF-8 preserved, control and invalid bytes escaped). The
JSON master record includes `rev_min`, `rev_max`, and `features`.

## ABI compatibility

Every cross-FFI struct in `src/fuse3/types.odin` and every on-disk struct
in `src/fs/structure.odin` carries a compile-time
`#assert(size_of(T) == N)`. All 12 FUSE struct sizes are cross-checked via
`make check`.

## Architecture highlights

- **Zero package-level globals.** All mount state lives in a single `FS`
  struct passed via `fuse_get_context().private_data`. `src/fs/` is fully
  stateless.

- **Thread safety.** A `sync.RW_Mutex` on `FS` guards shared state:
  mutating callbacks take it exclusively (`begin_op()`/`end_op()`),
  read-only callbacks share it (`begin_read_op()`/`end_read_op()`,
  non-mutating cache access only). Multi-threaded FUSE dispatch is the
  default. Disk I/O itself needs no lock (pread/pwrite).

- **Zero-copy I/O.** `fused_read_buf` returns a `fuse_bufvec` with
  `FUSE_BUF_IS_FD | FUSE_BUF_FD_SEEK` pointing at the backing file; the
  kernel splices directly from disk to the FUSE pipe. `fused_write_buf`
  uses `linux.splice()` for the write side.

- **Format versioning.** Rev 7–8, with `rev_min`/`rev_max` range checking
  and a `features` bitmask for runtime dispatch. The journal WAL (rev 7)
  provides crash consistency; rev 8 adds extended
  attributes. See [`docs/REV.md`](docs/REV.md) for the full revision history.

- **Extended attributes.** `setxattr`/`getxattr`/`listxattr`/`removexattr`
  store attributes in a self-describing blob chain referenced by each
  directory entry's `xattr_cluster`. Linux limits apply (255-byte names,
  64 KB values). See [`docs/DESIGN.md`](docs/DESIGN.md).

- **Advisory locks.** `lock` (POSIX `fcntl` region locks: F_SETLK /
  F_SETLKW / F_GETLK) and `flock` (BSD whole-file locks, multiple shared
  holders) are tracked in-memory per mount. Locks are advisory and lost on
  unmount; F_SETLKW treats a busy lock as a non-blocking conflict
  (`EAGAIN`) since FUSE callbacks cannot sleep.

- **In-memory caches.** LRU bitmap cache (1024 clusters), LRU
  path-resolution cache (128 entries), LFN cache (256 entries), and LRU
  directory-listing cache (128 directories) — no filesystem-size-scaled
  arrays.

- **I/O error handling.** Every `src/fs` I/O procedure returns `FS_Error`
  (`Sector_Read_Error`/`Sector_Write_Error` etc.) and propagates via
  `or_return`; the FUSE boundary maps it once via `fs_error_to_errno`.

- **Extent cache.** File-data extent chains are cached in-process
  (`FS.extents`), so repeated reads/writes skip the per-cluster metadata
  walk. Directory listings are cached separately with exact-remove plus
  clear-all-fallback invalidation. `statfs` uses a cached
  free-sector count kept coherent via delta updates on
  `allocate`/`truncate`/`remove`/`xattr` (not a stale scan).

## Remaining work

All 43 `fuse_operations` callbacks are wired. See
[`docs/DESIGN.md`](docs/DESIGN.md) for deferred refactors.
