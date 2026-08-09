// xattr_test.odin — Unit tests for extended-attribute storage (rev 8).
#+build linux
package tests

import "core:testing"
import "src:fs"

// test_xattr_roundtrip — set/get/list/remove xattrs on the demo file.
@test
test_xattr_roundtrip :: proc(t: ^testing.T) {
	vol, ok := open_test_volume()
	if !ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	res, rok := fs.resolve_path(&vol, "/Kernel")
	testing.expectf(t, rok, "resolve /Kernel")
	if !rok { return }

	entry := res.entry
	red: string = "red"
	large: string = "large"
	attrs := []fs.XAttr{
		{name = "user.color", value = transmute([]u8)red},
		{name = "user.size",  value = transmute([]u8)large},
		{name = "user.empty", value = {}},
	}
	serr := fs.xattr_store(&vol, &entry, attrs)
	testing.expect_value(t, serr, fs.FS_Error.None)

	// Persist the entry pointer via write_directory_entry_at (as the mounter does).
	testing.expect_value(t, entry.xattr_cluster != 0, true)
	testing.expect(t, fs.write_directory_entry_at(&vol, res.cluster, res.offset, res.entry_index, &entry), "persist entry")

	// Reload a fresh entry to simulate a fresh resolve.
	entry2, _ := fs.resolve_path(&vol, "/Kernel")

	val, found := fs.xattr_get(&vol, &entry2.entry, "user.color")
	defer delete(val)
	testing.expect(t, found, "get user.color found")
	testing.expect_value(t, string(val), "red")

	val2, found2 := fs.xattr_get(&vol, &entry2.entry, "user.empty")
	defer delete(val2)
	testing.expect(t, found2, "get user.empty found")
	testing.expect_value(t, len(val2), 0)

	_, found3 := fs.xattr_get(&vol, &entry2.entry, "user.missing")
	testing.expect(t, !found3, "missing attr not found")

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
	removed, rerr := fs.xattr_remove(&vol, &entry3, "user.size")
	testing.expect(t, removed, "removed user.size")
	testing.expect_value(t, rerr, fs.FS_Error.None)
	testing.expect(t, fs.write_directory_entry_at(&vol, res.cluster, res.offset, res.entry_index, &entry3), "persist after remove")

	_, found4 := fs.xattr_get(&vol, &entry3, "user.size")
	testing.expect(t, !found4, "user.size gone after remove")

	removed2, rerr2 := fs.xattr_remove(&vol, &entry3, "user.nope")
	testing.expect(t, !removed2, "removing missing attr reports not removed")
	testing.expect_value(t, rerr2, fs.FS_Error.None)

	// Clear everything.
	cerr := fs.xattr_clear(&vol, &entry3)
	testing.expect_value(t, cerr, fs.FS_Error.None)
	testing.expect_value(t, entry3.xattr_cluster, u64(0))
}

// test_xattr_large_value — a value spanning multiple sectors round-trips.
@test
test_xattr_large_value :: proc(t: ^testing.T) {
	vol, ok := open_test_volume()
	if !ok {testing.fail(t); return}
	defer close_test_volume(&vol)

	res, rok := fs.resolve_path(&vol, "/Kernel")
	testing.expectf(t, rok, "resolve /Kernel")
	if !rok { return }

	big := make([]u8, 3 * fs.SECTOR_SIZE)
	defer delete(big)
	for i in 0 ..< len(big) {
		big[i] = u8(i)
	}

	entry := res.entry
	attrs := []fs.XAttr{{name = "user.big", value = big}}
	serr := fs.xattr_store(&vol, &entry, attrs)
	testing.expect_value(t, serr, fs.FS_Error.None)
	testing.expect(t, fs.write_directory_entry_at(&vol, res.cluster, res.offset, res.entry_index, &entry), "persist entry")

	val, found := fs.xattr_get(&vol, &entry, "user.big")
	defer delete(val)
	testing.expect(t, found, "big attr found")
	testing.expect_value(t, len(val), len(big))
	for i in 0 ..< len(big) {
		if val[i] != big[i] {
			testing.expect(t, false, "big attr content mismatch")
			break
		}
	}

	cerr := fs.xattr_clear(&vol, &entry)
	testing.expect_value(t, cerr, fs.FS_Error.None)
	testing.expect(t, fs.write_directory_entry_at(&vol, res.cluster, res.offset, res.entry_index, &entry), "persist clear")
}
