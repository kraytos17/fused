# ADR-006: Permission Model (Constrained)

Date: 2026-10-17
Status: accepted

## Context

`Directory_Entry` stores ownership but no POSIX mode bitmask, while
FUSE clients expect mode/ownership enforcement. The audit asked for an
explicit decision: general-purpose POSIX semantics or a documented
constrained model.

## Decision

Fused implements a **constrained coarse-flag model**, not POSIX modes:

1. **Four deny flags are the whole model.** `No_Read`, `No_Write`,
   `Read_Only`, `No_Execute` on the entry. There is no stored
   owner/group/other matrix and no umask processing.
2. **chmod maps any-of-class.** `fused_chmod` (`src/mounter/misc.odin`)
   clears a deny flag when *any* of the owner/group/other bits for
   that class is present in the requested mode, and sets it otherwise.
   Write clears/sets both `No_Write` and `Read_Only` together.
3. **Enforcement is at open/access/getattr.** `fused_access` denies
   `R_OK` under `No_Read`, `W_OK` under `No_Write`/`Read_Only`, and
   `X_OK` everywhere except searchable directories (`.Directory`
   without `.No_Execute`), mirroring exactly what `getattr` reports;
   `fused_open` denies write opens under `No_Write`/`Read_Only` and
   read opens under `No_Read`; `fused_getattr` derives the display
   mode from fixed per-type profiles minus the denied classes
   (directories additionally lose exec under `No_Execute`; files and
   links never carry exec).
4. **Ownership is recorded, not enforced.** `fused_chown` stores
   uid/gid and is otherwise a no-op. No access decision consults the
   caller UID/GID or supplementary groups; root is not special-cased.
   The kernel does not enforce either: fused passes no
   `default_permissions` flag, so these callbacks are authoritative.
5. **No ACLs, no special files.** Out of scope until mode bits exist
   on disk (requires a format revision).

## Consequences

- `chmod 0600`-style expectations do not hold: setting any read bit
  clears the whole read denial for everyone.
- Permission changes are per-entry flag flips, journaled only insofar
  as directory-entry writes are (see ADR-001 scope: CE metadata only).

## Tests enforcing this

- `tests/mounter_test.odin:test_mount_chmod_access`: chmod mapping,
  `access(R_OK)` → `EACCES` after denial, unlink cleanup.
