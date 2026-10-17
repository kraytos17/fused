// lfn_lifetime_test.odin — LFN storage-lifetime regression tests.
//
// Long names once shared a bump-packed sector while rename freed the
// whole sector, so renaming one long name invalidated every name packed
// with it; unlink never reclaimed the sector at all. Each name now owns
// a dedicated sector, freed on rename-replace and unlink.
//
// NOTE: paths are heap buffers, never temp-allocator memory — begin_op
// resets the temp arena, so temp-held paths are clobbered mid-callback
// (the same reason cleanup_root builds heap path_bufs).
// scope: scratch image
#+build linux
package tests

import "core:sys/posix"
import "core:testing"
import "src:fs"
import "src:fuse3"
import "src:mounter"

LFN_SCRATCH := "/dev/shm/fused_lfn_test.img"

// lfn_mkpath builds a heap 65-byte "/"+64×ch path: buf backs the cstring,
// full/base are owned copies for string-typed calls. Caller frees all three.
lfn_mkpath :: proc(ch: u8) -> (buf: []u8, full, base: string) {
	buf = make([]u8, 66)
	buf[0] = '/'
	for i in 1 ..< 65 { buf[i] = ch }
	full = string(buf[:65])
	base = string(buf[1:65])
	return buf, full, base
}

// test_lfn_rename_preserves_sibling_name — renaming one long name must
// not disturb another long name (pre-fix they shared one bump sector and
// the rename freed it from under the sibling).
@(test)
test_lfn_rename_preserves_sibling_name :: proc(t: ^testing.T) {
	fsys: mounter.FS
	if !scratch_fs(t, LFN_SCRATCH, &fsys) { return }
	defer close_scratch_fs(&fsys, LFN_SCRATCH)

	b1buf, p1, n1 := lfn_mkpath('a')
	defer delete(b1buf)
	defer delete(p1)
	defer delete(n1)
	b2buf, p2, n2 := lfn_mkpath('b')
	defer delete(b2buf)
	defer delete(p2)
	defer delete(n2)
	b3buf, p3, n3 := lfn_mkpath('c')
	defer delete(b3buf)
	defer delete(p3)
	defer delete(n3)

	fi: fuse3.File_Info
	rc := mounter.fused_create(cstring(raw_data(b1buf)), posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)
	if rc != 0 { return }
	rc = mounter.fused_create(cstring(raw_data(b2buf)), posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)
	if rc != 0 { return }

	// Sanity: first name resolves before the rename.
	e1, _, _, _, rerr1 := mounter.resolve_path_cached(&fsys, p1, context.temp_allocator)
	testing.expect_value(t, rerr1, fs.FS_Error.None)
	if rerr1 != .None { return }
	e1c := e1
	rname1, rok1 := fs.resolve_lfn(&fsys.vol, &e1c, context.temp_allocator)
	testing.expect(t, rok1, "first name resolves")
	testing.expect_value(t, rname1, n1)

	rc = mounter.fused_rename(cstring(raw_data(b1buf)), cstring(raw_data(b3buf)), 0)
	testing.expect_value(t, rc, 0)
	if rc != 0 { return }

	// Sibling resolves with its exact name.
	e2, _, _, _, rerr := mounter.resolve_path_cached(&fsys, p2, context.temp_allocator)
	testing.expect_value(t, rerr, fs.FS_Error.None)
	if rerr != .None { return }
	e2c := e2
	rname, rok := fs.resolve_lfn(&fsys.vol, &e2c, context.temp_allocator)
	testing.expect(t, rok, "sibling name resolves")
	testing.expect_value(t, rname, n2)

	// Renamed file resolves under its new name.
	e3, _, _, _, rerr3 := mounter.resolve_path_cached(&fsys, p3, context.temp_allocator)
	testing.expect_value(t, rerr3, fs.FS_Error.None)
	if rerr3 != .None { return }
	e3c := e3
	rname3, rok3 := fs.resolve_lfn(&fsys.vol, &e3c, context.temp_allocator)
	testing.expect(t, rok3, "new name resolves")
	testing.expect_value(t, rname3, n3)
}

// test_lfn_unlink_reclaims_sector — removing a long-named file must
// return its dedicated LFN sector to free space (was: leaked).
@(test)
test_lfn_unlink_reclaims_sector :: proc(t: ^testing.T) {
	fsys: mounter.FS
	if !scratch_fs(t, LFN_SCRATCH, &fsys) { return }
	defer close_scratch_fs(&fsys, LFN_SCRATCH)

	free0 := fsys.free_sectors
	b1buf, p1d, n1d := lfn_mkpath('d')
	defer delete(b1buf)
	defer delete(p1d)
	defer delete(n1d)

	fi: fuse3.File_Info
	rc := mounter.fused_create(cstring(raw_data(b1buf)), posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)
	if rc != 0 { return }
	testing.expect(t, fsys.free_sectors < free0, "create consumes sectors")

	rc = mounter.fused_unlink(cstring(raw_data(b1buf)))
	testing.expect_value(t, rc, 0)
	testing.expect_value(t, fsys.free_sectors, free0)
}
