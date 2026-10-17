// xattr_test.odin — Unit tests for extended-attribute storage (rev 8).
#+build linux
package tests

import "core:fmt"
import "core:mem"
import "core:testing"
import "src:fs"

// test_xattr_roundtrip — set/get/list/remove xattrs on the demo file.
@(test)
test_xattr_roundtrip :: proc(t: ^testing.T) {
	vol, ok := open_test_volume()
	if !ok { testing.fail(t); return }
	defer close_test_volume(&vol)

	res, resolve_err := fs.resolve_path(&vol, "/Kernel")
	testing.expectf(t, resolve_err == .None, "resolve /Kernel")
	if resolve_err != .None { return }

	entry := res.entry
	red: string = "red"
	large: string = "large"
	attrs := []fs.XAttr {
		{name = "user.color", value = transmute([]u8)red},
		{name = "user.size", value = transmute([]u8)large},
		{name = "user.empty", value = {}},
	}
	reclaim, serr := fs.xattr_store(&vol, &entry, attrs)
	testing.expect_value(t, serr, fs.FS_Error.None)

	// Persist the entry pointer via write_directory_entry_at (as the mounter does).
	testing.expect_value(t, entry.xattr_cluster != 0, true)
	testing.expect(
		t,
		fs.write_directory_entry_at(&vol, fs.File_Identity{res.cluster, res.offset, res.entry_index}, &entry) ==
		.None,
		"persist entry",
	)
	// Free the previous chain only after the pointer persisted.
	testing.expect_value(t, fs.xattr_free_chain(&vol, reclaim), fs.FS_Error.None)

	// Reload a fresh entry to simulate a fresh resolve.
	entry2, _ := fs.resolve_path(&vol, "/Kernel")

	val, found, gerr := fs.xattr_get(&vol, &entry2.entry, "user.color")
	defer delete(val)
	testing.expect(t, found, "get user.color found")
	testing.expect_value(t, gerr, fs.FS_Error.None)
	testing.expect_value(t, string(val), "red")

	val2, found2, gerr2 := fs.xattr_get(&vol, &entry2.entry, "user.empty")
	defer delete(val2)
	testing.expect(t, found2, "get user.empty found")
	testing.expect_value(t, gerr2, fs.FS_Error.None)
	testing.expect_value(t, len(val2), 0)

	_, found3, gerr3 := fs.xattr_get(&vol, &entry2.entry, "user.missing")
	testing.expect(t, !found3, "missing attr not found")
	testing.expect_value(t, gerr3, fs.FS_Error.None)

	loaded, lerr := fs.xattr_load(&vol, &entry2.entry)
	defer {
		for &a in loaded {
			delete(a.name)
			delete(a.value)
		}
		delete(loaded)
	}
	testing.expect_value(t, lerr, fs.FS_Error.None)
	testing.expect_value(t, len(loaded), 3)

	// Remove one attribute.
	entry3 := entry2.entry
	removed, reclaim_r, rerr := fs.xattr_remove(&vol, &entry3, "user.size")
	testing.expect(t, removed, "removed user.size")
	testing.expect_value(t, rerr, fs.FS_Error.None)
	testing.expect(
		t,
		fs.write_directory_entry_at(&vol, fs.File_Identity{res.cluster, res.offset, res.entry_index}, &entry3) ==
		.None,
		"persist after remove",
	)
	testing.expect_value(t, fs.xattr_free_chain(&vol, reclaim_r), fs.FS_Error.None)

	_, found4, gerr4 := fs.xattr_get(&vol, &entry3, "user.size")
	testing.expect(t, !found4, "user.size gone after remove")
	testing.expect_value(t, gerr4, fs.FS_Error.None)

	removed2, _, rerr2 := fs.xattr_remove(&vol, &entry3, "user.nope")
	testing.expect(t, !removed2, "removing missing attr reports not removed")
	testing.expect_value(t, rerr2, fs.FS_Error.None)

	// Clear everything.
	cleared := fs.xattr_clear(&entry3)
	testing.expect_value(t, entry3.xattr_cluster, u64(0))
	testing.expect(
		t,
		fs.write_directory_entry_at(&vol, fs.File_Identity{res.cluster, res.offset, res.entry_index}, &entry3) ==
		.None,
		"persist clear",
	)
	testing.expect_value(t, fs.xattr_free_chain(&vol, cleared), fs.FS_Error.None)
}

