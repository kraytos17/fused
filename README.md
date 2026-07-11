# fused

A FUSE filesystem daemon in Odin with its own cluster-based on-disk format —
backed by a hand-verified, zero-copy libfuse3 binding.

[linux/amd64] [Odin dev-2026-07] [libfuse3 3.18] [MIT]

## Quick start

```sh
make all         # format a 1 MB image, build all binaries, run 9 tests, vet
make mount       # mount read-only at /tmp/fused (passes -f -d to libfuse3)
ls /tmp/fused    # Kernel
cat /tmp/fused/Kernel | head -c4 | od -tx1   # 82000d00
make unmount
```

## Architecture

```
src/disker ──▶ fused.img ──▶ src/fs/        pure logic (no FUSE, no libc)
                               ▲
src/mounter ──▶ src/fuse3/ ────┘             FUSE glue → libfuse3.so
```

| Package | What it does | Dependencies |
|---|---|---|
| `src/fuse3/` | Thin FFI binding to `libfuse3.so`. 39 `fuse_operations` callbacks, 12 cross-FFI structs with compile-time `#assert(size_of)`, 43 callback offsets verified byte-for-byte against C. | `core:c`, `core:sys/posix` |
| `src/fs/` | On-disk format (packed structs with `#assert` invariants), sector I/O, cluster-map and extent-chain navigation, directory iteration, LFN resolution, sector allocator with property-test coverage. No FUSE dependency — testable offline. | `core:os`, `core:io` |
| `src/disker/` | Standalone image formatter. Produces valid `fused.img` files. No `libfuse3` required. | `src:fs` |
| `src/mounter/` | Wires `src/fs/` into `src/fuse3/`. Implements `getattr`, `readdir`, `open`, `read`. Package-level globals `g_disk`/`g_master` hold mount state. `#no_bounds_check` on the inner read loop, `log.debugf` traces on every callback. | `src:fs`, `src:fuse3` |
| `tools/imgdump/` | Read-only image dumper. Walks the MasterRecord, cluster map, ClusterEntry tables, and directory tree — prints everything in human-readable form. | `src:fs` |

## Project layout

```
fused/
├── src/
│   ├── fuse3/                 # libfuse3 binding
│   │   ├── foreign.odin       #   foreign import + foreign block
│   │   ├── constants.odin     #   enums, capability bit_set, version pin
│   │   ├── types.odin         #   12 cross-FFI structs, 43 callback offsets
│   │   └── api.odin           #   Odin wrappers (run, fill_dir, nix, ctx, …)
│   ├── fs/                    # filesystem core — no FUSE dependency
│   │   ├── structure.odin     #   MasterRecord, ClusterEntry, DirectoryEntry, LFN_Pointer
│   │   ├── diskio.odin        #   sector_read / sector_write (checked os.seek)
│   │   ├── validate.odin      #   validate_master, FS_Error enum, FUSED_SIG
│   │   ├── clustermap.odin    #   cluster map + ClusterEntry table read/write
│   │   ├── directory.odin     #   directory entry iteration, entry_short_name, resolve_lfn
│   │   ├── extents.odin       #   resolve_extents chain walker
│   │   └── allocate.odin      #   allocate_sectors + deallocate_sectors
│   ├── disker/                # image formatter (standalone, no libfuse3)
│   │   └── main.odin
│   └── mounter/               # FUSE glue — wires fs/ into fuse3/
│       ├── main.odin          #   opens image, validates, builds ops, fuse3.run
│       └── ops.odin           #   fused_getattr, fused_readdir, fused_open, fused_read
├── tools/
│   └── imgdump/               # image dumper
│       └── main.odin
├── tests/
│   ├── c_assert.c             # C ground-truth sizes & offsets
│   ├── size_check.odin        # Odin-side @test assertions
│   ├── check_sizes.sh         # C vs Odin cross-check (12 structs, 43 offsets)
│   ├── check_context.sh       # audits "c" callbacks for context restoration
│   ├── smoke.sh               # mount + ls + cat + stat + write-reject + unmount
│   ├── fs_test.odin           # read + navigate a golden image
│   └── alloc_test.odin        # 7 allocator property tests
├── demo/
│   └── hello_main.odin        # the original hello-world binding proof
├── Makefile                   # single build entrypoint
├── odinfmt.json
└── ols.json
```

## Build

**Prerequisites:**
- Odin `dev-2026-07-nightly` (or later)
- `fuse3` ≥ 3.18 (`pacman -S fuse3` on Arch)
- Linux kernel with the `fuse` module loaded (`modprobe fuse`)

```sh
make all                   # clean + disker + build + imgdump + run-disker + test + vet
make disker                # build the image formatter → build/disker
make run-disker            # format a default 1 MB image → fused.img
make build                 # build the mounter → build/fused
make imgdump               # build the image dumper → build/imgdump
make release               # aggressive-opt build → build/fused_release
```

## Use

```sh
# Format a disk image
make run-disker
# Custom: ./build/disker --size=4M --cluster-size=16 --output=myfs.img

# Mount read-only
make mount MOUNTPOINT=/tmp/fused
# Or: ./build/fused fused.img -f -d /tmp/fused

# Interact
ls /tmp/fused                # Kernel
stat /tmp/fused/Kernel       # size=60  mode=-r--r--r--
cat /tmp/fused/Kernel        # binary content

# Unmount
make unmount MOUNTPOINT=/tmp/fused
```

## Makefile targets

| Target | Description |
|---|---|
| `all` | `clean` + `disker` + `build` + `imgdump` + `run-disker` + `test` + `vet` |
| `build` | Debug build → `build/fused` |
| `release` | `-o:aggressive -lto:thin -microarch:native` → `build/fused_release` |
| `disker` | Build the image formatter → `build/disker` |
| `run-disker` | Build + format a default 1 MB image → `fused.img` |
| `imgdump` | Build the image dumper → `build/imgdump` |
| `mount` | Build then run against `MOUNTPOINT` |
| `unmount` | `fusermount3 -u MOUNTPOINT` |
| `clean` | Remove `build/`, kill any stale mount |
| `test` | Odin test suite — 9 tests (struct sizes + fs core + allocator) |
| `check` | C vs Odin struct size cross-check (12 structs) |
| `audit` | Audit `proc "c"` callbacks for context restoration |
| `smoke` | Build + mount + `ls` + `cat` + `stat` + write-reject + unmount |
| `verify` | `check` + `audit` + `smoke` |
| `vet` | Parse + type-check with `-vet -vet-shadowing -strict-style` |
| `help` | Print this table |

Configurable: `MOUNTPOINT=/tmp/mnt`, `BUILD_DIR=build`, `ODIN=odin`, `IMAGE=fused.img`.

## ABI guarantees

Every cross-FFI struct in `src/fuse3/types.odin` and every on-disk struct in
`src/fs/structure.odin` carries a compile-time `#assert(size_of(T) == N)`.  Four
additional invariants in `structure.odin` enforce the relationships between
sector size, struct sizes, and entries-per-sector — if any constant drifts, the
build fails instead of silently corrupting images.

All 12 FUSE struct sizes and all 43 `fuse_operations` field offsets are
cross-checked against C at build time by `make check`.
