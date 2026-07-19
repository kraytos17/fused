// structure.odin — On-disk format for fused.
//
// Every struct is #packed. Sector size is fixed at 512 bytes.
#+build linux
package fs

Sector        :: distinct u64 // absolute sector number on disk
Cluster       :: distinct u64 // cluster index
Sector_Offset :: distinct u16 // sector offset within a cluster
// Journal_Seq distinct type for journal sequence numbers
Journal_Seq   :: distinct u64 // journal transaction sequence number
// Byte_Offset distinct type for byte positions/sizes
Byte_Offset   :: distinct u64 // byte position or size in the image

SECTOR_SIZE                :: 512
CLUSTER_ENTRIES_PER_SECTOR :: 32
CLUSTER_MAP_ENTRIES_PER_SECTOR :: 64
DEFAULT_CLUSTER_SIZE       :: 16
DEFAULT_IMAGE_SIZE         :: 1 * 1024 * 1024 // 1 MB
FUSED_SIG                  :: [7]u8{'F', 'U', 'S', 'E', 'D', 0, 0}

#assert(size_of(Cluster_Map_Entry) == 8)
#assert(SECTOR_SIZE / size_of(Cluster_Map_Entry) == CLUSTER_MAP_ENTRIES_PER_SECTOR)
#assert(SECTOR_SIZE / size_of(Cluster_Entry)     == CLUSTER_ENTRIES_PER_SECTOR)
#assert(DIR_ENTRY_SIZE_V5 * DIR_ENTRIES_PER_SECTOR_V5 <= SECTOR_SIZE)
#assert((DIR_ENTRIES_PER_SECTOR_V5 + 1) * DIR_ENTRY_SIZE_V5 >  SECTOR_SIZE)
#assert(DIR_ENTRY_SIZE_V4 * DIR_ENTRIES_PER_SECTOR_V4 <= SECTOR_SIZE)
#assert((DIR_ENTRIES_PER_SECTOR_V4 + 1) * DIR_ENTRY_SIZE_V4 >  SECTOR_SIZE)

Cluster_Map_Flag :: enum u16 {
	Allocated, // bit 0
	Reserved,  // bit 1
	Full,      // bit 2
}
Cluster_Map_Flags :: bit_set[Cluster_Map_Flag; u16]

Cluster_Entry_Flag :: enum u8 {
	Allocated,    // bit 0
	Cluster_Map,  // bit 1
	Directory,    // bit 2
	File_Content, // bit 3
	LFN,          // bit 4
}
Cluster_Entry_State :: bit_set[Cluster_Entry_Flag; u8]

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
Dir_Flags :: bit_set[Dir_Flag; u16]

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
}

// Rev 4 images had a single rev byte at offset 7 and can't be parsed
// by the rev 5 Master_Record layout (rev_max would read garbage).
// Rev 5 added uid/gid in Directory_Entry (56-byte entries).
// Rev 6 added intent log for crash-consistent allocation transactions.
// Rev 7 added physical redo-log WAL (Journal_V2) for full crash consistency.
SUPPORTED_REV_MIN :: 6
SUPPORTED_REV_MAX :: 7

// Feature version map: each flag is associated with the rev it was introduced.
// When adding a new feature: add it here, add to ALL_SUPPORTED_FEATURES, bump SUPPORTED_REV_MAX.
Feature_Flag :: enum u64 {
	Uid_Gid     = 0,  // rev 5: uid/gid fields in Directory_Entry, 56-byte entries, 9 per sector
	Journal_V2  = 1,  // rev 7: physical redo-log WAL
}
Features :: bit_set[Feature_Flag; u64]

// All features that this version understands.
// When adding a new feature: add it here AND bump SUPPORTED_REV_MAX.
ALL_SUPPORTED_FEATURES :: Features{.Uid_Gid, .Journal_V2}

// Every defined Feature_Flag must be accounted for in ALL_SUPPORTED_FEATURES.
#assert(ALL_SUPPORTED_FEATURES <= Features{.Uid_Gid, .Journal_V2})

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
	sector_index:   u16,
	flags:          Cluster_Map_Flags,
	reserved1:      u32,
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

// Default for the current format version
DIR_ENTRIES_PER_SECTOR :: DIR_ENTRIES_PER_SECTOR_V5
DIR_ENTRY_SIZE :: DIR_ENTRY_SIZE_V5

dir_entry_size :: proc(features: Features) -> u16 {
	if .Uid_Gid in features {return DIR_ENTRY_SIZE_V5}
	return DIR_ENTRY_SIZE_V4
}

dir_entries_per_sector :: proc(features: Features) -> u16 {
	if .Uid_Gid in features {return DIR_ENTRIES_PER_SECTOR_V5}
	return DIR_ENTRIES_PER_SECTOR_V4
}

// DirectoryEntry — 56 bytes, 9 per sector (rev 5, with uid/gid)
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
}
#assert(size_of(Directory_Entry) == 56)

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

JOURNAL_MAGIC :: 0xF11E
Jv2_MAGIC :: 0xF11E0002

JOURNAL_SEQ_OFFSET       :: 0  // u64: next transaction seq (resv offset)
JOURNAL_WATERMARK_OFFSET :: 8  // u64: last fully-applied seq
JOURNAL_REGION_OFFSET    :: 16 // u64: journal region size in sectors

// Intent_Log_Entry — describes a single CE-table write (rev 6 format, 14 bytes).
Intent_Log_Entry :: struct #packed {
	cluster:         u64,
	sector_offset:   u16,
	ce_index:        u8,
	alloc_size:      u16,
	state:           u8,
}

// Journal_Entry — full Cluster_Entry data for rev 7 replay (24 bytes).
Journal_Entry :: struct #packed {
	cluster:          u64,
	ce_index:         u8,
	state:            u8,
	sector_start:     u16,
	alloc_size:       u16,
	next_cluster:     u64,
	next_sector_index: u16,
}

// Jv2_Record — one sector in the ring buffer, containing packed Journal_Entry records.
Jv2_Record :: struct #packed {
	entries: [JOURNAL_ENTRIES_PER_RECORD]Journal_Entry,
}
JOURNAL_ENTRIES_PER_RECORD :: 21  // 504 / 24, no padding needed
#assert(size_of(Jv2_Record) == 21 * 24)
#assert(size_of(Jv2_Record) <= SECTOR_SIZE)
#assert(size_of(Journal_Entry) == 24)

// Jv2_Header — one sector, starts every transaction in the ring buffer.
Jv2_Header :: struct #packed {
	magic:        u32,
	seq:          u64,
	rec_count:    u16,
	rec_sectors:  u16,
	committed:    u8,
	_pad:         [5]u8,
	header_crc:   u32,
	_resv:        [482]u8,
	tail_magic:   u32,
}
#assert(size_of(Jv2_Header) == SECTOR_SIZE)

// Intent_Log — single sector (512 bytes), rev 6 format.
Intent_Log :: struct #packed {
	magic:   u16,
	seq:     u64,
	count:   u16,
	entries: [MAX_JOURNAL_ENTRIES_v6]Intent_Log_Entry,
	_pad:    [12]u8,
	crc:     u32,
}
#assert(size_of(Intent_Log) <= SECTOR_SIZE)
MAX_JOURNAL_ENTRIES_v6 :: 34

#assert(size_of(Intent_Log_Entry) == 14)
