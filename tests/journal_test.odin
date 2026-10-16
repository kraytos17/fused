// journal_test.odin — Tests for the journal backend.
//
// The journal (physical redo-log WAL) is the only crash-consistency
// mechanism. These tests drive allocation/deallocation through the backend
// and verify abort/commit seq semantics on the standard rev-8 test image.
#+build linux
package tests

import "core:testing"
import "src:fs"

// test_allocate_deallocate drives allocation and deallocation through
// the backend on the rev-8 (WAL journal) test image.
@(test)
test_allocate_deallocate :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {
		testing.fail(t)
		return
	}
	defer close_test_volume(&vol)

	c, o, aerr := fs.allocate_sectors(&vol, {}, 4, .File_Content)
	testing.expect(t, aerr == fs.FS_Error.None, "allocate ok")
	testing.expect(t, c != 0, "allocated cluster != 0")

	entry, ferr2 := fs.find_cluster_entry(&vol, c, o)
	testing.expect(t, ferr2 == fs.FS_Error.None, "find_cluster_entry ok")
	testing.expect(t, .Allocated in entry.state, "entry allocated")

	_, _, aerr = fs.allocate_sectors(&vol, fs.Chain_Location{c, o}, 10, .File_Content)
	testing.expect(t, aerr == fs.FS_Error.None, "extend ok")

	derr := fs.deallocate_sectors(&vol, fs.Chain_Location{c, o})
	testing.expect(t, derr == fs.FS_Error.None, "deallocate ok")
	_, ferr3 := fs.find_cluster_entry(&vol, c, o)
	testing.expect(t, ferr3 == fs.FS_Error.Entry_Not_Found, "entry freed")
}

// test_backend_abort verifies abort/commit seq semantics: an aborted
// transaction persists nothing (v2 abort is a no-op, so seq is unchanged),
// while a committed transaction advances seq by one.
@(test)
test_backend_abort :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok {
		testing.fail(t)
		return
	}
	defer close_test_volume(&vol)

	seq0 := fs.journal_seq_get(&vol.master)
	w0 := fs.journal_watermark(&vol.master)

	backend := fs.JOURNAL_BACKEND
	h: fs.Journal_Txn_Handle
	testing.expect(t, backend.begin(&vol, &h), "begin")
	backend.add(
		&vol,
		&h,
		fs.journal_entry_from_cluster_entry(
			fs.Cluster_Entry{state = {.Allocated}, allocation_size = 4, sector_start = 2},
			10,
			0,
		),
	)
	backend.abort(&vol, &h)
	testing.expect_value(t, fs.journal_seq_get(&vol.master), seq0)

	// Commit persists the log without advancing; finish checkpoints (seq + watermark).
	backend2 := fs.JOURNAL_BACKEND
	h2: fs.Journal_Txn_Handle
	testing.expect(t, backend2.begin(&vol, &h2), "begin 2")
	backend2.add(
		&vol,
		&h2,
		fs.journal_entry_from_cluster_entry(
			fs.Cluster_Entry{state = {.Allocated}, allocation_size = 4, sector_start = 2},
			11,
			1,
		),
	)
	testing.expect(t, backend2.commit(&vol, &h2), "commit 2")
	testing.expect_value(t, fs.journal_seq_get(&vol.master), seq0)
	testing.expect_value(t, fs.journal_watermark(&vol.master), w0)
	testing.expect(t, backend2.finish(&vol, &h2, true), "finish 2")
	testing.expect_value(t, fs.journal_seq_get(&vol.master), fs.Journal_Seq(u64(seq0) + 1))
	testing.expect_value(t, fs.journal_watermark(&vol.master), u64(seq0))
}

// test_recover_replays_committed_txn verifies crash recovery end to end: a
// committed-but-unapplied journal entry is applied by journal_recover. The
// scratch slot is restored afterwards so the shared test image is
// undisturbed (the ring keeps the committed slot, which later recovers
// would only re-apply idempotently — and no test calls recover).
@(test)
test_recover_replays_committed_txn :: proc(t: ^testing.T) {
	vol, vol_ok := open_test_volume()
	if !vol_ok { testing.fail(t); return }
	defer close_test_volume(&vol)

	// Find a readable table with a zero-state slot to scribble.
	found := false
	empty: fs.Cluster_Entry_State
	s_c: fs.Cluster
	s_j := 0
	saved: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	for ci in 1 ..< int(vol.master.cluster_map_size) {
		table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
		if fs.read_cluster_entry_table(&vol, fs.Cluster(ci), &table) != .None { continue }
		for j in 0 ..< len(table) {
			if table[j].state == empty {
				s_c, s_j, saved, found = fs.Cluster(ci), j, table, true
				break
			}
		}
		if found { break }
	}
	if !found {
		testing.fail(t)
		return
	}

	// Commit (but do not apply) a recognizable entry at the scratch slot.
	crafted := fs.Cluster_Entry {
		state           = {.Allocated},
		allocation_size = 1,
		sector_start    = 0,
	}
	backend := fs.JOURNAL_BACKEND
	h: fs.Journal_Txn_Handle
	testing.expect(t, backend.begin(&vol, &h), "begin")
	testing.expect(
		t,
		backend.add(&vol, &h, fs.journal_entry_from_cluster_entry(crafted, u64(s_c), u8(s_j))),
		"add",
	)
	testing.expect(t, backend.commit(&vol, &h), "commit")
	testing.expect(t, backend.finish(&vol, &h, true), "finish")

	// Pre-condition: the entry is not yet on disk.
	pre: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	testing.expect_value(t, fs.read_cluster_entry_table(&vol, s_c, &pre), fs.FS_Error.None)
	testing.expect(t, pre[s_j].state == empty, "slot untouched before recover")

	fs.journal_recover(&vol)

	after: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	testing.expect_value(t, fs.read_cluster_entry_table(&vol, s_c, &after), fs.FS_Error.None)
	testing.expect(t, after[s_j].state == crafted.state, "replayed state")
	testing.expect_value(t, after[s_j].allocation_size, crafted.allocation_size)

	// Restore the scratch slot; the test image must be undisturbed.
	testing.expect_value(
		t,
		fs.write_cluster_entry_table(&vol, s_c, &saved),
		fs.FS_Error.None,
	)
	check: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	testing.expect_value(t, fs.read_cluster_entry_table(&vol, s_c, &check), fs.FS_Error.None)
	testing.expect(t, check[s_j].state == empty, "slot restored")
}
