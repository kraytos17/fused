// test_fixtures.odin — Unified fixtures: isolated scratch images.
//
// Two families (pick one per test; both format a fresh 1M rev-8 image
// via jtxn_format, so every scratch run starts from identical bytes):
//   scratch_volume(t, path) — open an fs.Volume (no mounter).
//     teardown: defer close_scratch_volume(&vol, path).
//   scratch_fs(t, path, fsys) — open + init a mounter FS and install
//     the fake FUSE context.
//     teardown: defer close_scratch_fs(fsys, path).
// Teardown takes the LIVE state from fsys: init_fs_state populates the
// alloc cache in fsys.vol, so a caller's by-value copy is stale —
// closing the copy leaks (this bit the property test once).
// Tests on the shared image keep using open_test_volume / setup_mounter.
#+build linux
package tests

import "core:os"
import "core:testing"
import "src:fs"
import "src:fuse3"
import "src:mounter"

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

// scratch_volume formats an isolated image and opens a volume on it.
scratch_volume :: proc(t: ^testing.T, path: string) -> (vol: fs.Volume, ok: bool) {
	fd, fok := jtxn_format(t, path)
	if !fok { return {}, false }
	v, vok := open_volume_on_fd(fd)
	if !vok {
		os.close(fd)
		os.remove(path)
		return {}, false
	}
	return v, true
}

// close_scratch_volume closes a scratch volume and removes its image.
close_scratch_volume :: proc(vol: ^fs.Volume, path: string) {
	close_test_volume(vol)
	os.remove(path)
}

// scratch_fs formats an isolated image, opens it, and initializes a
// test FS in place at fsys (fake FUSE context included).
scratch_fs :: proc(t: ^testing.T, path: string, fsys: ^mounter.FS) -> bool {
	vol, vok := scratch_volume(t, path)
	if !vok { return false }
	fsys^ = {}
	mounter.init_fs_for_test(fsys, vol)
	ctx := fuse3.Context {
		uid        = 1000,
		gid        = 1000,
		private_data = fsys,
	}
	fuse3.set_test_context(&ctx)
	return true
}

// close_scratch_fs tears down a scratch FS and removes its image. Takes
// the live volume from fsys (see header note on stale copies).
close_scratch_fs :: proc(fsys: ^mounter.FS, path: string) {
	v := fsys.vol
	mounter.destroy_fs_for_test(fsys)
	close_test_volume(&v)
	os.remove(path)
}
