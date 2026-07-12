// diskio.odin — Sector-level read/write wrappers around ^os.File.
// Uses pread/pwrite — no seek needed, thread-safe.
#+build linux
package fs

import "core:os"

sector_read :: proc(disk: ^os.File, sector: Sector, buf: []u8) -> (ok: bool) {
	n, err := os.read_at(disk, buf, i64(u64(sector) * SECTOR_SIZE))
	return err == nil && n == len(buf)
}

sector_write :: proc(disk: ^os.File, sector: Sector, buf: []u8) -> (ok: bool) {
	n, err := os.write_at(disk, buf, i64(u64(sector) * SECTOR_SIZE))
	return err == nil && n == len(buf)
}

sector_read_bulk :: proc(disk: ^os.File, start_sector: Sector, buf: []u8) -> (n: int, ok: bool) {
	nn, err := os.read_at(disk, buf, i64(u64(start_sector) * SECTOR_SIZE))
	return nn, err == nil && nn == len(buf)
}

sector_write_bulk :: proc(disk: ^os.File, start_sector: Sector, buf: []u8) -> (ok: bool) {
	_, err := os.write_at(disk, buf, i64(u64(start_sector) * SECTOR_SIZE))
	return err == nil
}

read_master_record :: proc(disk: ^os.File) -> (master: Master_Record, ok: bool) {
	buf: [SECTOR_SIZE]u8
	if !sector_read(disk, Sector(0), buf[:]) {
		return {}, false
	}
	master = (^Master_Record)(raw_data(buf[:]))^
	return master, true
}