// test_xattr_large_value — a value spanning multiple sectors round-trips.
@(test)
test_xattr_large_value :: proc(t: ^testing.T) {
	vol, ok := open_test_volume()
	if !ok { testing.fail(t); return }
	defer close_test_volume(&vol)

	res, resolve_err := fs.resolve_path(&vol, "/Kernel")
	testing.expectf(t, resolve_err == .None, "resolve /Kernel")
	if resolve_err != .None { return }

	big := make([]u8, 3 * fs.SECTOR_SIZE)
	defer delete(big)
	for i in 0 ..< len(big) {
		big[i] = u8(i)
	}

	entry := res.entry
	attrs := []fs.XAttr{{name = "user.big", value = big}}
	reclaim, serr := fs.xattr_store(&vol, &entry, attrs)
	testing.expect_value(t, serr, fs.FS_Error.None)
	testing.expect(
		t,
		fs.write_directory_entry_at(&vol, fs.File_Identity{res.cluster, res.offset, res.entry_index}, &entry) ==
		.None,
		"persist entry",
	)
	testing.expect_value(t, fs.xattr_free_chain(&vol, reclaim), fs.FS_Error.None)

	val, found, gerr := fs.xattr_get(&vol, &entry, "user.big")
	defer delete(val)
	testing.expect(t, found, "big attr found")
	testing.expect_value(t, gerr, fs.FS_Error.None)
	testing.expect_value(t, len(val), len(big))
	for i in 0 ..< len(big) {
		if val[i] != big[i] {
			testing.expect(t, false, "big attr content mismatch")
			break
		}
	}

	cleared_big := fs.xattr_clear(&entry)
	testing.expect(t, cleared_big != 0, "clear returns old chain")
	testing.expect_value(t, entry.xattr_cluster, u64(0))
	testing.expect(
		t,
		fs.write_directory_entry_at(&vol, fs.File_Identity{res.cluster, res.offset, res.entry_index}, &entry) ==
		.None,
		"persist clear",
	)
	testing.expect_value(t, fs.xattr_free_chain(&vol, cleared_big), fs.FS_Error.None)
}

// xattr_test_blob assembles a blob with explicit header fields and raw
// record payload bytes.
xattr_test_blob :: proc(magic: u32, count: u16, total: u32, payload: []u8) -> []u8 {
	blob := make([]u8, 12 + len(payload))
	(^u32)(raw_data(blob[0:]))^ = magic
	(^u16)(raw_data(blob[4:]))^ = count
	(^u16)(raw_data(blob[6:]))^ = 0
	(^u32)(raw_data(blob[8:]))^ = total
	copy(blob[12:], payload)
	return blob
}

// xattr_test_rec builds one record payload for a name/value pair.
xattr_test_rec :: proc(name: string, value: []u8) -> []u8 {
	rec := make([]u8, 6 + len(name) + len(value))
	(^u16)(raw_data(rec[0:]))^ = u16(len(name))
	(^u32)(raw_data(rec[2:]))^ = u32(len(value))
	copy(rec[6:], name)
	copy(rec[6 + len(name):], value)
	return rec
}

// xattr_plant_blob allocates a .XAttr chain sized for the blob and writes it.
xattr_plant_blob :: proc(
	t: ^testing.T,
	vol: ^fs.Volume,
	blob: []u8,
) -> (
	c: fs.Cluster,
	o: fs.Sector_Offset,
	ok: bool,
) {
	sectors := (u64(len(blob)) + fs.SECTOR_SIZE - 1) / fs.SECTOR_SIZE
	cc, oo, aerr := fs.allocate_sectors(vol, {}, sectors, .XAttr)
	testing.expect_value(t, aerr, fs.FS_Error.None)
	if aerr != .None { return cc, oo, false }
	werr := fs.write_chain(vol, fs.Chain_Location{cc, oo}, blob)
	testing.expect_value(t, werr, fs.FS_Error.None)
	if werr != .None {
		fs.deallocate_sectors(vol, fs.Chain_Location{cc, oo})
		return cc, oo, false
	}
	return cc, oo, true
}

