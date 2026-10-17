// zero_fill_test.odin — file-extension zero-fill regression tests.
//
// A write past EOF or an extending truncate must expose zeros in the
// newly visible gap, never stale bytes from reused sectors. Runs on an
// isolated freshly formatted image: a poison file fills free sectors
// with 0xA5, is unlinked, and the alloc hint is reset so the victim
// reuses the poisoned sectors.
// scope: scratch image
#+build linux
package tests

import "core:c"
import "core:slice"
import "core:sys/posix"
import "core:testing"
import "src:fs"
import "src:fuse3"
import "src:mounter"

ZERO_SCRATCH := "/dev/shm/fused_zero_test.img"

poison_free_sectors :: proc(t: ^testing.T, fsys: ^mounter.FS) {
	fi: fuse3.File_Info
	rc := mounter.fused_create("/poison", posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)
	if rc != 0 { return }
	n := 64 * fs.SECTOR_SIZE
	buf := make([]u8, n)
	defer delete(buf)
	for i in 0 ..< len(buf) { buf[i] = 0xA5 }
	rc = mounter.fused_write("/poison", raw_data(buf), c.size_t(n), 0, &fi)
	testing.expect_value(t, rc, c.int(n))
	rc = mounter.fused_unlink("/poison")
	testing.expect_value(t, rc, 0)
	fsys.vol.cache.hint = 0
}

// count_nonzero counts nonzero bytes in a slice.
count_nonzero :: proc(b: []u8) -> int {
	bad := 0
	for i in 0 ..< len(b) {
		if b[i] != 0 { bad += 1 }
	}
	return bad
}

// test_write_past_eof_zeroes_gap — bytes between old EOF and the write
// offset must read as zeros, not poison from reused sectors.
@(test)
test_write_past_eof_zeroes_gap :: proc(t: ^testing.T) {
	fsys: mounter.FS
	if !scratch_fs(t, ZERO_SCRATCH, &fsys) { return }
	defer close_scratch_fs(&fsys, ZERO_SCRATCH)
	poison_free_sectors(t, &fsys)

	fi: fuse3.File_Info
	rc := mounter.fused_create("/v1", posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)
	if rc != 0 { return }

	data := "0123456789"
	rc = mounter.fused_write("/v1", raw_data(data), c.size_t(len(data)), 1000, &fi)
	testing.expect_value(t, rc, c.int(len(data)))

	out := make([]u8, 1010)
	defer delete(out)
	n := mounter.fused_read("/v1", raw_data(out), c.size_t(len(out)), 0, &fi)
	testing.expect_value(t, n, c.int(len(out)))
	testing.expect_value(t, count_nonzero(out[:1000]), 0)
	testing.expect(t, slice.equal(out[1000:], transmute([]u8)data), "tail matches write")
}

// test_truncate_up_zeroes_gap — extending truncate must expose zeros.
@(test)
test_truncate_up_zeroes_gap :: proc(t: ^testing.T) {
	fsys: mounter.FS
	if !scratch_fs(t, ZERO_SCRATCH, &fsys) { return }
	defer close_scratch_fs(&fsys, ZERO_SCRATCH)
	poison_free_sectors(t, &fsys)

	fi: fuse3.File_Info
	rc := mounter.fused_create("/v2", posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)
	if rc != 0 { return }

	data := "hi"
	rc = mounter.fused_write("/v2", raw_data(data), c.size_t(len(data)), 0, &fi)
	testing.expect_value(t, rc, c.int(len(data)))

	rc = mounter.fused_truncate("/v2", 1000, nil)
	testing.expect_value(t, rc, 0)

	out := make([]u8, 1000)
	defer delete(out)
	n := mounter.fused_read("/v2", raw_data(out), c.size_t(len(out)), 0, &fi)
	testing.expect_value(t, n, c.int(len(out)))
	testing.expect(t, slice.equal(out[:2], transmute([]u8)data), "head intact")
	testing.expect_value(t, count_nonzero(out[2:]), 0)
}

