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

Fill_Dir_Flags :: enum c.int {
	Defaults = 0,
	Plus     = 1 << 1,
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


// Seek_Whence restricts lseek to the supported hole/data modes (SEEK_* from
// <fcntl.h>). Converted from the c.int ABI word at the fused_lseek boundary;
// anything else is ENOSYS (closed world).
Seek_Whence :: enum c.int {
	Data = 3,
	Hole = 4,
}

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