// test_xattr_malformed_blob_rejected — every structural violation in a blob
// (short header, bad magic, missing records, bad total, duplicate or empty
// names) must fail closed with .Corrupt_XAttr_Blob, never surface as a
// partial or empty set. Sector padding past the declared blob is legitimate
// and loads without phantom attributes.
@(test)
test_xattr_malformed_blob_rejected :: proc(t: ^testing.T) {
	vol, ok := open_test_volume()
	if !ok { testing.fail(t); return }
	defer close_test_volume(&vol)

	rec_a := xattr_test_rec("user.a", []u8{49})
	defer delete(rec_a)
	payload := rec_a
	total := u32(len(payload))

	valid := xattr_test_blob(fs.XATTR_MAGIC, 1, total, payload)
	defer delete(valid)
	short := valid[:5]
	bad_magic := xattr_test_blob(0xDEADBEEF, 1, total, payload)
	defer delete(bad_magic)
	head_only := xattr_test_blob(fs.XATTR_MAGIC, 1, 0, {})
	defer delete(head_only)
	bad_total := xattr_test_blob(fs.XATTR_MAGIC, 1, total + 1, payload)
	defer delete(bad_total)
	trailing := make([]u8, len(valid) + 1)
	defer delete(trailing)
	copy(trailing, valid)
	dup_payload := make([]u8, 2 * len(payload))
	defer delete(dup_payload)
	copy(dup_payload, payload)
	copy(dup_payload[len(payload):], payload)
	duplicates := xattr_test_blob(fs.XATTR_MAGIC, 2, 2 * total, dup_payload)
	defer delete(duplicates)
	stray := xattr_test_blob(fs.XATTR_MAGIC, 0, 0, payload)
	defer delete(stray)

	empty_rec := xattr_test_rec("", []u8{})
	defer delete(empty_rec)
	empty_name := xattr_test_blob(fs.XATTR_MAGIC, 1, u32(len(empty_rec)), empty_rec)
	defer delete(empty_name)

	c, o, pok := xattr_plant_blob(t, &vol, valid)
	if !pok { return }
	defer fs.deallocate_sectors(&vol, fs.Chain_Location{c, o})

	// Control: the helper-built blob loads exactly one attribute.
	entry := fs.Directory_Entry{xattr_cluster = u64(c)}
	loaded, lerr := fs.xattr_load(&vol, &entry)
	testing.expect_value(t, lerr, fs.FS_Error.None)
	testing.expect_value(t, len(loaded), 1)
	for &a in loaded {
		delete(a.name)
		delete(a.value)
	}
	delete(loaded)

	cases := []struct {
		label: string,
		blob:  []u8,
	}{
		{"truncated header", short},
		{"bad magic", bad_magic},
		{"count without record", head_only},
		{"bad total", bad_total},
		{"duplicate names", duplicates},
		{"empty name", empty_name},
	}
	for &cs in cases {
		werr := fs.write_chain(&vol, fs.Chain_Location{c, o}, cs.blob)
		testing.expect_value(t, werr, fs.FS_Error.None)
		if werr != .None { continue }
		bad_entry := fs.Directory_Entry{xattr_cluster = u64(c)}
		attrs, derr := fs.xattr_load(&vol, &bad_entry)
		testing.expectf(t, derr == fs.FS_Error.Corrupt_XAttr_Blob, "%s rejected", cs.label)
		for &a in attrs {
			delete(a.name)
			delete(a.value)
		}
		delete(attrs)

		_, found, gerr := fs.xattr_get(&vol, &bad_entry, "user.a")
		testing.expectf(t, !found, "%s get not found", cs.label)
		testing.expectf(t, gerr == fs.FS_Error.Corrupt_XAttr_Blob, "%s get errors", cs.label)
	}

	// A torn multi-sector write (second sector lost) must also fail
	// closed: the zeroed tail parses as empty-name records, never as
	// attributes. 45 single-byte attrs span two sectors.
	torn_recs := make([dynamic]u8, 0, 700)
	defer delete(torn_recs)
	for i in 0 ..< 45 {
		name := fmt.tprintf("user.k%02d", i)
		rec := xattr_test_rec(name, []u8{u8(i)})
		defer delete(rec)
		append(&torn_recs, ..rec[:])
	}
	torn_total := u32(len(torn_recs))
	torn := xattr_test_blob(fs.XATTR_MAGIC, 45, torn_total, torn_recs[:])
	defer delete(torn)
	testing.expect(t, len(torn) > fs.SECTOR_SIZE, "torn blob spans sectors")
	mem.zero_slice(torn[fs.SECTOR_SIZE:])
	tc, to, tok := xattr_plant_blob(t, &vol, torn)
	if tok {
		defer fs.deallocate_sectors(&vol, fs.Chain_Location{tc, to})
		torn_entry := fs.Directory_Entry{xattr_cluster = u64(tc)}
		tattrs, terr := fs.xattr_load(&vol, &torn_entry)
		testing.expect_value(t, terr, fs.FS_Error.Corrupt_XAttr_Blob)
		testing.expect_value(t, len(tattrs), 0)
		delete(tattrs)
	}

	// Sector padding past the declared blob is legitimate (chains are
	// sector-granular): a trailing byte or a stray payload under a zero
	// count loads without surfacing phantom attributes.
	padded := []struct {
		label: string,
		blob:  []u8,
		want:  int,
	}{
		{"trailing byte", trailing, 1},
		{"payload under zero count", stray, 0},
	}
	for &cs in padded {
		werr := fs.write_chain(&vol, fs.Chain_Location{c, o}, cs.blob)
		testing.expect_value(t, werr, fs.FS_Error.None)
		if werr != .None { continue }
		ok_entry := fs.Directory_Entry{xattr_cluster = u64(c)}
		attrs, derr := fs.xattr_load(&vol, &ok_entry)
		testing.expectf(t, derr == fs.FS_Error.None, "%s accepted", cs.label)
		testing.expectf(t, len(attrs) == cs.want, "%s attr count", cs.label)
		for &a in attrs {
			delete(a.name)
			delete(a.value)
		}
		delete(attrs)
	}
}

