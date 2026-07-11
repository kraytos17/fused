// structure.odin — On-disk format for fused.
//
// Every struct is #packed. Sector size is fixed at 512 bytes.
#+build linux
package fs

Sector        :: distinct u64 // absolute sector number on disk
Cluster       :: distinct u64 // cluster index
Sector_Offset :: distinct u16 // sector offset within a cluster

SECTOR_SIZE                :: 512
CLUSTER_ENTRIES_PER_SECTOR :: 32
DIR_ENTRIES_PER_SECTOR     :: 10
DEFAULT_CLUSTER_SIZE       :: 16
DEFAULT_IMAGE_SIZE         :: 1 * 1024 * 1024 // 1 MB
FUSED_SIG                  :: [7]u8{'F', 'U', 'S', 'E', 'D', 0, 0}

#assert(SECTOR_SIZE / size_of(Cluster_Map_Entry) == CLUSTER_ENTRIES_PER_SECTOR)
#assert(SECTOR_SIZE / size_of(Cluster_Entry)     == CLUSTER_ENTRIES_PER_SECTOR)
#assert(DIR_ENTRIES_PER_SECTOR * size_of(Directory_Entry) <= SECTOR_SIZE)
#assert((DIR_ENTRIES_PER_SECTOR + 1) * size_of(Directory_Entry) >  SECTOR_SIZE)

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
	Allocated,  // bit 0
	LFN,        // bit 1
	Directory,  // bit 2
	Read_Only,  // bit 3
	Link,       // bit 4
	Exists,     // bit 5
	No_Write,   // bit 6
	No_Read,    // bit 7
	No_Execute, // bit 8
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
	Corrupt_Master_Record,
	No_Space,
	Entry_Not_Found,
	Not_A_Directory,
	Not_A_File,
	Sector_Read_Error,
	Sector_Write_Error,
	Name_Too_Long,
}

// MasterRecord — sector 0, 512 bytes
Master_Record :: struct #packed #all_or_none {
	sig:                [7]u8,
	rev:                u8,
	reserved0:          u8,
	reserved1:          u16,
	reserved2:          u32,
	cluster_map_offset: u64,
	cluster_map_size:   u64,
	cluster_size:       u64,
	root_sector_index:  u16,
	root_cluster:       u64,
	reserved3:          u16,
	reserved4:          u32,
	resv:               [455]u8,
	end_sig:            u16,
}
#assert(size_of(Master_Record) == 512)

// ClusterMapEntry — 16 bytes, 32 per sector
Cluster_Map_Entry :: struct #packed {
	sector_index:   u16,
	stored_cluster: u64,
	flags:          Cluster_Map_Flags,
	reserved1:      u32,
}
#assert(size_of(Cluster_Map_Entry) == 16)

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

// DirectoryEntry — 48 bytes, 10 per sector
Directory_Entry :: struct #packed {
	flags:          Dir_Flags,
	file_name:      [16]u8,
	sector_index:   u16,
	stored_cluster: u64,
	year:           u16,
	date_time:      Packed_Date_Time,
	file_size:      u64,
	reserved1:      u32,
	reserved2:      u16,
}
#assert(size_of(Directory_Entry) == 48)

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
