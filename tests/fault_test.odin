// fault_test.odin — deterministic fault-injection tests.
//
// The IO_Fault seam (Volume.fault) fails the Nth read/write/sync, proving
// the ADR-001 ordering properties that kill -9 timing cannot target: a
// commit failure must leave home untouched, and a failed op must persist
// nothing uncommitted. Runs on isolated scratch images.
#+build linux
package tests

import "core:os"
import "core:testing"
import "src:fs"

FAULT_SCRATCH := "/dev/shm/fused_fault_test.img"

// fault_state snapshots the externally visible allocation state.
fault_state :: proc(vol: ^fs.Volume) -> (free: u64, seq: u64, wm: u64) {
	free = fs.alloc_cache_count_free(vol)
	seq = u64(fs.journal_seq_get(&vol.master))
	wm = fs.journal_watermark(&vol.master)
	return free, seq, wm
}

// test_fault_sync_fails_alloc_clean — the journal's first sync fails, so
// the commit fails: home must be untouched (no partial allocation, no
// checkpoint advance). Pre-reorder code wrote home first and would have
// orphaned the prefix chain here.
@(test)
test_fault_sync_fails_alloc_clean :: proc(t: ^testing.T) {
	vol, ok := scratch_volume(t, FAULT_SCRATCH)
	if !ok { return }
	defer close_scratch_volume(&vol, FAULT_SCRATCH)

	vol.fault = fs.IO_Fault {
		enabled           = true,
		fail_reads_after  = max(u64),
		fail_writes_after = max(u64),
		fail_syncs_after  = 0,
	}
	f0, seq0, wm0 := fault_state(&vol)

	c, _, aerr := fs.allocate_sectors(&vol, {}, 100, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.Sector_Write_Error)
	testing.expect(t, c == 0, "no chain head published")

	f1, seq1, wm1 := fault_state(&vol)
	testing.expect_value(t, f1, f0)
	testing.expect_value(t, seq1, seq0)
	testing.expect_value(t, wm1, wm0)
	testing.expect(t, vol.fault.syncs == 1, "exactly the records sync ran")
	testing.expect(t, vol.fault.writes > 0, "records hit the page cache")
}

// test_fault_sync_fails_home_sync_holds_watermark — commit and home-apply
// both succeed, but the post-apply durability sync fails: the flush must
// still hold the watermark (the checkpoint must never overtake undurable
// home), and recover must advance it via idempotent re-replay of the
// already-applied chunk.
@(test)
test_fault_sync_fails_home_sync_holds_watermark :: proc(t: ^testing.T) {
	vol, ok := scratch_volume(t, FAULT_SCRATCH)
	if !ok { return }
	defer close_scratch_volume(&vol, FAULT_SCRATCH)

	hc, ho, aerr := fs.allocate_sectors(&vol, {}, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }

	// Single-entry deallocation plan for the head entry.
	table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	idx := -1
	entry, ferr := fs.find_cluster_entry(&vol, hc, ho, &table, &idx)
	testing.expect_value(t, ferr, fs.FS_Error.None)
	if ferr != .None { return }
	cleared_size := u64(entry.allocation_size)
	entry.state -= {.Allocated}
	plan := [1]fs.Journal_Entry{fs.journal_entry_from_cluster_entry(entry, u64(hc), u8(idx))}

	f0, seq0, wm0 := fault_state(&vol)

	// Budget: 1 record + 1 header + 1 home-table write, then the home
	// sync fails. The ignored finish(false) master write counts too.
	vol.fault = fs.IO_Fault {
		enabled           = true,
		fail_reads_after  = max(u64),
		fail_writes_after = max(u64),
		fail_syncs_after  = 2,
	}
	serr := fs.journal_flush_chunk(&vol, plan[:])
	testing.expect_value(t, serr, fs.FS_Error.Sector_Write_Error)
	testing.expect_value(t, vol.fault.writes, u64(4))
	testing.expect_value(t, vol.fault.syncs, u64(3))

	// Watermark held at wm0 (slot preserved: seq advanced once), but the
	// home apply already landed: entry gone, free count exact.
	f1, seq1, wm1 := fault_state(&vol)
	testing.expect_value(t, f1, f0 + cleared_size)
	testing.expect_value(t, seq1, seq0 + 1)
	testing.expect_value(t, wm1, wm0)
	_, rerr := fs.find_cluster_entry(&vol, hc, ho)
	testing.expect_value(t, rerr, fs.FS_Error.Entry_Not_Found)

	// Faults off: recover re-replays idempotently and advances past it.
	vol.fault.enabled = false
	fs.journal_recover(&vol)
	_, seq2, wm2 := fault_state(&vol)
	testing.expect_value(t, seq2, seq1)
	testing.expect_value(t, wm2, seq1)
	_, rerr2 := fs.find_cluster_entry(&vol, hc, ho)
	testing.expect_value(t, rerr2, fs.FS_Error.Entry_Not_Found)
	testing.expect_value(t, fs.alloc_cache_count_free(&vol), f0 + cleared_size)
}

