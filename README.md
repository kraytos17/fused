# fused — FUSE filesystem in Odin

FUSE filesystem daemon implemented in Odin. Cluster-based on-disk format
(rev 5 with feature flags, uid/gid support). 35 of 43 `fuse_operations`
callbacks implemented. Multi-threaded by default with `sync.Mutex` for
cache protection. Zero-copy I/O via `splice(2)`. LFN (long filenames up to
255 chars) supported through bump-allocated data sectors.

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
src/fuse3/          FFI binding to libfuse3.so
src/fs/
  structure.odin    Packed on-disk structs (rev 5 with feature flags)
  diskio.odin       Sector read/write
  validate.odin     MasterRecord validation (range + feature flags)
  display.odin      Human-readable flag formatters
  clustermap.odin   Cluster map reader/writer
  extents.odin      Extent chain walker
  directory.odin    Directory entry iteration, LFN, uid/gid
  allocate.odin     Sector allocator/deallocator
  alloc_cache.odin  LRU bitmap cache
src/disker/         Image formatter (standalone, no libfuse3)
src/mounter/        FUSE callbacks (35 wired) — wires src/fs/ into src/fuse3/
tools/imgdump/      Image dumper (read-only, JSON/text/hex output)
tests/              Odin unit tests + Python integration suite
```

## Build

**Prerequisites:**
- Odin dev-2026-07-nightly or later
- libfuse3 >= 3.18
- Linux kernel with fuse module loaded (`modprobe fuse`)

```
make all           # clean → build all → format image → test → vet
make build         # debug build → build/fused
make release       # optimized build → build/fused_release
make disker        # image formatter → build/disker
make imgdump       # image dumper → build/imgdump
make run-disker    # format 1 MB image → fused.img
make test          # Odin unit tests
make ci            # full pipeline: build + check + audit + test + FUSE smoke
```

## Mount

```
make mount                     # foreground, debug, mountpoint=mnt
./build/fused fused.img -f mnt                           # foreground
./build/fused --log-file=fused.log fused.img mnt          # with app log
./build/fused --log-level=warn fused.img mnt              # production
```

| Flag | Purpose |
|---|---|
| `-f` | Foreground (default — added automatically) |
| `-s` | Single-threaded mode (default: multi-threaded with mutex) |
| `-d` | FUSE protocol debug output (stderr) |
| `--log-file=<path>` | Redirect Odin log messages to file (append) |
| `--log-level=<level>` | Filter: debug (default), info, warn, error |
| `--log-format=<fmt>` | Output format: long (default), short, full |

## Production logging

```
./build/fused --log-level=warn fused.img mnt
./build/fused --log-level=error fused.img mnt
```

The daemon does not implement SIGHUP log reopening. Use `copytruncate` in
logrotate or pipe-based rotation:

```
./build/fused --log-level=warn fused.img mnt 2>&1 \
    | rotatelogs /var/log/fused/%Y%m%d.log 86400
```

## Makefile targets

| Target | Description |
|---|---|
| `all` | clean → build all binaries → format image → test |
| `build` | Debug build → build/fused |
| `disker` | Image formatter → build/disker |
| `imgdump` | Image dumper → build/imgdump |
| `release` | Optimized build → build/fused_release |
| `run-disker` | Format 1 MB image → fused.img |
| `mount` | Build + mount in foreground |
| `unmount` | fusermount3 -u mnt |
| `clean` | Remove build/, logs/, mnt/, fused.img, kill running mount |
| `test` | Odin unit tests |
| `check` | C vs Odin struct size cross-check (11 structs) |
| `audit` | Verify every `proc "c"` restores context + logger (35 callbacks) |
| `smoke` | Basic FUSE smoke test inside isolated namespace (18 checks) |
| `smoke-rw` | Read-write FUSE test (37 checks: create, write, mkdir, unlink, persistence, chmod, fallocate, symlink, truncate, utimens, chown, fsync, deep-nest) |
| `smoke-mt` | Multi-threaded stress test (reader + writer workers, 15s) |
| `smoke-errors` | FUSE error path tests (ENOTDIR, ENOTEMPTY, EACCES, ENOENT, EEXIST, ENOSYS) |
| `disker-test` | Disker CLI + imgdump JSON/text/hex validation (29 checks) |
| `ci` | build + check + audit + test + tool integration + all smoke tests |
| `verify` | check + audit (no FUSE needed) |
| `verify-full` | check + audit + all smoke tests |

The compiler uses `-thread-count:4` by default (set `THREAD_COUNT=N` to tune).
Set `SHOW_TIMINGS=1` to see compile-time breakdown.

## Format image

```
build/imgdump fused.img                           # human-readable dump
build/imgdump --json fused.img                    # machine-readable JSON
build/imgdump --hex=/Kernel fused.img             # hex dump of /Kernel
build/disker --force --output=my.img --size=16M   # custom image
```

`imgdump --json` always produces valid JSON — non-printable bytes in entry names
are escaped as `\uXXXX`. The JSON master record includes `rev_min`, `rev_max`,
and `features` fields.

## ABI compatibility

Every cross-FFI struct in `src/fuse3/types.odin` and every on-disk struct in
`src/fs/structure.odin` carries a compile-time `#assert(size_of(T) == N)`.
All 12 FUSE struct sizes and all 43 `fuse_operations` field offsets are
cross-checked against C ground truth at build time via `make check`.

## Architecture highlights

- **Zero package-level globals** — all mount state in a single `FS` struct
  passed via `fuse_get_context().private_data`. The `fs/` package is fully
  stateless.

- **Thread safety** — `sync.Mutex` on `FS` serializes cache-mutating
  callbacks. Multi-threaded FUSE dispatch is the default. Read-only callbacks
  (`read`, `read_buf`, `statfs`, `lseek`) run lock-free.

- **Zero-copy I/O** — `fused_read_buf` returns a `fuse_bufvec` with
  `FUSE_BUF_IS_FD | FUSE_BUF_FD_SEEK` pointing to the backing file. The
  kernel splices directly from disk → FUSE pipe. `fused_write_buf` uses
  `linux.splice()` for the write side.

- **Format versioning** — rev 5 with `rev_min`/`rev_max` range checking and
  `features` bitmask for runtime dispatch. `SUPPORTED_REV_MIN = SUPPORTED_REV_MAX = 5`.
  Rev 4 images can't be parsed (the MasterRecord struct changed between rev 4 and 5).

- **Two in-memory caches** — LRU bitmap cache (1024 cluster entries) + LRU
  path-resolution cache (128 entries). No filesystem-size-scaled arrays.

## Remaining work

8 of 43 `fuse_operations` callbacks are not yet wired:
`lock`, `flock`, `bmap`, `poll`, `setxattr`, `getxattr`, `listxattr`,
`removexattr`.
