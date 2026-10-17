# ADR-003: File Identity (Directory Slots, No Stable Nodes)

Date: 2026-10-17
Status: accepted (current schema; persistent identity deferred)

## Context

FUSE hands out `fi.fh` on open and passes it back on every I/O. The
identity behind that handle determines what open-unlink, rename, and
slot-reuse mean. A persistent inode scheme would enable hard links and
POSIX open-file semantics but costs a format revision.

## Decision

1. **Handles name directory slots, not files.** `File_Handle` is a
   `bit_field` packing `{dir_cluster, dir_offset, entry_index}`
   (`src/fs/volume.odin`); `read_entry_from_fh` re-resolves the slot's
   *current* content on every use. There is no generation, epoch, or
   open-file table: no `File_Node`, no reference counts.
2. **Open-unlink is not POSIX.** Unlink/rename frees the chain and
   clears the slot; an already-open handle keeps referring to the
   slot, i.e. to whatever (if anything) occupies it afterwards. This
   is documented incompleteness, not a bug to work around with entry
   copying.
3. **No hard links.** `fused_link` returns `ENOSYS`. Links cannot be
   bolted on by duplicating directory entries: unlink would free data
   still referenced by the other name, with no link count to mediate.
4. **Rename moves the slot's content, not the identity.** Handles
   opened before a rename resolve the old slot (now cleared or reused),
   not the moved file.

## Scope (explicit non-goals)

- No stable on-disk IDs, no link counts, no generations in this
  format revision.
- No deferred reclamation: storage is freed at unlink/rename time
  even with open handles.

## Consequences

- Callers must not hold `fi.fh` across unlink/rename and expect the
  same file; the support matrix states open-unlink as unsupported.
- A future persistent-identity revision needs a new ADR (layout,
  migration, link-count semantics) before any `link()` work starts.

## Tests enforcing this

- Slot-identity is covered indirectly by `test_ce_identity` (table
  slot semantics) and the handle round-trip paths in
  `tests/mounter_test.odin`; there is deliberately no open-unlink
  preservation test, because the behavior is not promised.