// test_fault_write_fails_alloc_clean — the first sector write fails: the
// op fails before persisting anything observable.
@(test)
test_fault_write_fails_alloc_clean :: proc(t: ^testing.T) {
	vol, ok := scratch_volume(t, FAULT_SCRATCH)
	if !ok { return }
	defer close_scratch_volume(&vol, FAULT_SCRATCH)

	vol.fault = fs.IO_Fault {
		enabled           = true,
		fail_reads_after  = max(u64),
		fail_writes_after = 0,
		fail_syncs_after  = max(u64),
	}
	f0, seq0, wm0 := fault_state(&vol)

	c, o, aerr := fs.allocate_sectors(&vol, {}, 100, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.Sector_Write_Error)
	testing.expect(t, c == 0, "no chain head published")
	_ = o

	f1, seq1, wm1 := fault_state(&vol)
	testing.expect_value(t, f1, f0)
	testing.expect_value(t, seq1, seq0)
	testing.expect_value(t, wm1, wm0)
}

// test_fault_apply_fails_watermark_held — the journal commits durably but
// a home-table write fails: the flush must hold the watermark (seq still
// advances, preserving the slot), and a later recover with faults off must
// complete the chunk from the committed log.
@(test)
test_fault_apply_fails_watermark_held :: proc(t: ^testing.T) {
	vol, ok := scratch_volume(t, FAULT_SCRATCH)
	if !ok { return }
	defer close_scratch_volume(&vol, FAULT_SCRATCH)

	hc, ho, aerr := fs.allocate_sectors(&vol, {}, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }

	// Single-entry deallocation plan for the head entry.
	table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	idx := -1
	entry, ferr := fs.find_cluster_entry(&vol, hc, ho, &table, &idx)
	testing.expect_value(t, ferr, fs.FS_Error.None)
	if ferr != .None { return }
	cleared_size := u64(entry.allocation_size)
	entry.state -= {.Allocated}
	plan := [1]fs.Journal_Entry{fs.journal_entry_from_cluster_entry(entry, u64(hc), u8(idx))}

	f0, seq0, wm0 := fault_state(&vol)

	// Budget: 1 record sector + 1 header sector, then the home-table
	// write fails. Syncs never fail; the ignored finish(false) master
	// write counts as a fourth write.
	vol.fault = fs.IO_Fault {
		enabled           = true,
		fail_reads_after  = max(u64),
		fail_writes_after = 2,
		fail_syncs_after  = max(u64),
	}
	ferr = fs.journal_flush_chunk(&vol, plan[:])
	testing.expect_value(t, ferr, fs.FS_Error.Sector_Write_Error)
	testing.expect_value(t, vol.fault.writes, u64(4))
	testing.expect_value(t, vol.fault.syncs, u64(2))

	// Watermark held at wm0 (slot preserved: seq advanced once).
	// Home untouched: head still allocated, free count unchanged.
	f1, seq1, wm1 := fault_state(&vol)
	testing.expect_value(t, f1, f0)
	testing.expect_value(t, seq1, seq0 + 1)
	testing.expect_value(t, wm1, wm0)
	_, rerr := fs.find_cluster_entry(&vol, hc, ho)
	testing.expect_value(t, rerr, fs.FS_Error.None)

	// Faults off: recover completes the chunk from the committed log.
	vol.fault.enabled = false
	fs.journal_recover(&vol)
	_, _, wm2 := fault_state(&vol)
	testing.expect_value(t, wm2, seq1)
	_, ferr2 := fs.find_cluster_entry(&vol, hc, ho)
	testing.expect_value(t, ferr2, fs.FS_Error.Entry_Not_Found)
	testing.expect_value(t, fs.alloc_cache_count_free(&vol), f0 + cleared_size)
}

