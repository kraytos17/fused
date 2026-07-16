# fused — FUSE filesystem

FUSE filesystem daemon implemented in Odin. Implements a cluster-based on-disk
format (rev 4) with read-write FUSE mounting via a libfuse3 FFI binding.
Multi-threaded by default (no `-s` flag), with a `sync.Mutex` protecting shared
caches.

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
src/fuse3/        FFI binding to libfuse3.so
src/fs/           ├── structure.odin     Packed on-disk structs
                  ├── diskio.odin        Sector read/write
                  ├── validate.odin      MasterRecord validation
                  ├── display.odin       Human-readable flag formatters
                  ├── clustermap.odin    Cluster map reader/writer
                  ├── extents.odin       Extent chain walker
                  ├── directory.odin     Directory entry iteration, LFN
                  ├── allocate.odin      Sector allocator/deallocator
                  └── alloc_cache.odin   LRU bitmap cache
src/disker/       Image formatter (standalone, no libfuse3)
src/mounter/      FUSE callbacks — wires src/fs/ into src/fuse3/
tools/imgdump/    Image dumper (read-only, uses only src/fs/)
tests/            Unit tests, struct-size cross-checks, smoke tests
demo/             Standalone hello-world FUSE demo (no src/fs/ dependency)
```

## Build

**Prerequisites:**
- Odin dev-2026-07-nightly or later
- libfuse3 >= 3.18
- Linux kernel with fuse module loaded (`modprobe fuse`)

```
make all           # clean → build all binaries → format image → test → vet
make build         # debug build → build/fused
make release       # optimized build → build/fused_release
make disker        # image formatter → build/disker
make imgdump       # image dumper → build/imgdump
make run-disker    # format 1MB image → fused.img
make test          # unit tests
make disker-test   # integration tests for disker + imgdump (20)
make ci            # full pipeline: build + check + audit + test + FUSE smoke
```

## Mount

```
make mount         # foreground, debug, mountpoint=mnt
./build/fused fused.img -f mnt                    # foreground
./build/fused --log-file=fused.log fused.img mnt   # with application log
./build/fused --log-level=warn fused.img mnt       # production (warnings only)
```

| Flag | Purpose |
|---|---|
| `-f` | Foreground (default — added automatically) |
| `-s` | Single-threaded mode (default: multi-threaded with mutex) |
| `-d` | FUSE protocol debug output (stderr) |
| `--log-file=<path>` | Redirect Odin log messages to file (append mode) |
| `--log-level=<level>` | Filter: debug (default), info, warn, error |

## Production logging

Odin log messages (getattr, create, write, errors) are written to stdout by
default. The FUSE `-d` flag produces low-level protocol output on stderr.

**Log levels:**

```
./build/fused --log-level=warn fused.img mnt
./build/fused --log-level=error fused.img mnt
```

**External rotation (recommended):**

```
./build/fused --log-level=warn fused.img mnt 2>&1 \
    | rotatelogs /var/log/fused/%Y%m%d.log 86400
```

The daemon does not implement SIGHUP log reopening — Odin's logger allocates
memory during initialization, which is not signal-safe. Use `copytruncate` in
logrotate or pipe-based rotation instead.

## Makefile targets

| Target | Description |
|---|---|
| `all` | clean → build all binaries → format image → test |
| `build` | Debug build → build/fused |
| `disker` | Image formatter → build/disker |
| `imgdump` | Image dumper → build/imgdump |
| `release` | Optimized build → build/fused_release |
| `run-disker` | Format 1 MB image → fused.img |
| `test` | Unit tests (47) |
| `disker-test` | Integration tests for disker + imgdump (20) |
| `smoke` | Read-only FUSE smoke test (14 checks) |
| `smoke-rw` | Read-write FUSE smoke test (25 steps: create, write, mkdir, unlink, remount, persistence, df) |
| `smoke-harness` | smoke via fuse_harness (isolated namespace, timed) |
| `smoke-rw-harness` | smoke-rw via fuse_harness (isolated namespace, timed) |
| `smoke-mt` | Multi-threaded stress test (concurrent read/write/delete workers) |
| `check` | C vs Odin struct size cross-check |
| `audit` | Verify every `proc "c"` restores context and logger |
| `ci` | build + check + audit + test + smoke-harness (all phases) |
| `ci-full` | ci + tool integration tests + smoke-rw |
| `clean` | Remove build/ and logs/ |
| `clean-logs` | Remove logs/ and cached test image |

The compiler uses `-thread-count:4` by default (set `THREAD_COUNT=N` to tune)
and `-no-threaded-checker` to skip the race-detector LLVM pass. Clean builds
use `-use-single-module` for speed; incremental builds use `-use-separate-modules`.
Set `SHOW_TIMINGS=1` to see compile-time breakdown.

## ABI compatibility

Every cross-FFI struct in `src/fuse3/types.odin` and every on-disk struct in
`src/fs/structure.odin` carries a compile-time `#assert(size_of(T) == N)`.
All 12 FUSE struct sizes and all 43 `fuse_operations` field offsets are
cross-checked against C at build time via `make check`.

## Architecture notes

Mount state (disk handle, master record, LRU bitmap cache, path cache, logger)
is held in a single `FS` struct passed as `fuse_get_context().private_data`. No
package-level globals — the `fs/` package is fully stateless, with all
dependencies passed as explicit parameters. This makes the concurrency model
explicit: a `sync.Mutex` on the `FS` struct serializes cache-mutating callbacks,
enabling multi-threaded FUSE dispatch by default. Read-only callbacks
(`read`, `statfs`) run lock-free.
