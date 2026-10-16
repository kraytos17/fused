// journal_txn_test.odin — journal transaction-bounds regression tests.
//
// Runs on isolated freshly formatted scratch images (never the shared
// image): journal commits advance seq/watermark and leave ring slots
// behind, so these tests must not pollute shared state.
#+build linux
package tests

import "core:os"
import "core:testing"
import "src:fs"

JTXN_SCRATCH := "/dev/shm/fused_jtxn_test.img"

// jtxn_format creates a fresh 1M scratch image at path and returns the
// open handle. Ownership passes to the caller.
jtxn_format :: proc(t: ^testing.T, path: string) -> (^os.File, bool) {
	fd, ferr := os.open(path, {.Read, .Write, .Create, .Trunc})
	testing.expect_value(t, ferr, nil)
	if ferr != nil { return {}, false }
	ferr2 := fs.format_image(
		fd,
		{
			size = 1 << 20,
			cluster_size = 16,
			features = fs.Features{.Uid_Gid, .XAttr},
			rev_min = 8,
			rev_max = 8,
			demo_data = {},
		},
	)
	testing.expect_value(t, ferr2, fs.FS_Error.None)
	if ferr2 != .None { os.close(fd); return {}, false }
	return fd, true
}

// bytes_equal compares two byte slices without extra imports.
bytes_equal :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) {
		if a[i] != b[i] { return false }
	}
	return true
}

// jtxn_find_header scans the journal region for a header with the given
// sequence number. Layout-agnostic: it finds the slot under either ring
// placement, so the overlap test discriminates before and after the fix.
jtxn_find_header :: proc(vol: ^fs.Volume, seq: u64) -> (fs.Sector, bool) {
	J := fs.journal_region_base(&vol.master)
	M := fs.journal_region_size(&vol.master)
	for i: u64 = 0; i < M; i += 1 {
		pos := J + fs.Sector(i)
		hdr_buf: [fs.SECTOR_SIZE]u8
		if fs.sector_read(vol, pos, hdr_buf[:]) != .None { continue }
		hdr := (^fs.Journal_Header)(raw_data(hdr_buf[:]))^
		if hdr.magic != fs.JOURNAL_WAL_MAGIC { continue }
		if u64(hdr.seq) == seq { return pos, true }
	}
	return 0, false
}

// test_journal_slots_do_not_overlap — a maximum-size transaction's record
// sectors must survive the next commit. Ring positions were computed as
// seq % M with records at pos+1.., so the next header overwrote the
// previous transaction's first record sector.
@(test)
test_journal_slots_do_not_overlap :: proc(t: ^testing.T) {
	fd, ok := jtxn_format(t, JTXN_SCRATCH)
	if !ok { return }
	vol, vok := open_volume_on_fd(fd)
	if !vok { os.close(fd); os.remove(JTXN_SCRATCH); return }
	defer { close_test_volume(&vol); os.remove(JTXN_SCRATCH) }

	seq1 := u64(fs.journal_seq_get(&vol.master))
	backend := fs.JOURNAL_BACKEND
	h1: fs.Journal_Txn_Handle
	testing.expect(t, backend.begin(&vol, &h1), "begin max txn")
	for i in 0 ..< fs.MAX_JOURNAL_ENTRIES {
		ce := fs.Cluster_Entry{state = {.Allocated}, allocation_size = 1, sector_start = u16(i)}
		testing.expect(
			t,
			backend.add(&vol, &h1, fs.journal_entry_from_cluster_entry(ce, u64(1000 + i), u8(i % 32))),
			"add fills",
		)
	}
	testing.expect(t, backend.commit(&vol, &h1), "commit max txn")

	pos1, pok := jtxn_find_header(&vol, seq1)
	testing.expect(t, pok, "txn1 header found")
	if !pok { return }
	snap0: [fs.SECTOR_SIZE]u8
	snap1: [fs.SECTOR_SIZE]u8
	testing.expect_value(t, fs.sector_read(&vol, pos1 + 1, snap0[:]), fs.FS_Error.None)
	testing.expect_value(t, fs.sector_read(&vol, pos1 + 2, snap1[:]), fs.FS_Error.None)

	h2: fs.Journal_Txn_Handle
	testing.expect(t, backend.begin(&vol, &h2), "begin small txn")
	ce2 := fs.Cluster_Entry{state = {.Allocated}, allocation_size = 1, sector_start = 7}
	testing.expect(
		t,
		backend.add(&vol, &h2, fs.journal_entry_from_cluster_entry(ce2, 2000, 3)),
		"add small",
	)
	testing.expect(t, backend.commit(&vol, &h2), "commit small txn")

	after0: [fs.SECTOR_SIZE]u8
	after1: [fs.SECTOR_SIZE]u8
	testing.expect_value(t, fs.sector_read(&vol, pos1 + 1, after0[:]), fs.FS_Error.None)
	testing.expect_value(t, fs.sector_read(&vol, pos1 + 2, after1[:]), fs.FS_Error.None)
	testing.expect(t, bytes_equal(snap0[:], after0[:]), "record sector 0 intact")
	testing.expect(t, bytes_equal(snap1[:], after1[:]), "record sector 1 intact")
}