// test_fault_apply_fails_twice_recover_both — two committed-but-unapplied
// chunks from separate flushes: recover must replay both in order and
// advance the watermark past both, without disturbing already-applied
// prefix work.
@(test)
test_fault_apply_fails_twice_recover_both :: proc(t: ^testing.T) {
	vol, ok := scratch_volume(t, FAULT_SCRATCH)
	if !ok { return }
	defer close_scratch_volume(&vol, FAULT_SCRATCH)

	hc1, ho1, aerr := fs.allocate_sectors(&vol, {}, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }
	hc2, ho2, berr := fs.allocate_sectors(&vol, {}, 1, .File_Content)
	testing.expect_value(t, berr, fs.FS_Error.None)
	if berr != .None { return }

	// One single-entry deallocation plan per chain head.
	table1: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	idx1 := -1
	entry1, ferr1 := fs.find_cluster_entry(&vol, hc1, ho1, &table1, &idx1)
	testing.expect_value(t, ferr1, fs.FS_Error.None)
	if ferr1 != .None { return }
	size1 := u64(entry1.allocation_size)
	entry1.state -= {.Allocated}
	plan1 := [1]fs.Journal_Entry{fs.journal_entry_from_cluster_entry(entry1, u64(hc1), u8(idx1))}

	table2: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	idx2 := -1
	entry2, ferr2 := fs.find_cluster_entry(&vol, hc2, ho2, &table2, &idx2)
	testing.expect_value(t, ferr2, fs.FS_Error.None)
	if ferr2 != .None { return }
	size2 := u64(entry2.allocation_size)
	entry2.state -= {.Allocated}
	plan2 := [1]fs.Journal_Entry{fs.journal_entry_from_cluster_entry(entry2, u64(hc2), u8(idx2))}

	f0, seq0, wm0 := fault_state(&vol)

	// First chunk: journal commits, home apply fails.
	vol.fault = fs.IO_Fault {
		enabled           = true,
		fail_reads_after  = max(u64),
		fail_writes_after = 2,
		fail_syncs_after  = max(u64),
	}
	jerr1 := fs.journal_flush_chunk(&vol, plan1[:])
	testing.expect_value(t, jerr1, fs.FS_Error.Sector_Write_Error)

	// Second chunk gets a fresh slot and fails the same way; the write
	// budget is relative to the running counter.
	vol.fault.fail_writes_after = vol.fault.writes + 2
	jerr2 := fs.journal_flush_chunk(&vol, plan2[:])
	testing.expect_value(t, jerr2, fs.FS_Error.Sector_Write_Error)

	// Both slots preserved, watermark still held, both heads allocated.
	_, seq1, wm1 := fault_state(&vol)
	testing.expect_value(t, seq1, seq0 + 2)
	testing.expect_value(t, wm1, wm0)
	testing.expect_value(t, fs.alloc_cache_count_free(&vol), f0)
	_, rerr1 := fs.find_cluster_entry(&vol, hc1, ho1)
	testing.expect_value(t, rerr1, fs.FS_Error.None)
	_, rerr2 := fs.find_cluster_entry(&vol, hc2, ho2)
	testing.expect_value(t, rerr2, fs.FS_Error.None)

	// Recover applies both in order and advances past both.
	vol.fault.enabled = false
	fs.journal_recover(&vol)
	_, seq2, wm2 := fault_state(&vol)
	testing.expect_value(t, seq2, seq1)
	testing.expect_value(t, wm2, seq1)
	_, ferr1b := fs.find_cluster_entry(&vol, hc1, ho1)
	testing.expect_value(t, ferr1b, fs.FS_Error.Entry_Not_Found)
	_, ferr2b := fs.find_cluster_entry(&vol, hc2, ho2)
	testing.expect_value(t, ferr2b, fs.FS_Error.Entry_Not_Found)
	testing.expect_value(t, fs.alloc_cache_count_free(&vol), f0 + size1 + size2)
}
// test_fault_write_fails_dealloc_clean — a write failure mid-deallocation
// leaves the chain fully resolvable and the free count untouched.
@(test)
test_fault_write_fails_dealloc_clean :: proc(t: ^testing.T) {
	vol, ok := scratch_volume(t, FAULT_SCRATCH)
	if !ok { return }
	defer close_scratch_volume(&vol, FAULT_SCRATCH)

	hc, ho, aerr := fs.allocate_sectors(&vol, {}, 10, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }

	vol.fault = fs.IO_Fault {
		enabled           = true,
		fail_reads_after  = max(u64),
		fail_writes_after = 0,
		fail_syncs_after  = max(u64),
	}
	f0, seq0, wm0 := fault_state(&vol)

	derr := fs.deallocate_sectors(&vol, fs.Chain_Location{hc, ho})
	testing.expect_value(t, derr, fs.FS_Error.Sector_Write_Error)

	runs, rerr := fs.resolve_extents(&vol, fs.Chain_Location{hc, ho})
	defer delete(runs)
	testing.expect_value(t, rerr, fs.FS_Error.None)
	total: u64
	for r in runs { total += u64(r.count) }
	testing.expect_value(t, total, u64(10))

	f1, seq1, wm1 := fault_state(&vol)
	testing.expect_value(t, f1, f0)
	testing.expect_value(t, seq1, seq0)
	testing.expect_value(t, wm1, wm0)
}

