# ADR-008: Error Mapping (FS_Error → errno)

Date: 2026-10-17
Status: accepted

## Context

`FS_Error` mixes not-found, format, allocation, and I/O states. The
audit requires corruption and I/O failures to never collapse into
`ENOENT`/`ENOSPC`, and unsupported operations to be explicit.

## Decision

1. **One central mapper.** `fs_error_to_errno`
   (`src/mounter/core.odin`) is a `#partial switch` over `FS_Error`
   with a `case:` default of `EIO`. Every corruption, format, and
   I/O variant maps to `EIO`; only `Entry_Not_Found → ENOENT`,
   `Not_A_Directory → ENOTDIR`, `Not_A_File → EISDIR`,
   `Name_Too_Long → ENAMETOOLONG`, `No_Space → ENOSPC`, and
   `.None → 0` differ. Adding a variant (e.g. `Corrupt_XAttr_Blob`)
   fails closed to `EIO` with no mapping change.
2. **Direct `nix()` for precondition errors.** Flag and state errors
   that are not `FS_Error` map at the call site: `EEXIST`/`ENODATA`
   for create/replace preconditions, `ERANGE` for undersized
   getxattr/listxattr buffers, `EACCES` for permission denials,
   `ENOTEMPTY` for non-empty rmdir, `ENOSYS` for intentionally
   unsupported ops (`link`, `mknod`, `statx`, `ioctl`).
3. **Absence vs. corruption is distinguished.** `fused_getxattr`
   returns `ENODATA` for a missing name and `EIO` for a load/parse
   failure; `xattr_get` reports them separately so corruption is
   never mistaken for absence. The same discipline applies wherever
   a lookup can fail on I/O: propagate, do not downgrade to
   not-found.
4. **Recovery errors refuse the mount.** `volume_open` returns the
   `journal_recover` error instead of mounting writable on an
   unrecovered image (ADR-001 §7).

## Scope (explicit non-goals)

- No fine-grained I/O taxonomy (`EIO` covers read/write/sync/corrupt).
- No `Transaction_Too_Large` distinct error: oversized transactions
  are chunked (journal_txn bounds tests), not rejected.

## Consequences

- New `FS_Error` variants are safe by default but should still gain
  an explicit row in `test_mount_fs_error_to_errno`.
- Any helper converting I/O errors to booleans must be audited for
  fail-open mapping (storage-audit candidate).

## Tests enforcing this

- `tests/mounter_test.odin:test_mount_fs_error_to_errno`: full
  variant → errno table, including `Corrupt_XAttr_Blob → EIO`.
- `tests/io_error_test.odin`: truncated/read-only images.
- `tests/xattr_test.odin`: corrupt blob → `EIO` at the callback layer
  (`ENODATA` reserved for genuinely missing names).
- `tests/fault_test.odin`: injected I/O errors surface, never downgrade.
