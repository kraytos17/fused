// validate.odin — Mount-time validation of MasterRecord.
#+build linux
package fs

validate_master :: proc(master: ^Master_Record, image_size: u64) -> FS_Error {
	if master.sig != FUSED_SIG {
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