// test_fault_recover_aborts_on_home_write — a committed-but-unapplied
// chunk meets a failing home-table write during recover: replay must
// abort the slot and hold the watermark (not skip it), and a later
// fault-free recover must complete it from the committed log.
@(test)
test_fault_recover_aborts_on_home_write :: proc(t: ^testing.T) {
	vol, ok := scratch_volume(t, FAULT_SCRATCH)
	if !ok { return }
	defer close_scratch_volume(&vol, FAULT_SCRATCH)

	hc, ho, aerr := fs.allocate_sectors(&vol, {}, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }

	// Single-entry deallocation plan, committed but left unapplied by a
	// failed apply (same setup as the flush-path test).
	table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	idx := -1
	entry, ferr := fs.find_cluster_entry(&vol, hc, ho, &table, &idx)
	testing.expect_value(t, ferr, fs.FS_Error.None)
	if ferr != .None { return }
	cleared_size := u64(entry.allocation_size)
	entry.state -= {.Allocated}
	plan := [1]fs.Journal_Entry{fs.journal_entry_from_cluster_entry(entry, u64(hc), u8(idx))}

	// Snapshot the clean baseline before arming faults.
	f0, seq0, wm0 := fault_state(&vol)
	testing.expect_value(t, wm0, seq0 - 1)

	vol.fault = fs.IO_Fault {
		enabled           = true,
		fail_reads_after  = max(u64),
		fail_writes_after = 2,
		fail_syncs_after  = max(u64),
	}
	ferr = fs.journal_flush_chunk(&vol, plan[:])
	testing.expect_value(t, ferr, fs.FS_Error.Sector_Write_Error)
	testing.expect_value(t, vol.fault.writes, u64(4))

	// Recover with the replay's home-table write faulted: scan and record
	// reads succeed, the apply write is the next one and fails.
	vol.fault.fail_writes_after = vol.fault.writes
	// The checkpoint write fails too (writes armed): recover reports it,
	// but the in-memory hold still stands for the asserts below.
	recerr := fs.journal_recover(&vol)
	testing.expect_value(t, recerr, fs.FS_Error.Sector_Write_Error)

	// Watermark advanced past the already-checkpointed prefix but stopped
	// before the unapplied chunk; home untouched, free count unchanged.
	// (seq is untouched by recover; it advanced once at flush time.)
	_, seq1, wm1 := fault_state(&vol)
	testing.expect_value(t, seq1, seq0 + 1)
	testing.expect_value(t, wm1, seq0)
	testing.expect_value(t, vol.fault.writes, u64(6))
	_, rerr := fs.find_cluster_entry(&vol, hc, ho)
	testing.expect_value(t, rerr, fs.FS_Error.None)
	testing.expect_value(t, fs.alloc_cache_count_free(&vol), f0)

	// Faults off: recover completes the chunk from the committed log.
	vol.fault.enabled = false
	fs.journal_recover(&vol)
	_, seq2, wm2 := fault_state(&vol)
	testing.expect_value(t, seq2, seq1)
	testing.expect_value(t, wm2, seq1)
	_, rerr2 := fs.find_cluster_entry(&vol, hc, ho)
	testing.expect_value(t, rerr2, fs.FS_Error.Entry_Not_Found)
	testing.expect_value(t, fs.alloc_cache_count_free(&vol), f0 + cleared_size)
}

