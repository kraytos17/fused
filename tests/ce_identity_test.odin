// ce_identity_test.odin — CE slot-identity regression tests.
//
// Freed CE slots retain their old sector_start, so a bare offset lookup
// can match a stale slot ahead of the live entry. Deallocation must clear
// the allocated slot (located via find_cluster_entry's index), never the
// first offset match. Runs on an isolated scratch image.
//
// Layout note: the first data cluster's table holds reserved entries in
// slots 0-1, so the test fills it (14 sectors) and works on the next
// cluster, whose table is fresh and holds only the test entry.
// scope: scratch image
#+build linux
package tests

import "core:os"
import "core:testing"
import "src:fs"

CE_SCRATCH := "/dev/shm/fused_ce_test.img"

// test_deallocate_clears_allocated_slot — with a stale duplicate offset in
// slot 0 and the live entry in slot 1, deallocation must clear slot 1 and
// leave slot 0 untouched (the old re-find cleared slot 0 and leaked slot 1).
@(test)
test_deallocate_clears_allocated_slot :: proc(t: ^testing.T) {
	vol, ok := scratch_volume(t, CE_SCRATCH)
	if !ok { return }
	defer close_scratch_volume(&vol, CE_SCRATCH)

	// Fill the first data cluster; the spillover lands alone in a fresh
	// table at slot 0.
	_, _, aerr := fs.allocate_sectors(&vol, {}, 14, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }
	c, o, berr := fs.allocate_sectors(&vol, {}, 1, .File_Content)
	testing.expect_value(t, berr, fs.FS_Error.None)
	if berr != .None { return }

	live: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	testing.expect_value(t, fs.read_cluster_entry_table(&vol, c, &live), fs.FS_Error.None)
	live_idx := -1
	for i in 0 ..< len(live) {
		if live[i].sector_start == u16(o) && .Allocated in live[i].state {
			live_idx = i
			break
		}
	}
	testing.expect_value(t, live_idx, 0)
	if live_idx != 0 { return }

	// Plant the stale duplicate ahead of the live entry: slot 0 keeps the
	// offset with no Allocated bit (exactly what a freed slot retains),
	// slot 1 holds the live entry.
	crafted := live
	crafted[1] = live[0]
	crafted[0].state -= {.Allocated}
	testing.expect_value(
		t,
		fs.write_cluster_entry_table(&vol, c, &crafted),
		fs.FS_Error.None,
	)

	derr := fs.deallocate_sectors(&vol, fs.Chain_Location{c, o})
	testing.expect_value(t, derr, fs.FS_Error.None)

	after: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	testing.expect_value(t, fs.read_cluster_entry_table(&vol, c, &after), fs.FS_Error.None)
	testing.expect(t, .Allocated not_in after[1].state, "live slot cleared")
	testing.expect(t, after[0] == crafted[0], "stale duplicate untouched")
	_, ferr := fs.find_cluster_entry(&vol, c, o)
	testing.expect_value(t, ferr, fs.FS_Error.Entry_Not_Found)
}
