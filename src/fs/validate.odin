// validate.odin — Mount-time validation of MasterRecord.
#+build linux
package fs

validate_master :: proc(master: ^Master_Record, image_size: u64) -> FS_Error {
	// sig must be "FUSED\0\0" (7 bytes) — the rev field carries the version
	sig_ok := master.sig[0] == 'F' && master.sig[1] == 'U' && master.sig[2] == 'S' &&
	          master.sig[3] == 'E' && master.sig[4] == 'D' &&
	          master.sig[5] == 0 && master.sig[6] == 0

	if !sig_ok {
		return .Invalid_Signature
	}
	if master.rev < 2 {
		return .Invalid_Signature
	}
	if master.end_sig != 0x0BB0 {
		return .Invalid_Signature
	}
	if master.cluster_size == 0 || master.cluster_size > 65536 {
		return .Corrupt_Master_Record
	}
	if master.cluster_map_offset == 0 {
		return .Corrupt_Master_Record
	}

	sector_count := image_size / SECTOR_SIZE
	if u64(master.cluster_map_offset) >= sector_count {
		return .Corrupt_Master_Record
	}

	total_clusters := sector_count / u64(master.cluster_size)
	if master.cluster_map_size > total_clusters {
		return .Corrupt_Master_Record
	}
	return .None
}