// test_fault_finish_fails_master_write_recovers_clean — home is applied
// and durable, but the checkpoint write fails: the flush must still
// report the error, and after remount (stale on-disk checkpoint) recover
// must converge idempotently without double-applying.
@(test)
test_fault_finish_fails_master_write_recovers_clean :: proc(t: ^testing.T) {
	vol, ok := scratch_volume(t, FAULT_SCRATCH)
	if !ok { return }
	defer close_scratch_volume(&vol, FAULT_SCRATCH)

	hc, ho, aerr := fs.allocate_sectors(&vol, {}, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }

	// Single-entry deallocation plan, as in the sibling tests.
	table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	idx := -1
	entry, ferr := fs.find_cluster_entry(&vol, hc, ho, &table, &idx)
	testing.expect_value(t, ferr, fs.FS_Error.None)
	if ferr != .None { return }
	cleared_size := u64(entry.allocation_size)
	entry.state -= {.Allocated}
	plan := [1]fs.Journal_Entry{fs.journal_entry_from_cluster_entry(entry, u64(hc), u8(idx))}

	f0, seq0, wm0 := fault_state(&vol)
	testing.expect_value(t, wm0, seq0 - 1)

	// Budget: 1 record + 1 header + 1 home-table write, then the master
	// write inside finish fails. In-memory state still advances.
	vol.fault = fs.IO_Fault {
		enabled           = true,
		fail_reads_after  = max(u64),
		fail_writes_after = 3,
		fail_syncs_after  = max(u64),
	}
	serr := fs.journal_flush_chunk(&vol, plan[:])
	testing.expect_value(t, serr, fs.FS_Error.Sector_Write_Error)
	testing.expect_value(t, vol.fault.writes, u64(4))
	testing.expect_value(t, vol.fault.syncs, u64(3))

	// Home is applied (entry gone, free count exact) and the checkpoint
	// advanced in memory — but nothing reached the master record.
	_, seq1, wm1 := fault_state(&vol)
	testing.expect_value(t, seq1, seq0 + 1)
	testing.expect_value(t, wm1, wm0 + 1)
	_, rerr := fs.find_cluster_entry(&vol, hc, ho)
	testing.expect_value(t, rerr, fs.FS_Error.Entry_Not_Found)
	testing.expect_value(t, fs.alloc_cache_count_free(&vol), f0 + cleared_size)

	// Remount: the on-disk checkpoint is stale (pre-flush seq/wm).
	close_test_volume(&vol)
	fd2, oerr := os.open(FAULT_SCRATCH, {.Read, .Write})
	testing.expect_value(t, oerr, nil)
	if oerr != nil { return }
	vol, ok = open_volume_on_fd(fd2)
	testing.expect_value(t, ok, true)
	if !ok { os.close(fd2); return }
	d0, seqd, wmd := fault_state(&vol)
	testing.expect_value(t, seqd, seq0)
	testing.expect_value(t, wmd, wm0)
	testing.expect_value(t, d0, f0 + cleared_size)

	// Recover converges idempotently from the committed log: no
	// double-apply, watermark advances past the chunk.
	fs.journal_recover(&vol)
	_, seq2, wm2 := fault_state(&vol)
	testing.expect_value(t, seq2, seqd)
	testing.expect_value(t, wm2, seqd + 1)
	_, rerr2 := fs.find_cluster_entry(&vol, hc, ho)
	testing.expect_value(t, rerr2, fs.FS_Error.Entry_Not_Found)
	testing.expect_value(t, fs.alloc_cache_count_free(&vol), f0 + cleared_size)
}