// test_xattr_clear_defers_free — clear detaches the chain in memory and
// hands it back for reclamation: the old chain stays allocated and
// readable until the caller persists and frees it.
@(test)
test_xattr_clear_defers_free :: proc(t: ^testing.T) {
	vol, ok := open_test_volume()
	if !ok { testing.fail(t); return }
	defer close_test_volume(&vol)

	entry := fs.Directory_Entry{}
	v := []u8{49}
	attrs := []fs.XAttr{{name = "user.t", value = v}}
	old, serr := fs.xattr_store(&vol, &entry, attrs)
	testing.expect_value(t, serr, fs.FS_Error.None)
	testing.expect(t, old == 0, "no previous chain")
	c1 := entry.xattr_cluster
	testing.expect(t, c1 != 0, "chain allocated")

	cleared := fs.xattr_clear(&entry)
	testing.expect_value(t, cleared, c1)
	testing.expect_value(t, entry.xattr_cluster, u64(0))

	// Old chain still live and readable (not yet freed).
	via_old := fs.Directory_Entry{xattr_cluster = cleared}
	loaded, lerr := fs.xattr_load(&vol, &via_old)
	testing.expect_value(t, lerr, fs.FS_Error.None)
	testing.expect_value(t, len(loaded), 1)
	for &a in loaded {
		delete(a.name)
		delete(a.value)
	}
	delete(loaded)

	testing.expect_value(t, fs.xattr_free_chain(&vol, cleared), fs.FS_Error.None)
	gone, lerr2 := fs.xattr_load(&vol, &via_old)
	testing.expect_value(t, lerr2, fs.FS_Error.Entry_Not_Found)
	delete(gone)
}

