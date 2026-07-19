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

Rev 7 images can be mounted read/write by the current codebase. Rev 6
images are still mountable (code selects the journal path based on
the `Journal_V2` feature flag).