// test_fault_recover_aborts_on_record_read — a committed-but-unapplied
// chunk meets a failing record-sector read during recover: replay must
// abort the slot and hold the watermark (not skip the rest of the slot),
// and a later fault-free recover must complete it from the committed log.
@(test)
test_fault_recover_aborts_on_record_read :: proc(t: ^testing.T) {
	vol, ok := scratch_volume(t, FAULT_SCRATCH)
	if !ok { return }
	defer close_scratch_volume(&vol, FAULT_SCRATCH)

	hc, ho, aerr := fs.allocate_sectors(&vol, {}, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }

	// Single-entry deallocation plan, committed but left unapplied by a
	// failed apply (same setup as the flush-path tests).
	table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	idx := -1
	entry, ferr := fs.find_cluster_entry(&vol, hc, ho, &table, &idx)
	testing.expect_value(t, ferr, fs.FS_Error.None)
	if ferr != .None { return }
	cleared_size := u64(entry.allocation_size)
	entry.state -= {.Allocated}
	plan := [1]fs.Journal_Entry{fs.journal_entry_from_cluster_entry(entry, u64(hc), u8(idx))}

	f0, seq0, wm0 := fault_state(&vol)
	testing.expect_value(t, wm0, seq0 - 1)

	// Commit the chunk, fail the home-table write: logged but unapplied,
	// watermark held, seq advanced once.
	vol.fault = fs.IO_Fault{
		enabled           = true,
		fail_reads_after  = max(u64),
		fail_writes_after = 2,
		fail_syncs_after  = max(u64),
	}
	jerr := fs.journal_flush_chunk(&vol, plan[:])
	testing.expect_value(t, jerr, fs.FS_Error.Sector_Write_Error)
	testing.expect_value(t, vol.fault.writes, u64(4))
	testing.expect_value(t, vol.fault.syncs, u64(2))

	// Recover with the replay's record-sector read faulted: scan and
	// record reads succeed, the apply write is the next one and fails.
	R0 := vol.fault.reads
	W0 := vol.fault.writes
	M := fs.journal_region_size(&vol.master)
	// Budget: M scan reads + old record read + old table read (CME +
	// sector); the unapplied chunk's record read is the first failure.
	vol.fault.fail_reads_after = R0 + M + 3
	// The checkpoint write fails too (writes still armed from the flush):
	// recover reports it, but the in-memory hold stands.
	recerr := fs.journal_recover(&vol)
	testing.expect_value(t, recerr, fs.FS_Error.Sector_Write_Error)
	testing.expect_value(t, vol.fault.reads, R0 + M + 4)
	testing.expect_value(t, vol.fault.writes, W0 + 1)
	vol.fault.fail_reads_after = max(u64)

	// Watermark advanced past the already-checkpointed prefix but stopped
	// before the unapplied chunk; home untouched, free count unchanged.
	// (seq is untouched by recover; it advanced once at flush time.)
	_, seq1, wm1 := fault_state(&vol)
	testing.expect_value(t, seq1, seq0 + 1)
	testing.expect_value(t, wm1, seq0)
	_, rerr := fs.find_cluster_entry(&vol, hc, ho)
	testing.expect_value(t, rerr, fs.FS_Error.None)
	testing.expect_value(t, fs.alloc_cache_count_free(&vol), f0)

	// Faults off: recover completes the chunk from the committed log.
	vol.fault.enabled = false
	fs.journal_recover(&vol)
	_, seq2, wm2 := fault_state(&vol)
	testing.expect_value(t, seq2, seq1)
	testing.expect_value(t, wm2, seq1)
	_, rerr2 := fs.find_cluster_entry(&vol, hc, ho)
	testing.expect_value(t, rerr2, fs.FS_Error.Entry_Not_Found)
	testing.expect_value(t, fs.alloc_cache_count_free(&vol), f0 + cleared_size)
}

