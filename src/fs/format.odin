// format.odin — Image construction shared by the format tool and tests.
//
// format_image lays out a raw image from sector 0:
//   MasterRecord → ClusterMap table → zeroed journal region
//   → root cluster (CE table, root directory entry, optional demo file).
#+build linux
package fs

import "core:log"
import "core:os"
import "core:time"

// Format_Params describes the image to build.
Format_Params :: struct {
	size:         u64,
	cluster_size: u64,
	features:     Features,
	rev_min:      u8,
	rev_max:      u8,
	// demo_data, when non-empty, is embedded as /Kernel at the root
	// (mirrors the format tool's demo file).
	demo_data:    []u8,
}

// Format_Geometry holds the derived layout numbers for an image size.
Format_Geometry :: struct {
	total_sectors:     u64,
	total_clusters:    u64,
	cm_sectors:        u64,
	journal_sectors:   u64,
	metadata_sectors:  u64,
	reserved_clusters: u64,
	root_cluster:      u64,
}

format_geometry :: proc(size, cluster_size: u64) -> Format_Geometry {
	total_sectors := size / SECTOR_SIZE
	total_clusters := total_sectors / cluster_size
	cme_per_sector := u64(CLUSTER_MAP_ENTRIES_PER_SECTOR)
	cm_sectors := (total_clusters + cme_per_sector - 1) / cme_per_sector
	journal_sectors := max(64, total_clusters / 10)
	metadata_sectors := 1 + cm_sectors + journal_sectors
	reserved_clusters := (metadata_sectors + cluster_size - 1) / cluster_size
	return {
		total_sectors     = total_sectors,
		total_clusters    = total_clusters,
		cm_sectors        = cm_sectors,
		journal_sectors   = journal_sectors,
		metadata_sectors  = metadata_sectors,
		reserved_clusters = reserved_clusters,
		root_cluster      = reserved_clusters,
	}
}

// format_image formats the open (empty) file fd as a fused image. The file
// is truncated to size and written from sector 0.
@(optimization_mode="favor_size")
format_image :: proc(fd: ^os.File, p: Format_Params) -> FS_Error {
	if terr := os.truncate(fd, i64(p.size)); terr != nil {
		return .Sector_Write_Error
	}

	g := format_geometry(p.size, p.cluster_size)
	total_clusters := g.total_clusters
	cm_sectors := g.cm_sectors
	journal_sectors := g.journal_sectors
	reserved_clusters := g.reserved_clusters
	root_cluster := g.root_cluster

	master: Master_Record
	master.sig = FUSED_SIG
	master.rev_min = p.rev_min
	master.rev_max = p.rev_max
	master.features = p.features
	master.cluster_map_offset = 1
	master.cluster_map_size = total_clusters
	master.cluster_size = p.cluster_size
	master.root_sector_index = 1
	master.root_cluster = root_cluster
	master.end_sig = 0x0BB0
	// Region size / seq are written unconditionally; v6 images never read
	// the region size, so this is harmless.
	journal_v2_set_region_size(&master, journal_sectors)
	journal_seq_init(&master)

	vol := Volume{disk = fd}
	{
		master_buf: [SECTOR_SIZE]u8
		(^Master_Record)(&master_buf[0])^ = master
		if sector_write(&vol, 0, master_buf[:]) != .None {
			return .Sector_Write_Error
		}
	}

	// Cluster map: reserved clusters + the root cluster are in use.
	cm_buf: [SECTOR_SIZE]u8
	entries := (^[CLUSTER_MAP_ENTRIES_PER_SECTOR]Cluster_Map_Entry)(&cm_buf[0])
	for sec_idx in 0 ..< cm_sectors {
		cm_buf = {}
		base := int(sec_idx) * CLUSTER_MAP_ENTRIES_PER_SECTOR
		for ei in 0 ..< CLUSTER_MAP_ENTRIES_PER_SECTOR {
			ci := base + ei
			if u64(ci) >= total_clusters { break }
			switch {
			case u64(ci) < reserved_clusters:
				entries[ei] = {flags = {.Reserved, .Full}}
			case u64(ci) == reserved_clusters:
				entries[ei] = {flags = {.Allocated}}
			}
		}
		if sector_write(&vol, Sector(1 + sec_idx), cm_buf[:]) != .None {
			return .Sector_Write_Error
		}
	}

	// Zero the journal region (right after the CME table).
	zero: [SECTOR_SIZE]u8
	for i: u64; i < journal_sectors; i += 1 {
		if sector_write(&vol, Sector(1 + cm_sectors + i), zero[:]) != .None {
			return .Sector_Write_Error
		}
	}

	// Root cluster: CE table with root dir entry and optional demo file.
	root_sector := root_cluster * p.cluster_size
	ce_buf: [SECTOR_SIZE]u8
	ce_table := (^[CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry)(&ce_buf[0])
	ce_table[0] = {
		state           = {.Allocated, .Cluster_Map},
		allocation_size = 1,
		sector_start    = 0,
	}
	ce_table[1] = {
		state           = {.Allocated, .Directory},
		allocation_size = 1,
		sector_start    = 1,
	}
	if len(p.demo_data) > 0 {
		demo_sectors := u16((len(p.demo_data) + SECTOR_SIZE - 1) / SECTOR_SIZE)
		ce_table[2] = {
			state           = {.Allocated, .File_Content},
			allocation_size = demo_sectors,
			sector_start    = 2,
		}
	}
	if sector_write(&vol, Sector(root_sector), ce_buf[:]) != .None {
		return .Sector_Write_Error
	}

	dir_buf: [SECTOR_SIZE]u8
	if len(p.demo_data) > 0 {
		now := time.now()
		y, mo, d := time.date(now)
		h, m, s := time.clock(now)
		entry := Directory_Entry{
			flags           = {.Allocated, .Exists},
			sector_index    = 2,
			stored_cluster  = root_cluster,
			year            = u16(y),
			date_time       = {month = u32(int(mo)), date = u32(d), hour = u32(h), minute = u32(m), second = u32(s)},
			atime_year      = u16(y),
			atime_date_time = {month = u32(int(mo)), date = u32(d), hour = u32(h), minute = u32(m), second = u32(s)},
			file_size       = u64(len(p.demo_data)),
		}
		copy(entry.file_name[:], "Kernel")
		(^Directory_Entry)(&dir_buf[0])^ = entry
	}
	if sector_write(&vol, Sector(root_sector + 1), dir_buf[:]) != .None {
		return .Sector_Write_Error
	}
	if len(p.demo_data) > 0 {
		content_buf: [SECTOR_SIZE]u8
		copy(content_buf[:], p.demo_data)
		if sector_write(&vol, Sector(root_sector + 2), content_buf[:]) != .None {
			return .Sector_Write_Error
		}
	}

	log.debugf("format: size=%d cluster_size=%d clusters=%d reserved=%d root=%d",
		p.size, p.cluster_size, total_clusters, reserved_clusters, root_cluster)
	return .None
}
