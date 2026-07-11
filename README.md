# fused

A FUSE filesystem daemon in Odin with its own on-disk format —
backed by a hand-verified libfuse3 binding.

## What this is

An Odin binding to the libfuse3 **high-level** (`fuse_operations`) API on
Linux/amd64, plus a complete filesystem driver for the fused format
(hybrid FAT-style cluster chains with two-level indirection).

## On-disk format

The image header at sector 0 carries a 7-byte `sig` (`"FUSED\0\0"`) and a
`rev` field (currently `2`).  The sig identifies the filesystem family and
never changes; `rev` carries the format version.  Future format bumps only
need to raise the `rev` floor in `validate_master`.
## Layout

```
fused/
├── src/
│   ├── fuse3/                 # the binding to libfuse3
│   │   ├── foreign.odin       # `foreign import libfuse3` + foreign block
│   │   ├── constants.odin     # enums, capability bit_set, version pin
│   │   ├── types.odin         # every struct passed across the FFI boundary
│   │   └── api.odin           # Odin-friendly wrappers (run, fill_dir, nix, ctx)
│   ├── fs/                    # core filesystem logic (no FUSE dependency)
│   │   ├── structure.odin     # MasterRecord, ClusterMapEntry, ClusterEntry, DirectoryEntry
│   │   ├── diskio.odin        # sector_read / sector_write against ^os.File
│   │   ├── validate.odin      # validate_master, FS_Error enum
│   │   ├── clustermap.odin    # cluster map reader, find_cluster_entry
│   │   └── directory.odin     # directory entry iteration, LFN resolution
│   ├── disker/                # image formatter CLI
│   │   └── main.odin
│   └── mounter/               # FUSE glue — wires fs/ into fuse3/
│       └── main.odin          # (stub for now; validates image, prints summary)
├── tools/
│   └── imgdump/               # hex/structure dumper
│       └── main.odin
├── demo/
│   └── hello_main.odin
├── tests/
│   ├── c_assert.c             # C ground-truth sizes & offsets
│   ├── size_check.odin        # Odin-side size dump + @test assertions
│   ├── check_sizes.sh         # cross-checks C vs Odin struct sizes
│   ├── check_context.sh       # audits "c" callbacks for context restoration
│   └── smoke.sh               # end-to-end mount + ls + cat + stat
├── Makefile                   # single build entrypoint
├── odinfmt.json
└── ols.json
```

## Build

Requires:
- `odin` (dev-2026-07-nightly tested)
- `fuse3` 3.18.x (`pacman -S fuse3` on Arch)
- Linux kernel with the `fuse` module loaded

```sh
# Format a fresh 1 MB image
make disker && make run-disker     # → fused.img

# Inspect the image
make imgdump && ./build/imgdump fused.img

# Build the mounter
make build                         # → build/fused

# Validate the image
./build/fused fused.img            # prints MasterRecord summary

make release                       # → build/fused_release
```

## Use

```sh
# 1. Format a disk image
make run-disker
# or: ./build/disker --size=4M --cluster-size=16 --output=myfs.img

# 2. Mount
make mount MOUNTPOINT=/tmp/fused  # once the mounter has FUSE callbacks

# 3. Unmount
make unmount MOUNTPOINT=/tmp/fused
```

## Makefile targets

| Target | Description |
|---|---|
| `build` | Debug build → `build/fused` (mounter) |
| `release` | Aggressive-opt build → `build/fused_release` |
| `disker` | Build the image formatter → `build/disker` |
| `run-disker` | Build + format a default 1 MB image → `fused.img` |
| `imgdump` | Build the image dumper → `build/imgdump` |
| `mount` | Build then run with `-f -d` against `MOUNTPOINT` |
| `unmount` | `fusermount3 -u MOUNTPOINT` |
| `clean` | Remove `build/`, kill any stale mount |
| `test` | Odin test suite (struct size `@test` assertions) |
| `check` | C vs Odin struct size cross-check (12 structs) |
| `audit` | Audit `proc "c"` callbacks for context restoration |
| `smoke` | Build + mount + `ls` + `cat` + `stat` + write-reject + unmount |
| `verify` | `check` + `audit` + `smoke` (full validation) |
| `vet` | Parse + type-check with `-vet -vet-shadowing -strict-style` |
| `help` | Print this table |

Configurable: `MOUNTPOINT=/tmp/mnt`, `BUILD_DIR=build`, `ODIN=odin`.

## ABI guarantee

Every cross-FFI struct in `src/fuse3/types.odin` and every on-disk struct in
`src/fs/structure.odin` has a compile-time `#assert(size_of(T) == N)`.  If a
future Odin release or a field reordering causes a size mismatch, the build
fails instead of silently corrupting memory or disk images.

All 12 FUSE struct sizes and all 43 `fuse_operations` field offsets are
cross-checked by `make check`.

## Binding status

Implemented in `src/fuse3/`:
- `fuse_operations` — all 39 callbacks (path-based, high-level API)
- `fuse_file_info`, `fuse_conn_info`, `fuse_config`, `fuse_context`
- `fuse_buf`, `fuse_bufvec`
- `fuse_args`, `fuse_opt`, `fuse_loop_config_v1`
- `fuse_main_real_versioned`, `fuse_version`, `fuse_pkgversion`
- `fuse_get_context`, `fuse_invalidate_path`, `fuse_exit`
- `fuse_set_feature_flag`, `fuse_unset_feature_flag`, `fuse_get_feature_flag`
- `ctx()`, `invalidate()`, `exit()`, `nix()` helpers in `api.odin`

Deferred:
- `fuse_lowlevel.h` (inode-based API — Phase 7)
- Custom `fuse_log_func_t` (can't `va_arg` from Odin)
- macOS / FUSE-T (`#+build linux` only)
