// test_common.odin — Shared test helpers for the fused test suite.
// All temp files go to /dev/shm for speed.
#+build linux
package tests

import "core:os"

TEST_IMG_SRC := "fused.img"
TEST_IMG_DST := "/dev/shm/fused_test.img"

// open_test_image returns a read-write copy of fused.img.
// Reuses the cached copy if it is up to date with the source.
open_test_image :: proc() -> (^os.File, bool) {
	src_stale := true
	src_fi, src_err := os.stat(TEST_IMG_SRC, context.temp_allocator)
	dst_fi, dst_err := os.stat(TEST_IMG_DST, context.temp_allocator)
	if src_err == nil && dst_err == nil {
		src_stale = src_fi.modification_time != dst_fi.modification_time
	}
	if !src_stale {
		fd, open_err := os.open(TEST_IMG_DST, {.Read, .Write})
		if open_err == nil {return fd, true}
	}

	src, src_open_err := os.open(TEST_IMG_SRC, {.Read})
	if src_open_err != nil {return nil, false}
	defer os.close(src)

	dst, dst_open_err := os.open(TEST_IMG_DST, {.Create, .Write, .Trunc})
	if dst_open_err != nil {return nil, false}
	defer os.close(dst)

	buf: [8192]u8
	for {
		n, read_err := os.read(src, buf[:])
		if read_err != nil || n == 0 {break}
		_, write_err := os.write(dst, buf[:n])
		if write_err != nil {break}
	}
	fd, open_err := os.open(TEST_IMG_DST, {.Read, .Write})
	return fd, open_err == nil
}
