// xattr.odin — FUSE extended-attribute callbacks (setxattr/getxattr/listxattr/removexattr).
#+build linux
package mounter

import "base:runtime"
import "core:c"
import "core:log"
import "core:mem"
import "core:strings"
import "src:fs"
import "src:fuse3"

// _xattr_upsert replaces the value of the named attr or appends a new one.
// The caller has already enforced Create/Replace preconditions and owns
// attrs (loaded by xattr_load, freed by the caller's deferred destroy).
@(private = "file")
_xattr_upsert :: proc(
	attrs: ^[dynamic]fs.XAttr,
	attr_name: string,
	value: [^]c.char,
	size: c.size_t,
) {
	for &a in attrs^ {
		if a.name == attr_name {
			delete(a.value)
			a.value = make([]u8, int(size))
			if size > 0 {
				mem.copy(raw_data(a.value), value, int(size))
			}
			return
		}
	}

	append(attrs, fs.XAttr{name = strings.clone(attr_name), value = make([]u8, int(size))})
	if size > 0 {
		mem.copy(raw_data(attrs^[len(attrs^) - 1].value), value, int(size))
	}
}

// fused_setxattr sets an extended attribute on a file or directory.
fused_setxattr :: proc "c" (
	path: cstring,
	name: cstring,
	value: [^]c.char,
	size: c.size_t,
	flags: c.int,
) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	context.logger = fsys.logger
	defer end_op(fsys)

	attr_name := string(name)
	if len(attr_name) == 0 || len(attr_name) > fs.XATTR_NAME_MAX {
		return fuse3.nix(.EINVAL)
	}
	if size > fs.XATTR_SIZE_MAX {
		return fuse3.nix(.E2BIG)
	}

	entry, entry_cluster, entry_offset, entry_idx, _, _, rerr := resolve_entry(fsys, path, nil)
	if rerr != .None {
		return fs_error_to_errno(rerr)
	}

	attrs, load_err := fs.xattr_load(&fsys.vol, &entry)
	defer {
		for &a in attrs {
			delete(a.name)
			delete(a.value)
		}
		delete(attrs)
	}
	if load_err != .None {
		return fuse3.nix(.EIO)
	}

	exists := false
	for &a in attrs {
		if a.name == attr_name {
			exists = true
			break
		}
	}
	// Parse the ABI word once; downstream switches on set membership.
	xflags := transmute(fuse3.Xattr_Flags)(flags)
	if .Create in xflags && exists {
		return fuse3.nix(.EEXIST)
	}
	if .Replace in xflags && !exists {
		return fuse3.nix(.ENODATA)
	}

	_xattr_upsert(&attrs, attr_name, value, size)
	if serr := fs.xattr_store(&fsys.vol, &entry, attrs[:]); serr != .None {
		return fuse3.nix(.EIO)
	}

	reinit_free_sectors(fsys)
	if werr := write_entry_at(
		fsys,
		fs.File_Identity{entry_cluster, entry_offset, entry_idx},
		&entry,
	); werr != .None {
		return fs_error_to_errno(werr)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("setxattr: %s %s (%d bytes)", path, attr_name, size)
	return 0
}

// fused_getxattr gets an extended attribute value.
//   size == 0        → return required size (probe)
//   size <  required → return -ERANGE
//   otherwise        → copy value and return its length
fused_getxattr :: proc "c" (
	path: cstring,
	name: cstring,
	value: [^]c.char,
	size: c.size_t,
) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	context.logger = fsys.logger
	defer end_op(fsys)

	entry, _, _, _, _, _, rerr := resolve_entry(fsys, path, nil)
	if rerr != .None {
		return fs_error_to_errno(rerr)
	}

	val, found := fs.xattr_get(&fsys.vol, &entry, string(name))
	defer delete(val)
	if !found {
		return fuse3.nix(.ENODATA)
	}
	if size == 0 {
		return c.int(len(val))
	}
	if c.size_t(len(val)) > size {
		return fuse3.nix(.ERANGE)
	}
	if len(val) > 0 {
		mem.copy(value, raw_data(val), len(val))
	}

	log.debugf("getxattr: %s %s (%d bytes)", path, name, len(val))
	return c.int(len(val))
}

// fused_listxattr lists extended attribute names (NUL-separated).
//   size == 0 → return required buffer length (probe)
//   too small → return -ERANGE
fused_listxattr :: proc "c" (path: cstring, list: [^]c.char, size: c.size_t) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	context.logger = fsys.logger
	defer end_op(fsys)

	entry, _, _, _, _, _, rerr := resolve_entry(fsys, path, nil)
	if rerr != .None {
		return fs_error_to_errno(rerr)
	}

	attrs, load_err := fs.xattr_load(&fsys.vol, &entry)
	defer {
		for &a in attrs {
			delete(a.name)
			delete(a.value)
		}
		delete(attrs)
	}
	if load_err != .None {
		return fuse3.nix(.EIO)
	}

	needed: c.size_t
	for &a in attrs {
		needed += c.size_t(len(a.name)) + 1
	}
	if size == 0 {
		return c.int(needed)
	}
	if needed > size {
		return fuse3.nix(.ERANGE)
	}

	off: c.size_t
	for &a in attrs {
		mem.copy(rawptr(&list[off]), raw_data(a.name), len(a.name))
		off += c.size_t(len(a.name))
		list[off] = 0
		off += 1
	}

	log.debugf("listxattr: %s (%d names)", path, len(attrs))
	return c.int(needed)
}

// fused_removexattr removes an extended attribute.
fused_removexattr :: proc "c" (path: cstring, name: cstring) -> c.int {
	context = runtime.default_context()
	fsys := begin_op()
	context.logger = fsys.logger
	defer end_op(fsys)

	entry, entry_cluster, entry_offset, entry_idx, _, _, rerr := resolve_entry(fsys, path, nil)
	if rerr != .None {
		return fs_error_to_errno(rerr)
	}

	removed, err := fs.xattr_remove(&fsys.vol, &entry, string(name))
	if err != .None {
		return fuse3.nix(.EIO)
	}
	if !removed {
		return fuse3.nix(.ENODATA)
	}

	reinit_free_sectors(fsys)
	if werr := write_entry_at(
		fsys,
		fs.File_Identity{entry_cluster, entry_offset, entry_idx},
		&entry,
	); werr != .None {
		return fs_error_to_errno(werr)
	}

	path_cache_invalidate_all(fsys)
	log.debugf("removexattr: %s %s", path, name)
	return 0
}
