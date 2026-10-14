// constants.odin — FUSE protocol constants and version markers.
#+build linux
package fuse3

import "base:intrinsics"
import "core:c"

// log2 is the bit-position projection used by core:sys/posix flag enums:
// members below hold positions so their bit_sets transmute losslessly
// against the c.int ABI words.
log2 :: intrinsics.constant_log2

FUSE_USE_VERSION_MAJOR :: 3
FUSE_USE_VERSION_MINOR :: 18
FUSE_USE_VERSION :: FUSE_USE_VERSION_MAJOR * 100 + FUSE_USE_VERSION_MINOR // 318
FUSE_HOTFIX_VERSION :: 2

Readdir_Flags :: enum c.int {
	Defaults = 0,
	Plus     = 1 << 0,
}

Fill_Dir_Flags :: enum c.int {
	Defaults = 0,
	Plus     = 1 << 1,
}

Log_Level :: enum c.int {
	Emergency,
	Alert,
	Critical,
	Error,
	Warning,
	Notice,
	Info,
	Debug,
}

OPT_KEY_OPT :: c.int(-1)
OPT_KEY_NONOPT :: c.int(-2)
OPT_KEY_KEEP :: c.int(-3)
OPT_KEY_DISCARD :: c.int(-4)

Rename_Flag :: enum c.uint {
	No_Replace = log2(1 << 0),
	Exchange   = log2(1 << 1),
	Whiteout   = log2(1 << 2),
}

Rename_Flags :: bit_set[Rename_Flag;c.uint]

// xattr setxattr flags (linux/xattr.h). Members are bit *positions*
// (log2 of the C values, following core:sys/posix O_Flag_Bits), so the set
// transmutes losslessly against the c.int ABI word. Parsed into
// Xattr_Flags at the mounter boundary; the ABI parameter stays c.int.
Xattr_Flag :: enum c.int {
	Create  = log2(1 << 0), // fail if the attribute already exists
	Replace = log2(1 << 1), // fail if the attribute does not exist
}

Xattr_Flags :: bit_set[Xattr_Flag;c.int]


SEEK_DATA :: c.int(3)
SEEK_HOLE :: c.int(4)

// Buf wire flags (fuse_buf flags). Members are bit positions (log2 of the
// C values); the set transmutes losslessly against the Buf.flags word.
Buf_Flag :: enum c.int {
	Is_Fd   = log2(2),
	Fd_Seek = log2(4),
}

Buf_Flags :: bit_set[Buf_Flag;c.int]

Falloc_Flag :: enum c.int {
	Keep_Size      = log2(1 << 0),
	Punch_Hole     = log2(1 << 1),
	Zero_Range     = log2(1 << 2),
	Collapse_Range = log2(1 << 3),
	Insert_Range   = log2(1 << 5),
}

Falloc_Flags :: bit_set[Falloc_Flag;c.int]

Cap_Bit :: enum u32 {
	Async_Read, // 1<<0
	Posix_Locks, // 1<<1
	_Reserved_2, // bit 2 reserved by FUSE_CAP_* numbering
	Atomic_O_Trunc, // 1<<3
	Export_Support, // 1<<4
	_Reserved_5, // bit 5 reserved
	Dont_Mask, // 1<<6
	Splice_Write, // 1<<7
	Splice_Move, // 1<<8
	Splice_Read, // 1<<9
	Flock_Locks, // 1<<10
	Ioctl_Dir, // 1<<11
	Auto_Inval_Data, // 1<<12
	Readdir_Plus, // 1<<13
	Readdir_Plus_Auto, // 1<<14
	Async_Dio, // 1<<15
	Writeback_Cache, // 1<<16
	No_Open_Support, // 1<<17
	Parallel_Dirops, // 1<<18
	Posix_Acl, // 1<<19
	Handle_Killpriv, // 1<<20
	Handle_Killpriv_V2, // 1<<21
	_Reserved_22, // bit 22 reserved
	Cache_Symlinks, // 1<<23
	No_Opendir_Support, // 1<<24
	Explicit_Inval_Data, // 1<<25
	Expire_Only, // 1<<26
	Setxattr_Ext, // 1<<27
	Direct_Io_Allow_Mmap, // 1<<28
	Passthrough, // 1<<29
	No_Export_Support, // 1<<30
	Over_Io_Uring, // 1<<31
}

Cap_Flags :: bit_set[Cap_Bit;u32]
