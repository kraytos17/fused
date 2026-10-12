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

	c, o, aerr := fs.allocate_sectors(&vol, 0, 0, 4, .File_Content)
	testing.expect(t, aerr == fs.FS_Error.None, "allocate ok")
	testing.expect(t, c != 0, "allocated cluster != 0")

	entry, ferr2 := fs.find_cluster_entry(&vol, c, o)
	testing.expect(t, ferr2 == fs.FS_Error.None, "find_cluster_entry ok")
	testing.expect(t, .Allocated in entry.state, "entry allocated")

	_, _, aerr = fs.allocate_sectors(&vol, c, o, 10, .File_Content)
	testing.expect(t, aerr == fs.FS_Error.None, "extend ok")

	derr := fs.deallocate_sectors(&vol, c, o)
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

	// A committed transaction advances seq by one.
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
	testing.expect_value(t, fs.journal_seq_get(&vol.master), fs.Journal_Seq(u64(seq0) + 1))
}
