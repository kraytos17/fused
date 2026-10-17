// structure.odin — On-disk format for fused.
//
// Every struct is #packed. Sector size is fixed at 512 bytes.
#+build linux
package fs

Sector :: distinct u64 // absolute sector number on disk
Cluster :: distinct u64 // cluster index
Sector_Offset :: distinct u16 // sector offset within a cluster
// Journal_Seq distinct type for journal sequence numbers
Journal_Seq :: distinct u64 // journal transaction sequence number
// Byte_Offset distinct type for byte positions/sizes
Byte_Offset :: distinct u64 // byte position or size in the image

// Chain_Location names a position in a sector chain: the starting cluster
// and the sector offset within it. It bundles the (cluster, offset) input
// pairs threaded through allocation, resolution, and chain walks. Results
// that name NEW locations keep their tuples.
Chain_Location :: struct {
	cluster: Cluster,
	offset:  Sector_Offset,
}

// File_Identity names a directory entry by its parent location: the
// directory cluster, the sector offset within it, and the entry index.
// Unlike the structs above it is NOT packed: it is in-memory only (map
// keys, file handles), never serialized. It is the shared vocabulary for
// every "which entry" triple (fh_parts returns it; entry_at_index and
// write_entry_at take it).
File_Identity :: struct {
	dir_cluster: Cluster,
	dir_offset:  Sector_Offset,
	entry_index: int,
}

SECTOR_SIZE :: 512
CLUSTER_ENTRIES_PER_SECTOR :: 32
CLUSTER_MAP_ENTRIES_PER_SECTOR :: 64
DEFAULT_CLUSTER_SIZE :: 16
DEFAULT_IMAGE_SIZE :: 1 * 1024 * 1024 // 1 MB
FUSED_SIG :: [7]u8{'F', 'U', 'S', 'E', 'D', 0, 0}
END_SIG :: 0x0BB0 // Master_Record.end_sig sentinel

#assert(size_of(Cluster_Map_Entry) == 8)
#assert(SECTOR_SIZE / size_of(Cluster_Map_Entry) == CLUSTER_MAP_ENTRIES_PER_SECTOR)
#assert(SECTOR_SIZE / size_of(Cluster_Entry) == CLUSTER_ENTRIES_PER_SECTOR)
#assert(DIR_ENTRY_SIZE_V5 * DIR_ENTRIES_PER_SECTOR_V5 <= SECTOR_SIZE)
#assert((DIR_ENTRIES_PER_SECTOR_V5 + 1) * DIR_ENTRY_SIZE_V5 > SECTOR_SIZE)
#assert(DIR_ENTRY_SIZE_V4 * DIR_ENTRIES_PER_SECTOR_V4 <= SECTOR_SIZE)
#assert((DIR_ENTRIES_PER_SECTOR_V4 + 1) * DIR_ENTRY_SIZE_V4 > SECTOR_SIZE)
#assert(DIR_ENTRY_SIZE_V6 * DIR_ENTRIES_PER_SECTOR_V6 == SECTOR_SIZE)

Cluster_Map_Flag :: enum u16 {
	Allocated, // bit 0
	Reserved, // bit 1
	Full, // bit 2
}
Cluster_Map_Flags :: bit_set[Cluster_Map_Flag;u16]

Cluster_Entry_Flag :: enum u8 {
	Allocated, // bit 0
	Cluster_Map, // bit 1
	Directory, // bit 2
	File_Content, // bit 3
	LFN, // bit 4
	XAttr, // bit 5: extended-attribute data chain
}
Cluster_Entry_State :: bit_set[Cluster_Entry_Flag;u8]

Dir_Flag :: enum u16 {
	Allocated,
	LFN,
	Directory,
	Read_Only,
	Link,
	Exists,
	No_Write,
	No_Read,
	No_Execute,
}
Dir_Flags :: bit_set[Dir_Flag;u16]

Packed_Date_Time :: bit_field u32 {
	month:    u32 | 4,
	date:     u32 | 5,
	hour:     u32 | 5,
	minute:   u32 | 6,
	second:   u32 | 6,
	reserved: u32 | 6,
}

Allocation_Kind :: enum u8 {
	Directory,
	File_Content,
	Cluster_Map,
	LFN,
	XAttr,
}