// test_fault_recover_aborts_on_home_read — a committed-but-unapplied
// chunk meets a failing home-table read during recover: replay must
// abort the slot and hold the watermark (not skip the rest of the slot),
// and a later fault-free recover must complete it from the committed log.
@(test)
test_fault_recover_aborts_on_home_read :: proc(t: ^testing.T) {
	vol, ok := scratch_volume(t, FAULT_SCRATCH)
	if !ok { return }
	defer close_scratch_volume(&vol, FAULT_SCRATCH)

	hc, ho, aerr := fs.allocate_sectors(&vol, {}, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }

	// Single-entry deallocation plan, committed but left unapplied by a
	// failed apply (same setup as the flush-path tests).
	table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	idx := -1
	entry, ferr := fs.find_cluster_entry(&vol, hc, ho, &table, &idx)
	testing.expect_value(t, ferr, fs.FS_Error.None)
	if ferr != .None { return }
	cleared_size := u64(entry.allocation_size)
	entry.state -= {.Allocated}
	plan := [1]fs.Journal_Entry{fs.journal_entry_from_cluster_entry(entry, u64(hc), u8(idx))}

	f0, seq0, wm0 := fault_state(&vol)
	testing.expect_value(t, wm0, seq0 - 1)

	// Commit the chunk, fail the home-table write: logged but unapplied,
	// watermark held, seq advanced once.
	vol.fault = fs.IO_Fault{
		enabled           = true,
		fail_reads_after  = max(u64),
		fail_writes_after = 2,
		fail_syncs_after  = max(u64),
	}
	jerr := fs.journal_flush_chunk(&vol, plan[:])
	testing.expect_value(t, jerr, fs.FS_Error.Sector_Write_Error)
	testing.expect_value(t, vol.fault.writes, u64(4))
	testing.expect_value(t, vol.fault.syncs, u64(2))

	// Recover with the replay's home-table sector read faulted: scan,
	// old record/table, and new record/CME reads succeed; the new slot's
	// table-sector read is the first failure.
	// Budget: M scan + old rec + old CME + old table + new rec + new CME.
	R0 := vol.fault.reads
	W0 := vol.fault.writes
	M := fs.journal_region_size(&vol.master)
	vol.fault.fail_reads_after = R0 + M + 5
	// The checkpoint write fails too (writes still armed from the flush):
	// recover reports it, but the in-memory hold stands.
	recerr := fs.journal_recover(&vol)
	testing.expect_value(t, recerr, fs.FS_Error.Sector_Write_Error)
	testing.expect_value(t, vol.fault.reads, R0 + M + 6)
	testing.expect_value(t, vol.fault.writes, W0 + 1)
	vol.fault.fail_reads_after = max(u64)

	// Watermark advanced past the already-checkpointed prefix but stopped
	// before the unapplied chunk; home untouched, free count unchanged.
	// (seq is untouched by recover; it advanced once at flush time.)
	_, seq1, wm1 := fault_state(&vol)
	testing.expect_value(t, seq1, seq0 + 1)
	testing.expect_value(t, wm1, seq0)
	_, rerr := fs.find_cluster_entry(&vol, hc, ho)
	testing.expect_value(t, rerr, fs.FS_Error.None)
	testing.expect_value(t, fs.alloc_cache_count_free(&vol), f0)

	// Faults off: recover completes the chunk from the committed log.
	vol.fault.enabled = false
	fs.journal_recover(&vol)
	_, seq2, wm2 := fault_state(&vol)
	testing.expect_value(t, seq2, seq1)
	testing.expect_value(t, wm2, seq1)
	_, rerr2 := fs.find_cluster_entry(&vol, hc, ho)
	testing.expect_value(t, rerr2, fs.FS_Error.Entry_Not_Found)
	testing.expect_value(t, fs.alloc_cache_count_free(&vol), f0 + cleared_size)
}

// test_fault_commit_header_write_leaves_nothing — the commit's record
// write lands but the header write fails: the flush must report the
// error with home untouched, seq/watermark unmoved (no slot was
// committed), and a later recover must be a no-op for the torn chunk
// (the header slot carries no magic, so the scan skips it).
@(test)
test_fault_commit_header_write_leaves_nothing :: proc(t: ^testing.T) {
	vol, ok := scratch_volume(t, FAULT_SCRATCH)
	if !ok { return }
	defer close_scratch_volume(&vol, FAULT_SCRATCH)

	hc, ho, aerr := fs.allocate_sectors(&vol, {}, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }

	// Single-entry deallocation plan, as in the sibling tests.
	table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	idx := -1
	entry, ferr := fs.find_cluster_entry(&vol, hc, ho, &table, &idx)
	testing.expect_value(t, ferr, fs.FS_Error.None)
	if ferr != .None { return }
	entry.state -= {.Allocated}
	plan := [1]fs.Journal_Entry{fs.journal_entry_from_cluster_entry(entry, u64(hc), u8(idx))}

	f0, seq0, wm0 := fault_state(&vol)
	testing.expect_value(t, wm0, seq0 - 1)

	// Budget: 1 record write lands, the records sync lands, then the
	// header write fails. Home is never touched; no finish runs.
	vol.fault = fs.IO_Fault{
		enabled           = true,
		fail_reads_after  = max(u64),
		fail_writes_after = 1,
		fail_syncs_after  = max(u64),
	}
	jerr := fs.journal_flush_chunk(&vol, plan[:])
	testing.expect_value(t, jerr, fs.FS_Error.Sector_Write_Error)
	testing.expect_value(t, vol.fault.writes, u64(2))
	testing.expect_value(t, vol.fault.syncs, u64(1))

	// Nothing committed: seq/watermark unmoved, home untouched.
	_, seq1, wm1 := fault_state(&vol)
	testing.expect_value(t, seq1, seq0)
	testing.expect_value(t, wm1, wm0)
	_, rerr := fs.find_cluster_entry(&vol, hc, ho)
	testing.expect_value(t, rerr, fs.FS_Error.None)
	testing.expect_value(t, fs.alloc_cache_count_free(&vol), f0)

	// Faults off: recover replays only the older checkpointed prefix
	// idempotently; the torn chunk leaves no trace (home still present,
	// free count unchanged, watermark past the old slot only).
	vol.fault.enabled = false
	fs.journal_recover(&vol)
	_, seq2, wm2 := fault_state(&vol)
	testing.expect_value(t, seq2, seq0)
	testing.expect_value(t, wm2, seq0)
	_, rerr2 := fs.find_cluster_entry(&vol, hc, ho)
	testing.expect_value(t, rerr2, fs.FS_Error.None)
	testing.expect_value(t, fs.alloc_cache_count_free(&vol), f0)
}

