// io_error_test.odin — Fault-injection tests for disk I/O error paths.
//
// Both tests use real OS failure semantics (short reads, EACCES writes),
// not mocks. The exercised paths (sector_read/sector_write,
// read_master_record) are silent — they emit no log output — which the
// test runner requires (it fails on log.error). Error paths that log
// (No_Space fill, corrupt-chain guards, journal-full) are deliberately
// out of scope; see the plan file.
// scope: scratch image
#+build linux
package tests

import "core:os"
import "core:testing"
import "src:fs"

// TRUNC_IMG is a scratch image holding only the master sector; every data
// read past it is a short read.
TRUNC_IMG := "/dev/shm/fused_trunc.img"

// copy_first_sectors copies the first n sectors of src to dst.
copy_first_sectors :: proc(t: ^testing.T, src_path, dst_path: string, sectors: int) {
	src, serr := os.open(src_path, {.Read})
	if serr != nil {
		testing.fail(t)
		return
	}
	defer os.close(src)

	dst, derr := os.open(dst_path, {.Write, .Create, .Trunc})
	if derr != nil {
		testing.fail(t)
		return
	}
	defer os.close(dst)

	buf: [fs.SECTOR_SIZE]u8
	for _ in 0 ..< sectors {
		n, rerr := os.read(src, buf[:])
		if rerr != nil || n != fs.SECTOR_SIZE {
			testing.fail(t)
			return
		}

		wn, werr := os.write(dst, buf[:])
		if werr != nil || wn != fs.SECTOR_SIZE {
			testing.fail(t)
			return
		}
	}
}

// test_read_error_on_truncated_image — data reads past a truncated image
// fail as Sector_Read_Error: the master record reads fine (sector 0 is
// present), a raw sector read past the end fails, and resolving any real
// path degrades to Entry_Not_Found (chain-walk corruption reads as
// missing, by design — never a crash, never success).
@(test)
test_read_error_on_truncated_image :: proc(t: ^testing.T) {
	copy_first_sectors(t, TEST_IMG_SRC, TRUNC_IMG, 2)
	fd, ferr := os.open(TRUNC_IMG, {.Read, .Write})
	testing.expect_value(t, ferr, nil)
	if ferr != nil { return }
	defer os.close(fd)
	defer os.remove(TRUNC_IMG)

	vol, vok := open_volume_on_fd(fd)
	testing.expect(t, vok, "volume opens (master intact)")
	defer close_test_volume(&vol)

	scratch: [fs.SECTOR_SIZE]u8
	testing.expect(
		t,
		fs.sector_read(&vol, fs.Sector(50), scratch[:]) == .Sector_Read_Error,
		"short read",
	)

	_, rerr := fs.resolve_path(&vol, "/nope", context.temp_allocator)
	testing.expect(t, rerr == .Entry_Not_Found, "broken chain reads as missing")

	empty, eerr := os.open(TRUNC_IMG, {.Write, .Create, .Trunc})
	testing.expect_value(t, eerr, nil)
	if eerr != nil { return }
	defer os.close(empty)

	_, merr := fs.read_master_record(empty)
	testing.expect(t, merr == .Sector_Read_Error, "empty master read")
}

// test_write_error_on_read_only_image — every write to a read-only open
// fails as Sector_Write_Error: a raw sector write and an entry
// read-modify-write (reads succeed, the write fails with EACCES).
// Nothing reaches the disk, so the shared image is untouched.
@(test)
test_write_error_on_read_only_image :: proc(t: ^testing.T) {
	fd, ferr := os.open(TEST_IMG_SRC, {.Read})
	testing.expect_value(t, ferr, nil)
	if ferr != nil { return }

	vol, vok := open_volume_on_fd(fd)
	testing.expect(t, vok, "volume opens read-only")
	defer close_test_volume(&vol)

	scratch: [fs.SECTOR_SIZE]u8
	testing.expect(
		t,
		fs.sector_write(&vol, fs.Sector(0), scratch[:]) == .Sector_Write_Error,
		"raw write",
	)
	e := fs.Directory_Entry{}
	testing.expect(
		t,
		fs.write_directory_entry_at(
			&vol,
			fs.File_Identity {
				fs.Cluster(vol.master.root_cluster),
				fs.Sector_Offset(vol.master.root_sector_index),
				0,
			},
			&e,
		) ==
		.Sector_Write_Error,
		"entry write",
	)
}
