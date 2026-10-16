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

fault_setup :: proc(t: ^testing.T) -> (fs.Volume, bool) {
	fd, fok := jtxn_format(t, FAULT_SCRATCH)
	if !fok { return {}, false }
	vol, vok := open_volume_on_fd(fd)
	if !vok { os.close(fd); os.remove(FAULT_SCRATCH); return {}, false }
	return vol, true
}

fault_teardown :: proc(vol: ^fs.Volume) {
	close_test_volume(vol)
	os.remove(FAULT_SCRATCH)
}

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
	vol, ok := fault_setup(t)
	if !ok { return }
	defer fault_teardown(&vol)

	vol.fault = fs.IO_Fault{
		enabled           = true,
		fail_reads_after  = max(u64),
		fail_writes_after = max(u64),
		fail_syncs_after  = 0,
	}
	f0, seq0, wm0 := fault_state(&vol)

	c, o, aerr := fs.allocate_sectors(&vol, {}, 100, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.Sector_Write_Error)
	testing.expect(t, c == 0, "no chain head published")

	f1, seq1, wm1 := fault_state(&vol)
	testing.expect_value(t, f1, f0)
	testing.expect_value(t, seq1, seq0)
	testing.expect_value(t, wm1, wm0)
	testing.expect(t, vol.fault.syncs == 1, "exactly the records sync ran")
	testing.expect(t, vol.fault.writes > 0, "records hit the page cache")
}

// test_fault_write_fails_alloc_clean — the first sector write fails: the
// op fails before persisting anything observable.
@(test)
test_fault_write_fails_alloc_clean :: proc(t: ^testing.T) {
	vol, ok := fault_setup(t)
	if !ok { return }
	defer fault_teardown(&vol)

	vol.fault = fs.IO_Fault{
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

// test_fault_write_fails_dealloc_clean — a write failure mid-deallocation
// leaves the chain fully resolvable and the free count untouched.
@(test)
test_fault_write_fails_dealloc_clean :: proc(t: ^testing.T) {
	vol, ok := fault_setup(t)
	if !ok { return }
	defer fault_teardown(&vol)

	hc, ho, aerr := fs.allocate_sectors(&vol, {}, 10, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }

	vol.fault = fs.IO_Fault{
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
