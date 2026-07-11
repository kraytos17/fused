// diskio.odin — Sector-level read/write wrappers around ^os.File.
#+build linux
package fs

import "core:io"
import "core:os"

sector_read :: proc(disk: ^os.File, sector: Sector, buf: []u8) -> (ok: bool) {
	offset := i64(u64(sector) * SECTOR_SIZE)
	os.seek(disk, offset, io.Seek_From.Start)
	n, read_err := os.read(disk, buf)
	return read_err == nil && n == len(buf)
}

sector_write :: proc(disk: ^os.File, sector: Sector, buf: []u8) -> (ok: bool) {
	offset := i64(u64(sector) * SECTOR_SIZE)
	os.seek(disk, offset, io.Seek_From.Start)
	n, write_err := os.write(disk, buf)
	return write_err == nil && n == len(buf)
}

read_master_record :: proc(disk: ^os.File) -> (master: Master_Record, ok: bool) {
	buf: [SECTOR_SIZE]u8
	if !sector_read(disk, Sector(0), buf[:]) {return {}, false}
	master = (^Master_Record)(raw_data(buf[:]))^
	return master, true
}
