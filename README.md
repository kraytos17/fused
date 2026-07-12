# fused — FUSE filesystem

FUSE filesystem daemon implemented in Odin. Implements a cluster-based on-disk
format with read-write FUSE mounting via a libfuse3 FFI binding.

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
src/fs/           On-disk format, allocator, directory iteration
src/disker/       Image formatter (standalone, no libfuse3)
src/mounter/      FUSE callbacks — wires src/fs/ into src/fuse3/
tools/imgdump/    Image dumper (read-only, uses only src/fs/)
tests/            Unit tests, struct-size cross-checks, smoke tests
docs/             Design document, implementation plan
```

## Build

**Prerequisites:**
- Odin dev-2026-07-nightly or later
- libfuse3 >= 3.18
- Linux kernel with fuse module loaded (`modprobe fuse`)

```
make all           # clean + disker + build + imgdump + run-disker + test + vet
make build         # debug build → build/fused
make release       # optimized build → build/fused_release
make disker        # image formatter → build/disker
make run-disker    # format 1MB image → fused.img
make test          # unit tests
make ci            # full pipeline: build + check + audit + test + smoke
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
| `all` | clean + disker + build + imgdump + run-disker + test + vet |
| `build` | Debug build → build/fused |
| `release` | Optimized build → build/fused_release |
| `test` | Unit tests |
| `check` | C vs Odin struct size cross-check |
| `audit` | Verify every `proc "c"` restores context and logger |
| `smoke` | mount + ls + cat + stat + write + unmount |
| `smoke-rw` | Full read-write test (create, write, mkdir, unlink, remount) |
| `ci` | build + check + audit + test + smoke (all phases) |
| `clean` | Remove build/ and logs/ |
| `clean-logs` | Remove logs/ and cached test image |

## ABI compatibility

Every cross-FFI struct in `src/fuse3/types.odin` and every on-disk struct in
`src/fs/structure.odin` carries a compile-time `#assert(size_of(T) == N)`.
All 12 FUSE struct sizes and all 43 `fuse_operations` field offsets are
cross-checked against C at build time via `make check`.
