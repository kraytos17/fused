// journal_test.odin — Tests for the unified journal backend table.
//
// The standard test image is rev 8 (v2 WAL), so the v6 intent-log backend
// has no other coverage. These tests build a minimal rev-6 image and drive
// allocation/deallocation/recovery through the same call sites as the v2
// backend.
#+build linux
package tests

import "core:hash"
import "core:os"
import "core:testing"
import "src:fs"

V6_TEST_IMG := "/dev/shm/fused_v6_test.img"
// make_v6_image formats a 1 MB rev-6 image (features = {.Uid_Gid}, intent
// log journal) at V6_TEST_IMG via the shared fs.format_image.
make_v6_image :: proc(t: ^testing.T) -> (ok: bool) {
	os.remove(V6_TEST_IMG)
	fd, ferr := os.open(V6_TEST_IMG, {.Create, .Write, .Trunc, .Read})
	if ferr != nil {
		testing.fail(t)
		return false
	}
	defer os.close(fd)

	if ferr := fs.format_image(fd, {
		size         = 1024 * 1024,
		cluster_size = 8,
		features     = fs.Features{.Uid_Gid},
		rev_min      = 6,
		rev_max      = 6,
	}); ferr != .None {
		testing.fail(t)
		return false
	}
	return true
}

// read_intent_log_sector reads the intent-log sector raw.
read_intent_log_sector :: proc(vol: ^fs.Volume) -> (log: fs.Intent_Log, ok: bool) {
	buf: [fs.SECTOR_SIZE]u8
	if fs.sector_read(vol, fs.intent_log_sector(&vol.master), buf[:]) != .None {
		return {}, false
	}
	return (^fs.Intent_Log)(&buf[0])^, true
}

// test_v6_allocate_deallocate drives allocation and deallocation through the
// unified backend on a rev-6 (intent log) image.
@test
test_v6_allocate_deallocate :: proc(t: ^testing.T) {
	if !make_v6_image(t) { return }

	vol, verr := fs.volume_open(V6_TEST_IMG)
	if verr != .None {
		testing.fail(t)
		return
	}
	defer fs.volume_close(&vol)

	// Fresh allocation of 4 sectors.
	c, o, aerr := fs.allocate_sectors(&vol, 0, 0, 4, .File_Content)
	testing.expect(t, aerr == fs.FS_Error.None, "allocate ok")
	testing.expect(t, c != 0, "allocated cluster != 0")

	entry, ferr2 := fs.find_cluster_entry(&vol, c, o)
	testing.expect(t, ferr2 == fs.FS_Error.None, "find_cluster_entry ok")
	testing.expect(t, .Allocated in entry.state, "entry allocated")

	// Extend the chain (exercises link_tail_to_new journaling).
	_, _, aerr = fs.allocate_sectors(&vol, c, o, 10, .File_Content)
	testing.expect(t, aerr == fs.FS_Error.None, "extend ok")

	// Deallocate the chain; the first entry must now be free.
	derr := fs.deallocate_sectors(&vol, c, o)
	testing.expect(t, derr == fs.FS_Error.None, "deallocate ok")
	_, ferr3 := fs.find_cluster_entry(&vol, c, o)
	testing.expect(t, ferr3 == fs.FS_Error.Entry_Not_Found, "entry freed")
}

// test_v2_allocate_deallocate drives the same call sites on the rev-8
// (v2 WAL) test image, proving both backends share one code path.
@test
test_v2_allocate_deallocate :: proc(t: ^testing.T) {
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

// test_v6_dirty_log_recover writes a dirty intent log, reopens the volume
// (which runs recovery through the unified backend), and verifies the log is
// cleared.
@test
test_v6_dirty_log_recover :: proc(t: ^testing.T) {
	if !make_v6_image(t) { return }

	// Poison the intent-log sector with a dirty log.
	fd, ferr := os.open(V6_TEST_IMG, {.Read, .Write})
	if ferr != nil {
		testing.fail(t)
		return
	}
	defer os.close(fd)
	vol := fs.Volume{disk = fd}
	master, mok := fs.read_master_record(fd)
	testing.expect(t, mok, "read_master_record")
	vol.master = master

	dirty: fs.Intent_Log
	dirty.magic = fs.JOURNAL_MAGIC
	dirty.seq = 5
	dirty.count = 1
	dirty.entries[0] = {cluster = 10, ce_index = 0, alloc_size = 1, state = 1}
	dirty_buf: [fs.SECTOR_SIZE]u8
	(^fs.Intent_Log)(&dirty_buf[0])^ = dirty
	// CRC over the sector minus its final 4 bytes, exactly as the writer does.
	dirty.crc = hash.crc32(dirty_buf[:fs.SECTOR_SIZE - 4])
	(^fs.Intent_Log)(&dirty_buf[0])^ = dirty
	testing.expect(t, fs.sector_write(&vol, fs.intent_log_sector(&master), dirty_buf[:]) == .None, "dirty log write")

	// Reopen: validation + unified recovery should clear the log.
	vol2, verr := fs.volume_open(V6_TEST_IMG)
	testing.expect(t, verr == fs.FS_Error.None, "volume_open ok")
	defer fs.volume_close(&vol2)

	cleared, cok := read_intent_log_sector(&vol2)
	testing.expect(t, cok, "read log sector")
	testing.expect_value(t, u16(cleared.magic), u16(0))
	// Recovery's clearing commit bumps the master seq (initialised to 1 by
	// journal_seq_init) by one.
	testing.expect_value(t, fs.journal_seq_get(&vol2.master), fs.Journal_Seq(2))
}

// test_backend_abort verifies the unified abort semantics: a v6 transaction
// that is discarded leaves no dirty log behind.
@test
test_backend_abort :: proc(t: ^testing.T) {
	if !make_v6_image(t) { return }

	vol, verr := fs.volume_open(V6_TEST_IMG)
	if verr != .None {
		testing.fail(t)
		return
	}
	defer fs.volume_close(&vol)

	backend := fs.journal_backend_for(&vol.master)
	h: fs.Journal_Txn_Handle
	testing.expect(t, backend.begin(&vol, &h), "begin")
	backend.add(&vol, &h, fs.journal_entry_from_cluster_entry(
		fs.Cluster_Entry{state = {.Allocated}, allocation_size = 4, sector_start = 2},
		10, 0))
	backend.abort(&vol, &h)

	cleared, cok := read_intent_log_sector(&vol)
	testing.expect(t, cok, "read log sector")
	testing.expect_value(t, u16(cleared.magic), u16(0))

	// A committed transaction also leaves the log clean (clear after write).
	backend2 := fs.journal_backend_for(&vol.master)
	h2: fs.Journal_Txn_Handle
	testing.expect(t, backend2.begin(&vol, &h2), "begin 2")
	backend2.add(&vol, &h2, fs.journal_entry_from_cluster_entry(
		fs.Cluster_Entry{state = {.Allocated}, allocation_size = 4, sector_start = 2},
		11, 1))
	testing.expect(t, backend2.commit(&vol, &h2), "commit 2")

	cleared2, cok2 := read_intent_log_sector(&vol)
	testing.expect(t, cok2, "read log sector 2")
	testing.expect_value(t, u16(cleared2.magic), u16(0))
}
