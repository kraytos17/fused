// diskio.odin — Sector-level read/write wrappers around ^os.File.
// Uses pread/pwrite — no seek needed, thread-safe.
#+build linux
package fs

import "core:os"

// Fault_Class selects an I/O class for single-shot injection.
Fault_Class :: enum {
	None,
	Reads,
	Writes,
	Syncs,
}

// IO_Fault is a deterministic fault injector and I/O counter for tests.
// The zero value disables injection (production behavior). Enable it to
// fail reads/writes/syncs past a threshold (the first N succeed) or to
// count I/O per operation. Single-shot mode fails exactly one op — the
// fail_once_at-th (1-based) call of fail_once_class — then lets all
// later I/O of every class succeed, rollback included; threshold mode
// cannot express that (it faults the rollback too), which is what
// blocked late-fault enumeration. Single-threaded test volumes only.
IO_Fault :: struct {
	enabled:           bool,
	fail_reads_after:  u64,
	fail_writes_after: u64,
	fail_syncs_after:  u64,
	reads:             u64,
	writes:            u64,
	syncs:             u64,
	// Single-shot injection: ops of fail_once_class are counted and
	// when the count lands exactly on fail_once_at, that op fails and
	// the shot disarms (fail_once_class resets to .None). fail_once_at
	// = 0 never fires. Counting continues so tests can assert where
	// the fault landed. The threshold fields stay independent and keep
	// applying to their own classes.
	fail_once_class:   Fault_Class,
	fail_once_at:      u64,
}

// io_fails counts one op of the given class and reports whether it
// fails. Threshold mode: every op past fail_<class>_after fails.
// Single-shot mode: the op whose class count lands exactly on
// fail_once_at fails and disarms the shot, so later ops — rollback I/O
// included — succeed. A disabled fault (enabled = false) never counts
// and never fails: production behavior.
@(private = "file")
_io_fails :: proc(f: ^IO_Fault, class: Fault_Class) -> bool {
	if !f.enabled {
		return false
	}

	count: ^u64
	threshold: u64
	switch class {
	case .None:
		return false
	case .Reads:
		count = &f.reads
		threshold = f.fail_reads_after
	case .Writes:
		count = &f.writes
		threshold = f.fail_writes_after
	case .Syncs:
		count = &f.syncs
		threshold = f.fail_syncs_after
	}

	count^ += 1
	if count^ > threshold {
		return true
	}
	if f.fail_once_class == class && count^ == f.fail_once_at {
		f.fail_once_class = .None
		return true
	}
	return false
}

// sector_read reads one 512-byte sector from disk at the given sector number
sector_read :: proc(vol: ^Volume, sector: Sector, buf: []u8) -> FS_Error {
	if _io_fails(&vol.fault, .Reads) {
		return .Sector_Read_Error
	}

	n, err := os.read_at(vol.disk, buf, i64(u64(sector) * SECTOR_SIZE))
	if err != nil || n != len(buf) {
		return .Sector_Read_Error
	}
	return .None
}

// sector_write writes one 512-byte sector to disk
sector_write :: proc(vol: ^Volume, sector: Sector, buf: []u8) -> FS_Error {
	if _io_fails(&vol.fault, .Writes) {
		return .Sector_Write_Error
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
	if _io_fails(&vol.fault, .Writes) {
		return .Sector_Write_Error
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
	if _io_fails(&vol.fault, .Syncs) {
		return false
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