// test_journal_replay_stops_at_first_incomplete — txn N carries an entry
// whose target table is unreadable; txn N+1 is valid. Recovery must not
// apply N+1 past the incomplete N, and the watermark must hold at N.
@(test)
test_journal_replay_stops_at_first_incomplete :: proc(t: ^testing.T) {
	fd, ok := jtxn_format(t, JTXN_SCRATCH)
	if !ok { return }
	vol, vok := open_volume_on_fd(fd)
	if !vok { os.close(fd); os.remove(JTXN_SCRATCH); return }
	defer { close_test_volume(&vol); os.remove(JTXN_SCRATCH) }

	empty: fs.Cluster_Entry_State
	s_c: fs.Cluster
	s_j := 0
	found := false
	for ci in 1 ..< int(vol.master.cluster_map_size) {
		table: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
		if fs.read_cluster_entry_table(&vol, fs.Cluster(ci), &table) != .None { continue }
		for j in 0 ..< len(table) {
			if table[j].state == empty {
				s_c, s_j, found = fs.Cluster(ci), j, true
				break
			}
		}
		if found { break }
	}
	testing.expect(t, found, "scratch slot found")
	if !found { return }

	seqN := u64(fs.journal_seq_get(&vol.master))
	backend := fs.JOURNAL_BACKEND
	hn: fs.Journal_Txn_Handle
	testing.expect(t, backend.begin(&vol, &hn), "begin N")
	bad := fs.Cluster_Entry{state = {.Allocated}, allocation_size = 1}
	testing.expect(
		t,
		backend.add(&vol, &hn, fs.journal_entry_from_cluster_entry(bad, u64(0xFFFFFFFF), 0)),
		"add bad",
	)
	testing.expect(t, backend.commit(&vol, &hn), "commit N")

	hv: fs.Journal_Txn_Handle
	testing.expect(t, backend.begin(&vol, &hv), "begin N+1")
	good := fs.Cluster_Entry{state = {.Allocated}, allocation_size = 1, sector_start = 0}
	testing.expect(
		t,
		backend.add(&vol, &hv, fs.journal_entry_from_cluster_entry(good, u64(s_c), u8(s_j))),
		"add good",
	)
	testing.expect(t, backend.commit(&vol, &hv), "commit N+1")

	// Simulate the crash window: both transactions still need replay.
	fs.journal_set_watermark(&vol.master, u64(seqN))
	testing.expect_value(t, fs.write_master_record(&vol), fs.FS_Error.None)

	fs.journal_recover(&vol)

	after: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	testing.expect_value(t, fs.read_cluster_entry_table(&vol, s_c, &after), fs.FS_Error.None)
	testing.expect(t, after[s_j].state == empty, "N+1 not replayed past incomplete N")
	testing.expect_value(t, fs.journal_watermark(&vol.master), u64(seqN))
}

// test_journal_chunks_large_allocations — 600 sectors at 16/cluster needs
// ~75 journal entries, past MAX_JOURNAL_ENTRIES (34). The allocator must
// commit in bounded chunks (seq advances more than once), not silently
// journal a prefix of the transaction.
@(test)
test_journal_chunks_large_allocations :: proc(t: ^testing.T) {
	fd, ok := jtxn_format(t, JTXN_SCRATCH)
	if !ok { return }
	vol, vok := open_volume_on_fd(fd)
	if !vok { os.close(fd); os.remove(JTXN_SCRATCH); return }
	defer { close_test_volume(&vol); os.remove(JTXN_SCRATCH) }

	seq0 := u64(fs.journal_seq_get(&vol.master))
	c, o, aerr := fs.allocate_sectors(&vol, {}, 600, .File_Content)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return }
	testing.expect(t, c != 0, "allocated")
	seq1 := u64(fs.journal_seq_get(&vol.master))
	testing.expect(t, seq1 - seq0 >= 2, "large alloc commits multiple journal txns")

	runs, rerr := fs.resolve_extents(&vol, fs.Chain_Location{c, o})
	defer delete(runs)
	testing.expect_value(t, rerr, fs.FS_Error.None)
	total: u64
	for r in runs { total += u64(r.count) }
	testing.expect_value(t, total, u64(600))
}
