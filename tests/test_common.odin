// test_common.odin — Shared test helpers for the fused test suite.
// All temp files go to /dev/shm for speed.
#+build linux
package tests

import "core:os"

TEST_IMG_SRC := "fused.img"
TEST_IMG_DST := "/dev/shm/fused_test.img"

// open_test_image returns a read-write copy of fused.img.
// Reuses the same temp file across tests.
open_test_image :: proc() -> (^os.File, bool) {
	fd, open_err := os.open(TEST_IMG_DST, {.Read, .Write})
	if open_err == nil {
		return fd, true
	}

	src, src_err := os.open(TEST_IMG_SRC, {.Read})
	if src_err != nil {return nil, false}

	dst, dst_err := os.open(TEST_IMG_DST, {.Create, .Write, .Trunc})
	if dst_err != nil {os.close(src); return nil, false}

	buf: [8192]u8
	for {
		n, read_err := os.read(src, buf[:])
		if read_err != nil || n == 0 {break}
		_, write_err := os.write(dst, buf[:n])
		if write_err != nil {break}
	}
	os.close(dst)
	os.close(src)

	fd, open_err = os.open(TEST_IMG_DST, {.Read, .Write})
	return fd, open_err == nil
}
