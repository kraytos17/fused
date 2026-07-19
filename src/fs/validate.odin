// validate.odin — Mount-time validation of MasterRecord.
#+build linux
package fs

validate_master :: proc(master: ^Master_Record, image_size: Byte_Offset) -> FS_Error {
	if master.sig != FUSED_SIG {
		return .Invalid_Signature
	}
	if master.rev_max < SUPPORTED_REV_MIN {
		return .Version_Too_Old
	}
	if master.rev_min > SUPPORTED_REV_MAX {
		return .Version_Too_New
	}

	unknown := master.features & ~ALL_SUPPORTED_FEATURES
	if unknown != {} {
		return .Feature_Not_Supported
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

	sector_count := u64(image_size) / SECTOR_SIZE
	if u64(master.cluster_map_offset) >= sector_count {
		return .Corrupt_Master_Record
	}

	total_clusters := sector_count / u64(master.cluster_size)
	if master.cluster_map_size > total_clusters {
		return .Corrupt_Master_Record
	}
	return .None
}
