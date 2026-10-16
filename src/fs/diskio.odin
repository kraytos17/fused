// diskio.odin — Sector-level read/write wrappers around ^os.File.
// Uses pread/pwrite — no seek needed, thread-safe.
#+build linux
package fs

import "core:os"

// IO_Fault is a deterministic fault injector and I/O counter for tests.
// The zero value disables injection (production behavior). Enable it to
// fail reads/writes/syncs past a threshold (the first N succeed) or to
// count I/O per operation. Single-threaded test volumes only.
IO_Fault :: struct {
	enabled:           bool,
	fail_reads_after:  u64,
	fail_writes_after: u64,
	fail_syncs_after:  u64,
	reads:             u64,
	writes:            u64,
	syncs:             u64,
}

// sector_read reads one 512-byte sector from disk at the given sector number
sector_read :: proc(vol: ^Volume, sector: Sector, buf: []u8) -> FS_Error {
	if vol.fault.enabled {
		vol.fault.reads += 1
		if vol.fault.reads > vol.fault.fail_reads_after { return .Sector_Read_Error }
	}
	n, err := os.read_at(vol.disk, buf, i64(u64(sector) * SECTOR_SIZE))
	if err != nil || n != len(buf) {
		return .Sector_Read_Error
	}
	return .None
}

// sector_write writes one 512-byte sector to disk
sector_write :: proc(vol: ^Volume, sector: Sector, buf: []u8) -> FS_Error {
	if vol.fault.enabled {
		vol.fault.writes += 1
		if vol.fault.writes > vol.fault.fail_writes_after { return .Sector_Write_Error }
	}
	n, err := os.write_at(vol.disk, buf, i64(u64(sector) * SECTOR_SIZE))
	if err != nil || n != len(buf) {
		return .Sector_Write_Error
	}
	return .None
}

// sector_write_bulk writes multiple sectors; like the single-sector
// form, a short write without an error still fails instead of
// reporting success.
sector_write_bulk :: proc(vol: ^Volume, start_sector: Sector, buf: []u8) -> FS_Error {
	if vol.fault.enabled {
		vol.fault.writes += 1
		if vol.fault.writes > vol.fault.fail_writes_after { return .Sector_Write_Error }
	}
	n, err := os.write_at(vol.disk, buf, i64(u64(start_sector) * SECTOR_SIZE))
	if err != nil || n != len(buf) {
		return .Sector_Write_Error
	}
	return .None
}

// volume_sync flushes the volume file, honoring fault injection. It
// backs the journal's durability points (records, header, home-apply);
// user-facing fsync callbacks keep direct os.sync (no fault tests).
volume_sync :: proc(vol: ^Volume) -> bool {
	if vol.fault.enabled {
		vol.fault.syncs += 1
		if vol.fault.syncs > vol.fault.fail_syncs_after { return false }
	}
	return os.sync(vol.disk) == nil
}

// sector_for returns the absolute sector for a (cluster, offset) pair.
@(require_results)
sector_for :: proc(cluster: Cluster, offset: Sector_Offset, cluster_size: u64) -> Sector {
	return Sector(u64(cluster) * cluster_size + u64(offset))
}

// read_master_record reads and returns the Master_Record from sector 0.
// A short read reports .Sector_Read_Error (no validation here — see
// validate_master); callers needing validity checks layer them on top.
read_master_record :: proc(disk: ^os.File) -> (master: Master_Record, err: FS_Error) {
	buf: [SECTOR_SIZE]u8
	n, read_err := os.read_at(disk, buf[:], 0)
	if read_err != nil || n != SECTOR_SIZE {
		return {}, .Sector_Read_Error
	}

	master = (^Master_Record)(raw_data(buf[:]))^
	return master, .None
}