// test_fault_recover_scan_read_error_fails — a journal-region header
// that cannot be READ is a disk failure, not an empty slot: recover
// must return the error with the watermark unmoved (the committed set
// is unknowable, so scanning past is unsound), and a later fault-free
// recover must converge from the log.
@(test)
test_fault_recover_scan_read_error_fails :: proc(t: ^testing.T) {
	vol, ok := scratch_volume(t, FAULT_SCRATCH)
	if !ok { return }
	defer close_scratch_volume(&vol, FAULT_SCRATCH)

	hc, ho, aerr := fs.allocate_sectors(&vol, {}, 1, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }

	// Single-entry deallocation plan, committed but left unapplied by a
	// failed apply (same setup as the flush-path tests).
	table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	idx := -1
	entry, ferr := fs.find_cluster_entry(&vol, hc, ho, &table, &idx)
	testing.expect_value(t, ferr, fs.FS_Error.None)
	if ferr != .None { return }
	cleared_size := u64(entry.allocation_size)
	entry.state -= {.Allocated}
	plan := [1]fs.Journal_Entry{fs.journal_entry_from_cluster_entry(entry, u64(hc), u8(idx))}

	f0, seq0, wm0 := fault_state(&vol)
	testing.expect_value(t, wm0, seq0 - 1)

	// Commit the chunk, fail the home-table write: logged but unapplied,
	// watermark held, seq advanced once.
	vol.fault = fs.IO_Fault{
		enabled           = true,
		fail_reads_after  = max(u64),
		fail_writes_after = 2,
		fail_syncs_after  = max(u64),
	}
	jerr := fs.journal_flush_chunk(&vol, plan[:])
	testing.expect_value(t, jerr, fs.FS_Error.Sector_Write_Error)
	testing.expect_value(t, vol.fault.writes, u64(4))
	testing.expect_value(t, vol.fault.syncs, u64(2))

	// Fail the very first scan header read: no slot may be trusted.
	R0 := vol.fault.reads
	W0 := vol.fault.writes
	vol.fault.fail_reads_after = R0
	recerr := fs.journal_recover(&vol)
	testing.expect_value(t, recerr, fs.FS_Error.Sector_Read_Error)
	testing.expect_value(t, vol.fault.reads, R0 + 1)
	testing.expect_value(t, vol.fault.writes, W0)
	vol.fault.fail_reads_after = max(u64)

	// Nothing replayed, watermark unmoved, home untouched.
	_, seq1, wm1 := fault_state(&vol)
	testing.expect_value(t, seq1, seq0 + 1)
	testing.expect_value(t, wm1, wm0)
	_, rerr := fs.find_cluster_entry(&vol, hc, ho)
	testing.expect_value(t, rerr, fs.FS_Error.None)
	testing.expect_value(t, fs.alloc_cache_count_free(&vol), f0)

	// Faults off: recover converges from the committed log.
	vol.fault.enabled = false
	fs.journal_recover(&vol)
	_, seq2, wm2 := fault_state(&vol)
	testing.expect_value(t, seq2, seq1)
	testing.expect_value(t, wm2, seq1)
	_, rerr2 := fs.find_cluster_entry(&vol, hc, ho)
	testing.expect_value(t, rerr2, fs.FS_Error.Entry_Not_Found)
	testing.expect_value(t, fs.alloc_cache_count_free(&vol), f0 + cleared_size)
}