// test_xattr_store_alloc_failure_keeps_old — when allocation fails before
// persisting anything, the entry pointer and free space are unchanged.
@(test)
test_xattr_store_alloc_failure_keeps_old :: proc(t: ^testing.T) {
	vol, ok := open_test_volume()
	if !ok { testing.fail(t); return }
	defer close_test_volume(&vol)

	f0 := fs.alloc_cache_count_free(&vol)
	vol.fault = fs.IO_Fault{
		enabled           = true,
		fail_reads_after  = max(u64),
		fail_writes_after = 0,
		fail_syncs_after  = max(u64),
	}
	entry := fs.Directory_Entry{}
	v := []u8{49}
	attrs := []fs.XAttr{{name = "user.t", value = v}}
	reclaim, serr := fs.xattr_store(&vol, &entry, attrs)
	testing.expect_value(t, serr, fs.FS_Error.Sector_Write_Error)
	testing.expect_value(t, reclaim, u64(0))
	testing.expect_value(t, entry.xattr_cluster, u64(0))
	vol.fault.enabled = false
	testing.expect_value(t, fs.alloc_cache_count_free(&vol), f0)
}

// test_xattr_crash_window_sound — between commit and persist the old chain
// must stay live and readable: a crash there leaves entry → new (to be
// persisted) and old intact, never entry → freed sectors.
@(test)
test_xattr_crash_window_sound :: proc(t: ^testing.T) {
	vol, ok := open_test_volume()
	if !ok { testing.fail(t); return }
	defer close_test_volume(&vol)

	entry := fs.Directory_Entry{}
	v1 := []u8{49}
	attrs1 := []fs.XAttr{{name = "user.t", value = v1}}
	r0, serr1 := fs.xattr_store(&vol, &entry, attrs1)
	testing.expect_value(t, serr1, fs.FS_Error.None)
	testing.expect_value(t, r0, u64(0))
	c1 := entry.xattr_cluster
	testing.expect(t, c1 != 0, "V1 chain allocated")

	// Second store, old chain deliberately not freed yet (crash window).
	v2 := []u8{50, 51}
	attrs2 := []fs.XAttr{{name = "user.t", value = v2}}
	r1, serr2 := fs.xattr_store(&vol, &entry, attrs2)
	testing.expect_value(t, serr2, fs.FS_Error.None)
	testing.expect_value(t, r1, c1)
	c2 := entry.xattr_cluster
	testing.expect(t, c2 != 0 && c2 != c1, "V2 chain allocated")

	// Old chain fully intact and readable.
	via_old := fs.Directory_Entry{xattr_cluster = c1}
	old_attrs, oerr := fs.xattr_load(&vol, &via_old)
	testing.expect_value(t, oerr, fs.FS_Error.None)
	testing.expect_value(t, len(old_attrs), 1)
	testing.expect_value(t, string(old_attrs[0].value), "1")
	for &a in old_attrs {
		delete(a.name)
		delete(a.value)
	}
	delete(old_attrs)

	// New chain readable through the entry.
	new_attrs, nerr := fs.xattr_load(&vol, &entry)
	testing.expect_value(t, nerr, fs.FS_Error.None)
	testing.expect_value(t, len(new_attrs), 1)
	testing.expect_value(t, string(new_attrs[0].value), "23")
	for &a in new_attrs {
		delete(a.name)
		delete(a.value)
	}
	delete(new_attrs)

	// Post-persist cleanup would free the old chain; do it directly.
	testing.expect_value(t, fs.xattr_free_chain(&vol, c1), fs.FS_Error.None)
	testing.expect_value(t, fs.xattr_free_chain(&vol, c2), fs.FS_Error.None)
}
