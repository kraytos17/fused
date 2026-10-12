# fused — Format Revision History

## Rev 4 (legacy — not parseable by current code)

Single rev byte at offset 7. `Directory_Entry` is 48 bytes (10 per sector).
No uid/gid fields. No `Master_Record.end_sig` sentinel.

The current `Master_Record` layout changed between rev 4 and 5; rev 4
images are rejected by `validate_master` with `.Invalid_Signature`.

## Rev 5 — `Uid_Gid` feature

Introduced `rev_min`/`rev_max` range checking and a `features` bitmask.
Feature flag `.Uid_Gid` (bit 0) grows `Directory_Entry` from 48 to 56
bytes (9 per sector instead of 10), adding uid/gid fields.
`SUPPORTED_REV_MIN = SUPPORTED_REV_MAX = 5`.

## Rev 6 — Intent log

Added `Intent_Log` single-sector crash-consistency journal. Every
multi-write allocation transaction records CE-table entry metadata
before committing, enabling detection of in-flight writes after a crash.
`SUPPORTED_REV_MIN = 6`, `SUPPORTED_REV_MAX = 6`.

## Rev 7 — Journal v2 WAL

Added `Journal_V2` feature flag (bit 1). Replaces the single-sector
intent log with a physical redo-log WAL in a dedicated journal region
(default 64 sectors, configurable at format time). Provides idempotent
automatic replay on mount. `SUPPORTED_REV_MIN = 6`, `SUPPORTED_REV_MAX = 7`.

Rev 7 images can be mounted read/write by the current codebase. (Historically,
rev 6 images were also mountable — code selected the journal path based on
the `Journal_V2` feature flag. The intent log has since been removed; rev 6
images are now rejected. See below.)

## Rev 8 — `XAttr` feature

Added `XAttr` feature flag (bit 2). `Directory_Entry` grows from 56 to
64 bytes (8 entries per sector instead of 9) with a new `xattr_cluster`
field. Extended attributes are serialized into a self-describing blob
(`XAttr_Blob_Header` + length-prefixed name/value records) stored in a
dedicated `.XAttr` cluster chain referenced by `xattr_cluster`.

Allocation and deallocation of xattr chains are journaled through the v2
WAL (deallocation now records a v2 journal entry on v2 images, fixing a
latent bug where freed chains were resurrected by replay on remount).
`SUPPORTED_REV_MIN = 6`, `SUPPORTED_REV_MAX = 8`.

Rev 8 images can be mounted read/write by the current codebase. (Historically,
rev 6/7 images remained mountable — entry sizing and journal path dispatched
on the feature flags. The intent log has since been removed; rev 6 images
are now rejected. See below.)

## Post-rev-8 — intent log removed, WAL is the only journal

The rev-6 single-sector intent log (`Intent_Log`, `Intent_Log_Entry`,
`JOURNAL_MAGIC`) was deleted. `SUPPORTED_REV_MIN = 7`, so rev 6 images fail
validation with `.Version_Too_Old`. The `.Journal_V2` feature flag (bit 1)
was then deleted as well: images carrying it fail validation with
`.Feature_Not_Supported` (the unknown-bit check compares the u64
representation so retired bits stay visible). Reformat to migrate.
`journal_backend_for` was replaced by the `JOURNAL_BACKEND` constant, and all
`journal_v2_*`/`Jv2_*` symbols were renamed to version-neutral
`journal_*`/`Journal_*` names.
