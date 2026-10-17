# ADR-002: On-Disk Format and Compatibility

Date: 2026-10-17
Status: accepted

## Context

The image format must stay mountable across revisions: readers need
minimum/maximum rules, feature bits need introduction semantics, and
the layout must be validated before any journal sector is touched.

## Decision

1. **Revision window 7–8.** `SUPPORTED_REV_MIN = 7`,
   `SUPPORTED_REV_MAX = 8` (`src/fs/structure.odin`).
   `validate_master` rejects `rev_max < MIN` (too old) and
   `rev_min > MAX` (too new), so a newer writer that raises its
   minimum excludes this reader explicitly.
2. **Feature bits gate layouts.** `Feature_Flag` maps each bit to its
   introducing revision (`Uid_Gid` = rev 5, 56-byte entries;
   `XAttr` = rev 8, 64-byte entries). Unknown bits — including the
   retired rev-7 journal selector — are rejected by u64 comparison, so
   a repurposed bit can never slip through a `bit_set`-level check.
   Directory entry size/count dispatch on features with a V4 fallback
   (`dir_entry_size`, `dir_entries_per_sector`).
3. **Layout is computed, then validated.** `format_geometry` derives
   cluster-map sectors, journal sectors (`max(64, clusters/10)`), and
   reserved clusters from size and cluster size; `validate_master`
   re-checks signature, end signature, cluster size bounds, map offset
   and size, and root location before recovery reads anything.
4. **No silent migration.** There is no upgrade path: rev < 7 images
   (including rev 6 with the removed intent log) are rejected, not
   converted. Adding a feature means adding the flag, listing it in
   `ALL_SUPPORTED_FEATURES`, and bumping `SUPPORTED_REV_MAX`.
5. **Golden fixtures per supported revision.** Fresh formats are
   byte-pinned: `tests/golden_test.odin` formats a deterministic
   scratch image (no demo data — demo entries carry wall-clock
   timestamps) for rev 7 (V5 layouts, no XAttr) and rev 8 (V6/V5
   layouts with XAttr) and compares FNV-1a hashes of the full image
   and of each 64 KiB chunk against stored constants, naming the
   first differing chunk on drift. Any format change must update
   the goldens deliberately (verify the diff is the intended change
   first), never blindly.

## Scope (explicit non-goals)

- No forward compatibility: a rev-9 image is rejected, full stop.
- No repair of geometry violations: `Corrupt_Master_Record` refuses
  the mount.
- Endianness is native little-endian (packed structs); cross-endian
  images are out of scope.

## Consequences

- A format change is a deliberate multi-step act: layout code,
  feature bit, revision bump, validation, and golden fixture
  updates — never just a struct edit.
- Retired bits stay retired: bit 1 must never be reused.

## Tests enforcing this

- `tests/size_check.odin`: struct-size asserts incl. C ABI cross-checks.
- `tests/io_error_test.odin`: truncated images rejected before I/O.
- `tests/golden_test.odin`: byte-goldens for rev 7 and rev 8 fresh
  formats (full + per-chunk hashes) plus a format-twice
  determinism check. Mutation-checked: a one-byte master change
  fails both goldens with chunk localization.
- `make doctor`: master validation on every fresh image.
