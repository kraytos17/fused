# ADR-016: Rev-9 Inode Table (Indirection, Links, Stable Identity)

Date: 2026-11-18
Status: accepted (design; implementation pending E-05/E-02)

## Context

Rev 8's `Directory_Entry` is the inode: one packed 64-byte record (8 per
sector, zero slack — `#assert(size_of(Directory_Entry) == 64)`) holding
name, type flags, the data-chain head, uid/gid, timestamps, size, and
the xattr head. This makes four things impossible:

1. **Hard links.** `link` returns EPERM (`src/mounter/misc.odin`, the
   rev-9/Q-01 anchor): two dir entries cannot share one allocation
   identity without an indirection to own the link count.
2. **Stable inode numbers.** `st_ino` is 0; fabricating it from the
   slot is rejected by ADR-003 because the slot moves on
   cross-directory rename.
3. **POSIX mode bits, rdev, ctime.** The entry has no room, and the
   packed date/time format is the wrong shape for nsec.
4. **Per-inode resource identity for the checker and the journal.**
   Reachability and reference validation want a level between dir
   entries and sector chains.

The entry layout machinery was built for exactly this moment:
`Dir_Entry_Layout` binds feature flags to strides, and a rev 9 "adds
one row instead of editing two parallel chains".

## Decision

1. **Rev 9 introduces a per-image inode table.** A dedicated region of
   fixed-size inode records, referenced by inode number. A record owns
   everything per-inode: `nlink`, POSIX `mode`, `rdev`, `uid`, `gid`,
   `size`, `mtime`/`atime`/`ctime` (sec+nsec), the data-chain head,
   and the xattr-chain head. Entries shrink to {type flags, name (16
   inline or LFN pointer), `ino`}.
2. **The 64-byte stride stays.** `Dir_Entry_Layout` gains a row keyed
   by the new `.Inode_Table` feature flag with the same 64-byte /
   8-per-sector geometry; the freed fields become reserved slack for
   future growth. No capacity changes, no new stride math.
3. **Hard links are entries sharing one inode.** `link()` creates a
   dir entry referencing the existing `ino` and bumps `nlink`
   (journalized, like CE writes today). `unlink`/`rmdir` clear the
   slot and decrement; the record is released at `nlink == 0` (data
   chain, xattr chain — the LFN storage is per-ENTRY: the name dies
   with the slot, the inode's resources with the last link). The
   `_release_entry_resources` factoring is the template: entry-level
   release vs inode-level release split the same way.
4. **`st_ino` is the table ino** — stable across rename (slots move,
   inos do not). Directory `nlink` becomes 2 + subdirs.
5. **Real modes on rev-9 images.** chmod/chown write the table record;
   access/open/getattr enforce POSIX semantics. The constrained
   deny-flag model (ADR-006) remains the behavior of rev-8 images and
   is superseded for rev-9 images.
6. **Master_Record grows** `{inode_table_cluster, inode_table_sectors,
   next_ino}` in the rev-9 layout; `validate_master` checks the new
   region like every other (layout computed, then validated). The
   feature flag `.Inode_Table` (bit 3) is required on rev_max ≥ 9.
7. **Table-record writes ride the existing WAL** — a new journal
   record kind for inode updates; allocation/deallocation through the
   journal as CE writes are today. This is the natural anchor for
   E-03's transaction over entry writes (link = one inode record + N
   entry writes).
8. **Checker.** Stage B walks entries → inodes → chains: orphans are
   unreferenced table records (and their chains); new findings:
   ino out of range, nlink ≠ number of referencing entries, mode/rdev
   validation. Repair follows the existing model (ADR-009).
9. **Compatibility.** `SUPPORTED_REV_MAX = 9`, `SUPPORTED_REV_MIN`
   unchanged (7). Rev-8 images mount read-write exactly as today
   (EPERM link, st_ino 0, deny-flag modes); there is no conversion —
   reformat to migrate (ADR-002 #4). Fresh rev-9 formats are
   byte-golden pinned like every revision.

## Consequences

- Resolution gains one hop (entry → inode record → chain), absorbed by
  the dir cache plus a small inode cache; rev-8 paths keep direct
  entry fields, so both decodes live side by side behind the feature
  flag.
- The stale-head class of crash bugs (truncate zero-clear, ADR-013)
  becomes a table-record update with the same crash-order discipline.
- f_fsid stays 0; a volume UUID is a separate decision (E-02 tail).
- Implementation cost is the largest since E-03: table region,
  journal record kind, dual-mode entry decode, checker Stage B
  rewrite, migration goldens.

## Alternatives rejected

- **Entry-is-inode with shared nlink** — a `link()` writes the same
  count into multiple copies; keeping them coherent reopens exactly
  the crash windows M-1 just closed.
- **Wider stride (96/128-byte entries)** — halves directory capacity
  for fields the table houses anyway.
- **Sidecar extension records** — two-level reads for every stat-class
  op and more windows, to avoid one region.
- **Defer hard links again** — the entry stays the inode, stable ino
  stays impossible, and E-01/E-05 keep slipping.