FS_Error :: enum {
	None,
	Cluster_Not_Found,
	Cluster_Map_Full,
	Multi_Sector_Cluster_Map_Unsupported,
	Invalid_Signature,
	Version_Too_Old,
	Version_Too_New,
	Feature_Not_Supported,
	Corrupt_Master_Record,
	No_Space,
	Entry_Not_Found,
	Not_A_Directory,
	Not_A_File,
	Sector_Read_Error,
	Sector_Write_Error,
	Name_Too_Long,
	Corrupt_XAttr_Blob,
}

// Rev 4 images had a single rev byte at offset 7 and can't be parsed
// by the rev 5 Master_Record layout (rev_max would read garbage).
// Rev 5 added uid/gid in Directory_Entry (56-byte entries).
// Rev 6 added an intent log for crash-consistent allocation transactions;
// the intent log was removed and rev 6 images are no longer mountable.
// Rev 7 added a physical redo-log WAL for full crash consistency (now the
// only journal; its feature bit is retired, see Feature_Flag).
// Rev 8 added XAttr support (extended attributes stored in a dedicated chain).
SUPPORTED_REV_MIN :: 7
SUPPORTED_REV_MAX :: 8

// Feature version map: each flag is associated with the rev it was introduced.
// When adding a new feature: add it here, add to ALL_SUPPORTED_FEATURES, bump SUPPORTED_REV_MAX.
Feature_Flag :: enum u64 {
	Uid_Gid = 0, // rev 5: uid/gid fields in Directory_Entry, 56-byte entries, 9 per sector
	// Bit 1 (rev 7 journal WAL selector) is retired: the WAL is the only
	// journal, so no flag is needed. Images with bit 1 set are rejected
	// by validation (unknown feature bit); reformat to migrate.
	XAttr   = 2, // rev 8: xattr_cluster field in Directory_Entry, 64-byte entries, 8 per sector
}
Features :: bit_set[Feature_Flag;u64]

// All features that this version understands.
// When adding a new feature: add it here AND bump SUPPORTED_REV_MAX.
ALL_SUPPORTED_FEATURES :: Features{.Uid_Gid, .XAttr}

// Every defined Feature_Flag must be accounted for in ALL_SUPPORTED_FEATURES.
#assert(ALL_SUPPORTED_FEATURES <= Features{.Uid_Gid, .XAttr})

// MasterRecord — sector 0, 512 bytes
Master_Record :: struct #packed #all_or_none {
	sig:                [7]u8,
	rev_min:            u8,
	rev_max:            u8,
	features:           Features,
	cluster_map_offset: u64,
	cluster_map_size:   u64,
	cluster_size:       u64,
	root_sector_index:  u16,
	root_cluster:       u64,
	reserved3:          u16,
	reserved4:          u32,
	resv:               [453]u8,
	end_sig:            u16,
}
#assert(size_of(Master_Record) == 512)

// ClusterMapEntry — 8 bytes, 64 per sector
Cluster_Map_Entry :: struct #packed {
	sector_index: u16,
	flags:        Cluster_Map_Flags,
	reserved1:    u32,
}
#assert(size_of(Cluster_Map_Entry) == 8)

// ClusterEntry — 16 bytes, 32 per sector
Cluster_Entry :: struct #packed {
	state:             Cluster_Entry_State,
	next_sector_index: u16,
	next_cluster:      u64,
	allocation_size:   u16,
	sector_start:      u16,
	reserved1:         u8,
}
#assert(size_of(Cluster_Entry) == 16)

// DirectoryEntry sizes
DIR_ENTRY_SIZE_V4 :: 48
DIR_ENTRIES_PER_SECTOR_V4 :: 10

DIR_ENTRY_SIZE_V5 :: 56
DIR_ENTRIES_PER_SECTOR_V5 :: 9

// Rev 8: xattr_cluster field appended to Directory_Entry.
DIR_ENTRY_SIZE_V6 :: 64
DIR_ENTRIES_PER_SECTOR_V6 :: 8

// Default for the current format version
DIR_ENTRIES_PER_SECTOR :: DIR_ENTRIES_PER_SECTOR_V6
DIR_ENTRY_SIZE :: DIR_ENTRY_SIZE_V6

// Dir_Entry_Layout binds a feature flag to the directory-entry size and
// entries-per-sector it implies.  dir_entry_size / dir_entries_per_sector
// walk this table (highest-revision feature first) and fall back to the V4
// defaults when no layout feature is present.  A future revision that changes
// the entry layout adds one row here instead of editing two parallel chains.
Dir_Entry_Layout :: struct {
	feature:    Feature_Flag,
	size:       u16,
	per_sector: u16,
}

