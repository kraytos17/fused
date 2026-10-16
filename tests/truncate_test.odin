// truncate_test.odin — truncate-at-boundary regression tests.
//
// truncate_chain_at's exact-boundary branch freed the tail twice (the
// second free failed, so shrink reported an error and skipped the size
// update) and left the predecessor linked into the freed tail. Runs on
// an isolated scratch image with a hand-fragmented 3-extent chain:
// A fills three clusters, B takes the next, A is freed, then C
// (36 sectors) spans the freed clusters plus part of B's cluster.
// Entry sizes are read back, not assumed (the first data cluster holds
// reserved sectors).
#+build linux
package tests

import "core:os"
import "core:testing"
import "src:fs"

TRUNC_SCRATCH := "/dev/shm/fused_trunc_test.img"

// trunc_fixture builds the 3-extent chain and returns the head, the
// second/third entry locations, and the first two entry sizes. Cleanup
// on failure is internal; on success the caller owns vol and the file.
trunc_fixture :: proc(
	t: ^testing.T,
) -> (
	vol: fs.Volume,
	chead: fs.Chain_Location,
	e2loc: fs.Chain_Location,
	e3loc: fs.Chain_Location,
	s1: u64,
	s2: u64,
	ok: bool,
) {
	fd, fok := jtxn_format(t, TRUNC_SCRATCH)
	if !fok { return {}, {}, {}, {}, 0, 0, false }
	v, vok := open_volume_on_fd(fd)
	if !vok { os.close(fd); os.remove(TRUNC_SCRATCH); return {}, {}, {}, {}, 0, 0, false }
	fail := false
	afc, afo, aerr := fs.allocate_sectors(&v, {}, 32, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { fail = true }
	_, _, berr := fs.allocate_sectors(&v, {}, 16, .File_Content)
	testing.expect_value(t, berr, fs.FS_Error.None)
	if berr != .None { fail = true }
	if !fail {
		derr := fs.deallocate_sectors(&v, fs.Chain_Location{afc, afo})
		testing.expect_value(t, derr, fs.FS_Error.None)
		if derr != .None { fail = true }
	}
	v.cache.hint = 0
	if !fail {
		chc, cho, cerr := fs.allocate_sectors(&v, {}, 36, .File_Content)
		testing.expect_value(t, cerr, fs.FS_Error.None)
		if cerr != .None { fail = true } else {
			chead = {chc, cho}
			e1, e1err := fs.find_cluster_entry(&v, chc, cho)
			testing.expect_value(t, e1err, fs.FS_Error.None)
			if e1err != .None { fail = true } else {
				s1 = u64(e1.allocation_size)
				e2loc = {fs.Cluster(e1.next_cluster), fs.Sector_Offset(e1.next_sector_index)}
				e2, e2err := fs.find_cluster_entry(&v, e2loc.cluster, e2loc.offset)
				testing.expect_value(t, e2err, fs.FS_Error.None)
				if e2err != .None { fail = true } else {
					s2 = u64(e2.allocation_size)
					e3loc = {fs.Cluster(e2.next_cluster), fs.Sector_Offset(e2.next_sector_index)}
					e3, e3err := fs.find_cluster_entry(&v, e3loc.cluster, e3loc.offset)
					testing.expect_value(t, e3err, fs.FS_Error.None)
					testing.expect(t, e3.next_cluster == 0, "chain ends at e3")
					if e3err != .None || e3.next_cluster != 0 { fail = true } else {
						runs, rerr := fs.resolve_extents(&v, chead)
						defer delete(runs)
						testing.expect_value(t, rerr, fs.FS_Error.None)
						total: u64
						for r in runs { total += u64(r.count) }
						testing.expect_value(t, total, u64(36))
						testing.expect(t, s2 >= 3, "e2 big enough for within-test")
						if rerr != .None || total != 36 || s2 < 3 { fail = true }
					}
				}
			}
		}
	}
	if fail {
		close_test_volume(&v)
		os.remove(TRUNC_SCRATCH)
		return {}, {}, {}, {}, 0, 0, false
	}
	return v, chead, e2loc, e3loc, s1, s2, true
}

// test_truncate_at_extent_boundary — truncating exactly at the second
// extent's start must free the tail once, detach the predecessor, and
// succeed (was: second free failed → spurious error + dangling link).
@(test)
test_truncate_at_extent_boundary :: proc(t: ^testing.T) {
	vol, chead, e2loc, e3loc, s1, _, ok := trunc_fixture(t)
	if !ok { return }
	defer { close_test_volume(&vol); os.remove(TRUNC_SCRATCH) }

	terr := fs.truncate_chain_at(&vol, chead, s1)
	testing.expect_value(t, terr, fs.FS_Error.None)
	if terr != .None { return }

	e1, _ := fs.find_cluster_entry(&vol, chead.cluster, chead.offset)
	testing.expect(t, e1.next_cluster == 0, "predecessor detached")
	_, ferr2 := fs.find_cluster_entry(&vol, e2loc.cluster, e2loc.offset)
	testing.expect_value(t, ferr2, fs.FS_Error.Entry_Not_Found)
	_, ferr3 := fs.find_cluster_entry(&vol, e3loc.cluster, e3loc.offset)
	testing.expect_value(t, ferr3, fs.FS_Error.Entry_Not_Found)

	runs, rerr := fs.resolve_extents(&vol, chead)
	defer delete(runs)
	testing.expect_value(t, rerr, fs.FS_Error.None)
	total: u64
	for r in runs { total += u64(r.count) }
	testing.expect_value(t, total, s1)
}

// test_truncate_within_extent — truncating inside the second extent keeps
// the predecessor link, shrinks the entry, and frees only the tail.
@(test)
test_truncate_within_extent :: proc(t: ^testing.T) {
	vol, chead, e2loc, e3loc, s1, s2, ok := trunc_fixture(t)
	if !ok { return }
	defer { close_test_volume(&vol); os.remove(TRUNC_SCRATCH) }

	terr := fs.truncate_chain_at(&vol, chead, s1 + s2 - 2)
	testing.expect_value(t, terr, fs.FS_Error.None)
	if terr != .None { return }

	e1, _ := fs.find_cluster_entry(&vol, chead.cluster, chead.offset)
	testing.expect(t, u64(e1.next_cluster) == u64(e2loc.cluster), "link to e2 kept")
	testing.expect(t, u16(e1.next_sector_index) == u16(e2loc.offset), "link offset kept")
	e2, _ := fs.find_cluster_entry(&vol, e2loc.cluster, e2loc.offset)
	testing.expect_value(t, e2.allocation_size, u16(s2 - 2))
	testing.expect(t, e2.next_cluster == 0, "tail cut after e2")
	_, ferr3 := fs.find_cluster_entry(&vol, e3loc.cluster, e3loc.offset)
	testing.expect_value(t, ferr3, fs.FS_Error.Entry_Not_Found)

	runs, rerr := fs.resolve_extents(&vol, chead)
	defer delete(runs)
	testing.expect_value(t, rerr, fs.FS_Error.None)
	total: u64
	for r in runs { total += u64(r.count) }
	testing.expect_value(t, total, s1 + s2 - 2)
}

// test_truncate_to_zero_frees_all — truncating to zero frees every entry
// with no predecessor to detach.
@(test)
test_truncate_to_zero_frees_all :: proc(t: ^testing.T) {
	vol, chead, _, _, _, _, ok := trunc_fixture(t)
	if !ok { return }
	defer { close_test_volume(&vol); os.remove(TRUNC_SCRATCH) }

	terr := fs.truncate_chain_at(&vol, chead, 0)
	testing.expect_value(t, terr, fs.FS_Error.None)
	_, ferr := fs.find_cluster_entry(&vol, chead.cluster, chead.offset)
	testing.expect_value(t, ferr, fs.FS_Error.Entry_Not_Found)
}
