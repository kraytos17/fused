# fused — FUSE filesystem in Odin

A FUSE filesystem daemon written in Odin, backed by a cluster-based on-disk
format (rev 7, feature flags, uid/gid support, journaling). 35 of 43
`fuse_operations` callbacks are implemented. Multi-threaded by default,
with a `sync.Mutex` guarding cache mutation. Zero-copy I/O via `splice(2)`.
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
src/
  fuse3/              FFI binding to libfuse3.so
  fs/                 On-disk format + all volume logic
    structure.odin      Packed on-disk structs (rev 7, feature flags)
    volume.odin          Volume struct, volume_open/close
    diskio.odin          Sector read/write
    clustermap.odin       Cluster map reader/writer
    extents.odin          Extent chain walker
    directory.odin        Directory entry iteration, LFN resolution
    allocate.odin          Sector allocator/deallocator
    alloc_cache.odin        LRU bitmap cache
    path.odin                 Unified path resolution
    journal.odin                Intent log + journal v2 WAL
    validate.odin                 MasterRecord validation
    display.odin                    Human-readable flag formatters
  mounter/            FUSE callbacks (35 wired), package mounter
    core.odin            FS struct, begin_op/end_op, resolve_path
    dir.odin               Directory slot helpers
    read.odin                 fused_getattr, fused_readdir, fused_read
    write.odin                  fused_write, fused_truncate, fused_copy_file_range
    create.odin                    fused_create, fused_mkdir, fused_symlink, fused_rename
    misc.odin                        fused_utimens, fused_chmod, fused_lseek, fused_statfs
tests/                63 Odin unit tests + 48 Python pytest integration tests
```

## Prerequisites

- Odin dev-2026-07-nightly or later
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
| `-s` | Single-threaded mode (default: multi-threaded with mutex) |
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
make test                       # 63 Odin unit tests
make pytest                     # 48 Python integration tests
make ci                         # full pipeline: build → check → audit → test → tool → FUSE smoke
make smoke                      # basic FUSE ops (isolated namespace, needs /dev/fuse)
make smoke-rw                   # read-write + persistence
make smoke-errors               # error path tests
```

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
| `test` | Odin unit tests (63) |
| `pytest` | Python integration tests (48) |
| `check` | Struct-size cross-check (Odin compile-time `#assert`s) |
| `audit` | Verify every `proc "c"` callback uses `begin_op` (35 callbacks) |
| `smoke` | Basic FUSE smoke test in an isolated namespace (pytest) |
| `smoke-rw` | Read-write FUSE test (pytest) |
| `smoke-mt` | Multi-threaded stress test |
| `smoke-errors` | FUSE error-path tests (pytest) |
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

`imgdump --json` always produces valid JSON; non-printable bytes in entry
names are escaped as `\uXXXX`. The JSON master record includes `rev_min`,
`rev_max`, and `features`.

## ABI compatibility

Every cross-FFI struct in `src/fuse3/types.odin` and every on-disk struct
in `src/fs/structure.odin` carries a compile-time
`#assert(size_of(T) == N)`. All 12 FUSE struct sizes are cross-checked via
`make check`.

## Architecture highlights

- **Zero package-level globals.** All mount state lives in a single `FS`
  struct passed via `fuse_get_context().private_data`. `src/fs/` is fully
  stateless.

- **Thread safety.** A `sync.Mutex` on `FS` serializes cache-mutating
  callbacks. Multi-threaded FUSE dispatch is the default. Read-only
  callbacks (`read`, `read_buf`, `statfs`, `lseek`) run lock-free.

- **Zero-copy I/O.** `fused_read_buf` returns a `fuse_bufvec` with
  `FUSE_BUF_IS_FD | FUSE_BUF_FD_SEEK` pointing at the backing file; the
  kernel splices directly from disk to the FUSE pipe. `fused_write_buf`
  uses `linux.splice()` for the write side.

- **Format versioning.** Rev 6–7, with `rev_min`/`rev_max` range checking
  and a `features` bitmask for runtime dispatch. Intent log (rev 6) and
  journal v2 WAL (rev 7) provide crash consistency. See [`docs/REV.md`](docs/REV.md)
  for the full revision history.

- **Two in-memory caches.** LRU bitmap cache (1024 cluster entries) and
  LRU path-resolution cache (128 entries) — no filesystem-size-scaled
  arrays.

## Remaining work

8 of 43 `fuse_operations` callbacks remain unwired: `lock`, `flock`,
`bmap`, `poll`, `setxattr`, `getxattr`, `listxattr`, `removexattr`.