DIR_ENTRY_LAYOUTS :: [2]Dir_Entry_Layout {
	{.XAttr, DIR_ENTRY_SIZE_V6, DIR_ENTRIES_PER_SECTOR_V6},
	{.Uid_Gid, DIR_ENTRY_SIZE_V5, DIR_ENTRIES_PER_SECTOR_V5},
}

dir_entry_size :: proc(features: Features) -> u16 {
	for layout in DIR_ENTRY_LAYOUTS {
		if layout.feature in features { return layout.size }
	}
	return DIR_ENTRY_SIZE_V4
}

dir_entries_per_sector :: proc(features: Features) -> u16 {
	for layout in DIR_ENTRY_LAYOUTS {
		if layout.feature in features { return layout.per_sector }
	}
	return DIR_ENTRIES_PER_SECTOR_V4
}

// DirectoryEntry — 64 bytes, 8 per sector (rev 8, with xattr support)
// 56 bytes, 9 per sector (rev 5-7, without xattr support)
// or 48 bytes, 10 per sector (rev 4, without uid/gid)
Directory_Entry :: struct #packed {
	flags:           Dir_Flags,
	file_name:       [16]u8,
	sector_index:    u16,
	stored_cluster:  u64,
	uid:             u32,
	gid:             u32,
	year:            u16,
	date_time:       Packed_Date_Time,
	file_size:       u64,
	atime_date_time: Packed_Date_Time,
	atime_year:      u16,
	xattr_cluster:   u64,
}
#assert(size_of(Directory_Entry) == 64)

// LFN_Pointer — packed into file_name[16] when the LFN flag is set
LFN_Pointer :: struct #packed {
	cluster: u64,
	size:    u32,
	sector:  u16,
	_pad:    u16,
}
#assert(size_of(LFN_Pointer) == 16)

// Extent_Run — flat description of a contiguous sector range
Extent_Run :: struct {
	sector: Sector,
	count:  u16,
}

JOURNAL_WAL_MAGIC :: 0xF11E0002

JOURNAL_SEQ_OFFSET :: 0 // u64: next transaction seq (resv offset)
JOURNAL_WATERMARK_OFFSET :: 8 // u64: last fully-applied seq
JOURNAL_REGION_OFFSET :: 16 // u64: journal region size in sectors

// Journal_Entry — full Cluster_Entry data for rev 7 replay (24 bytes).
Journal_Entry :: struct #packed {
	cluster:           u64,
	ce_index:          u8,
	state:             u8,
	sector_start:      u16,
	alloc_size:        u16,
	next_cluster:      u64,
	next_sector_index: u16,
}

// Journal_Record — one sector in the ring buffer, containing packed Journal_Entry records.
Journal_Record :: struct #packed {
	entries: [JOURNAL_ENTRIES_PER_RECORD]Journal_Entry,
}

JOURNAL_ENTRIES_PER_RECORD :: 21 // 504 / 24, no padding needed
#assert(size_of(Journal_Record) == 21 * 24)
#assert(size_of(Journal_Record) <= SECTOR_SIZE)
#assert(size_of(Journal_Entry) == 24)

// Journal_Header — one sector, starts every transaction in the ring buffer.
Journal_Header :: struct #packed {
	magic:       u32,
	seq:         u64,
	rec_count:   u16,
	rec_sectors: u16,
	committed:   u8,
	_pad:        [5]u8,
	header_crc:  u32,
	_resv:       [482]u8,
	tail_magic:  u32,
}
#assert(size_of(Journal_Header) == SECTOR_SIZE)

MAX_JOURNAL_ENTRIES :: 34

// XAttr blob — packed records stored in a dedicated cluster chain.
// The chain is found by scanning the owning cluster's CE table for an
// entry whose state carries .XAttr (mirrors LFN pointer resolution).
XATTR_MAGIC :: 0x58415452 // "XATR"
XATTR_NAME_MAX :: 255
XATTR_SIZE_MAX :: 65536

XAttr_Blob_Header :: struct #packed {
	magic: u32,
	count: u16,
	_pad:  u16,
	total: u32, // Σ over records of (6 + name_len + value_len); blob len is 12 + total
}
#assert(size_of(XAttr_Blob_Header) == 12)

XAttr_Record_Header :: struct #packed {
	name_len:  u16,
	value_len: u32,
}
#assert(size_of(XAttr_Record_Header) == 6)