// test_zero_length_write_no_side_effects — a zero-byte write past EOF
// must change nothing: size, extents, and timestamps stay put.
@(test)
test_zero_length_write_no_side_effects :: proc(t: ^testing.T) {
	fsys: mounter.FS
	if !scratch_fs(t, ZERO_SCRATCH, &fsys) { return }
	defer close_scratch_fs(&fsys, ZERO_SCRATCH)

	fi: fuse3.File_Info
	rc := mounter.fused_create("/v3", posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)
	if rc != 0 { return }

	data := "hi"
	rc = mounter.fused_write("/v3", raw_data(data), c.size_t(len(data)), 0, &fi)
	testing.expect_value(t, rc, c.int(len(data)))

	empty: [1]u8
	rc = mounter.fused_write("/v3", raw_data(empty[:]), 0, 5000, &fi)
	testing.expect_value(t, rc, 0)

	entry, _, _, _, rerr := mounter.resolve_path_cached(&fsys, "/v3", context.temp_allocator)
	testing.expect_value(t, rerr, fs.FS_Error.None)
	testing.expect_value(t, entry.file_size, u64(2))
}

// test_fallocate_grow_zeroes_covered_gap — growing over an already-covered
// chain (a shrunk-then-grown sector keeps old bytes past EOF) must zero.
@(test)
test_fallocate_grow_zeroes_covered_gap :: proc(t: ^testing.T) {
	fsys: mounter.FS
	if !scratch_fs(t, ZERO_SCRATCH, &fsys) { return }
	defer close_scratch_fs(&fsys, ZERO_SCRATCH)
	poison_free_sectors(t, &fsys)

	fi: fuse3.File_Info
	rc := mounter.fused_create("/v4", posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)
	if rc != 0 { return }

	big := make([]u8, 600)
	defer delete(big)
	for i in 0 ..< len(big) { big[i] = 0x42 }
	rc = mounter.fused_write("/v4", raw_data(big), c.size_t(len(big)), 0, &fi)
	testing.expect_value(t, rc, c.int(len(big)))

	rc = mounter.fused_truncate("/v4", 100, nil)
	testing.expect_value(t, rc, 0)

	rc = mounter.fused_fallocate("/v4", 0, 0, 400, &fi)
	testing.expect_value(t, rc, 0)

	out := make([]u8, 400)
	defer delete(out)
	n := mounter.fused_read("/v4", raw_data(out), c.size_t(len(out)), 0, &fi)
	testing.expect_value(t, n, c.int(len(out)))
	bad_head := 0
	for i in 0 ..< 100 {
		if out[i] != 0x42 { bad_head += 1 }
	}
	testing.expect_value(t, bad_head, 0)
	testing.expect_value(t, count_nonzero(out[100:]), 0)
}

// test_write_buf_past_eof_zeroes_gap — a bufvec write past EOF zeroes the gap.
@(test)
test_write_buf_past_eof_zeroes_gap :: proc(t: ^testing.T) {
	fsys: mounter.FS
	if !scratch_fs(t, ZERO_SCRATCH, &fsys) { return }
	defer close_scratch_fs(&fsys, ZERO_SCRATCH)
	poison_free_sectors(t, &fsys)

	fi: fuse3.File_Info
	rc := mounter.fused_create("/v5", posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)
	if rc != 0 { return }

	data := "0123456789"
	bv: fuse3.Bufvec
	bv.count = 1
	bv._buf[0] = fuse3.Buf {
		size = c.size_t(len(data)),
		mem  = rawptr(raw_data(data)),
	}
	rc = mounter.fused_write_buf("/v5", &bv, 800, &fi)
	testing.expect_value(t, rc, c.int(len(data)))

	out := make([]u8, 810)
	defer delete(out)
	n := mounter.fused_read("/v5", raw_data(out), c.size_t(len(out)), 0, &fi)
	testing.expect_value(t, n, c.int(len(out)))
	testing.expect_value(t, count_nonzero(out[:800]), 0)
	testing.expect(t, slice.equal(out[800:], transmute([]u8)data), "tail matches")
}
