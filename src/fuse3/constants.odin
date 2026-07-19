// constants.odin — FUSE protocol constants and version markers.
#+build linux
package fuse3

import "core:c"

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

OPT_KEY_OPT     :: c.int(-1)
OPT_KEY_NONOPT  :: c.int(-2)
OPT_KEY_KEEP    :: c.int(-3)
OPT_KEY_DISCARD :: c.int(-4)

RENAME_NOREPLACE :: c.uint(1 << 0)
RENAME_EXCHANGE  :: c.uint(1 << 1)
RENAME_WHITEOUT  :: c.uint(1 << 2)

SEEK_DATA :: c.int(3)
SEEK_HOLE :: c.int(4)

FALLOC_FL_KEEP_SIZE      :: c.int(1 << 0)
FALLOC_FL_PUNCH_HOLE     :: c.int(1 << 1)
FALLOC_FL_ZERO_RANGE     :: c.int(1 << 2)
FALLOC_FL_COLLAPSE_RANGE :: c.int(1 << 3)
FALLOC_FL_INSERT_RANGE   :: c.int(1 << 5)

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

Cap_Flags :: bit_set[Cap_Bit; u32]
