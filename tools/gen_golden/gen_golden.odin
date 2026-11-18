// gen_golden.odin — generate tests/golden/rev{7,8}.img compat fixtures.
//
// Usage (from repo root):
//     make golden   # regenerates tests/golden/rev{7,8}.img + .list
//
// Each image is a 1M volume with a fixed logical tree (see TREE below):
// /Kernel, /docs/readme.txt, one LFN file, one symlink, and (rev 8 only)
// one xattr. The .list files pin the logical content (kinds, sizes,
// targets, xattrs); tests/golden_compat_test.odin verifies a live image
// matches its .list plus the embedded file bytes. Timestamps are
// wall-clock and deliberately NOT compared.
package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "src:fs"
import "src:fuse3"
import "src:mounter"

KERNEL_DATA := "golden kernel payload 0123456789 abcdefghijklmnopqrstuvwxyz\n"
README_DATA := "golden readme\n"
LONG_NAME := "this_is_a_long_file_name_01.txt"
LONG_DATA := "long name content\n"
LINK_PATH := "/link"
LINK_TARGET := "/Kernel"
XATTR_NAME := "user.comment"
XATTR_REV8 := "golden-rev8"

Spec :: struct {
	file:     string,
	features: fs.Features,
	rev_min:  u8,
	rev_max:  u8,
}

SPECS := [?]Spec {
	{file = "tests/golden/rev7.img", features = {.Uid_Gid}, rev_min = 7, rev_max = 7},
	{file = "tests/golden/rev8.img", features = {.Uid_Gid, .XAttr}, rev_min = 8, rev_max = 8},
}

// cstr formats a NUL-terminated test path into a stack buffer. Caller
// buffers must outlive the call (never the temp arena: begin_op frees it).
cstr :: proc(buf: []u8, format: string, args: ..any) -> cstring {
	s := fmt.bprintf(buf, format, ..args)
	buf[len(s)] = 0
	return cstring(raw_data(buf))
}

fail :: proc(msg: string, args: ..any) {
	fmt.eprintf(msg, ..args)
	fmt.eprintf("\n")
	os.exit(1)
}

make_tree :: proc(fsys: ^mounter.FS, want_xattr: bool) {
	pbuf: [256]u8
	kernel := KERNEL_DATA
	readme := README_DATA
	longd := LONG_DATA
	fi: fuse3.File_Info
	if rc := mounter.fused_create(cstr(pbuf[:], "/Kernel"), {.IRUSR, .IWUSR}, &fi); rc != 0 {
		fail("create /Kernel: %d", rc)
	}
	if rc := mounter.fused_write("/Kernel", raw_data(transmute([]u8)kernel), len(kernel), 0, &fi);
	   rc != c.int(len(kernel)) {
		fail("write /Kernel: %d", rc)
	}
	if rc := mounter.fused_mkdir("/docs", {.IRUSR, .IWUSR, .IXUSR}); rc != 0 {
		fail("mkdir /docs: %d", rc)
	}
	if rc := mounter.fused_create(cstr(pbuf[:], "/docs/readme.txt"), {.IRUSR, .IWUSR}, &fi);
	   rc != 0 {
		fail("create readme: %d", rc)
	}
	if rc := mounter.fused_write(
		"/docs/readme.txt",
		raw_data(transmute([]u8)readme),
		len(readme),
		0,
		&fi,
	); rc != c.int(len(readme)) {
		fail("write readme: %d", rc)
	}
	if rc := mounter.fused_create(cstr(pbuf[:], "/%s", LONG_NAME), {.IRUSR, .IWUSR}, &fi);
	   rc != 0 {
		fail("create long: %d", rc)
	}
	if rc := mounter.fused_write(
		cstr(pbuf[:], "/%s", LONG_NAME),
		raw_data(transmute([]u8)longd),
		len(longd),
		0,
		&fi,
	); rc != c.int(len(longd)) {
		fail("write long: %d", rc)
	}
	if rc := mounter.fused_symlink(
		cstr(pbuf[:], "%s", LINK_TARGET),
		cstr(pbuf[128:], "%s", LINK_PATH),
	); rc != 0 {
		fail("symlink: %d", rc)
	}
	if want_xattr {
		xval := XATTR_REV8
		if rc := mounter.fused_setxattr(
			"/Kernel",
			cstr(pbuf[:], "%s", XATTR_NAME),
			raw_data(transmute([]u8)xval),
			len(xval),
			0,
		); rc != 0 {
			fail("setxattr: %d", rc)
		}
	}
}

// list_tree walks the volume and appends stable listing lines: F/D/L/X.
// One subdir level is enough for the fixed tree; recursion is bounded.
list_tree :: proc(vol: ^fs.Volume, sb: ^strings.Builder) {
	walk :: proc(
		vol: ^fs.Volume,
		sb: ^strings.Builder,
		dir: string,
		loc: fs.Chain_Location,
		depth: int,
	) {
		if depth > 4 {
			return
		}

		entries, err := fs.read_directory_entries(vol, loc.cluster, loc.offset)
		if err != .None {
			fail("walk %s: %v", dir, err)
		}

		defer delete(entries)
		for &w in entries {
			name: string
			if .LFN in w.entry.flags {
				n, ok := fs.resolve_lfn(vol, &w.entry, context.temp_allocator)
				if !ok {
					fail("lfn resolve %s", dir)
				}
				name = n
			} else {
				name = fs.entry_short_name(&w.entry)
			}

			full := strings.join([]string{dir, name}, "/", context.temp_allocator)
			if .Directory in w.entry.flags {
				strings.write_string(sb, fmt.tprintf("D %s\n", full))
				walk(vol, sb, full, fs.data_chain_of(w.entry), depth + 1)
			} else if .Link in w.entry.flags {
				raw, rerr := fs.read_chain(vol, fs.data_chain_of(w.entry), context.temp_allocator)
				if rerr != .None {
					fail("readlink %s", full)
				}
				target := string(raw[:min(len(raw), int(w.entry.file_size))])
				strings.write_string(sb, fmt.tprintf("L %s -> %s\n", full, target))
			} else {
				strings.write_string(sb, fmt.tprintf("F %d %s\n", w.entry.file_size, full))
				if .XAttr in vol.master.features && w.entry.xattr_cluster != 0 {
					attrs, aerr := fs.xattr_load(vol, &w.entry)
					if aerr != .None {
						fail("xattr %s: %v", full, aerr)
					}
					defer {
						for &a in attrs {
							delete(a.name)
							delete(a.value)
						}
						delete(attrs)
					}
					for &a in attrs {
						strings.write_string(
							sb,
							fmt.tprintf("X %s %s=%s\n", full, string(a.name), string(a.value)),
						)
					}
				}
			}
		}
	}

	// Resolve the root location from the live master: the synthetic root
	// entry carries the current chain head.
	master_loc := fs.Chain_Location {
		fs.Cluster(vol.master.root_cluster),
		fs.Sector_Offset(vol.master.root_sector_index),
	}
	walk(vol, sb, "", master_loc, 0)
}

gen_one :: proc(spec: Spec) {
	fmt.printf("gen %s (rev %d, features %v)\n", spec.file, spec.rev_max, spec.features)
	fd, ferr := os.open(spec.file, {.Read, .Write, .Create, .Trunc})
	if ferr != nil {
		fail("open %s: %v", spec.file, ferr)
	}

	ferr2 := fs.format_image(
		fd,
		fs.Format_Params {
			size = 1 << 20,
			cluster_size = 16,
			features = spec.features,
			rev_min = spec.rev_min,
			rev_max = spec.rev_max,
			demo_data = {},
		},
	)
	if ferr2 != .None {
		os.close(fd)
		fail("format %s: %v", spec.file, ferr2)
	}

	vol, verr := open_on_fd(fd)
	if verr != .None {
		os.close(fd)
		fail("open %s: %v", spec.file, verr)
	}

	fsys := new(mounter.FS)
	mounter.init_fs_for_test(fsys, vol)
	ctx := fuse3.Context {
		uid          = 1000,
		gid          = 1000,
		private_data = fsys,
	}

	fuse3.set_test_context(&ctx)
	make_tree(fsys, .XAttr in spec.features)
	// Take the live volume back before teardown.
	live := fsys.vol
	mounter.destroy_fs_for_test(fsys)
	free(fsys)

	sb := strings.builder_make()
	list_tree(&live, &sb)
	fs.volume_close(&live)

	list_path := strings.join([]string{spec.file[:len(spec.file) - 4], ".list"}, "")
	if werr := os.write_entire_file(list_path, transmute([]u8)strings.to_string(sb)); werr != nil {
		fail("write %s: %v", list_path, werr)
	}
	fmt.printf("wrote %s + %s\n", spec.file, list_path)
}

// open_on_fd mirrors tests.open_volume_on_fd (the generator is a separate
// package and cannot import the test package).
open_on_fd :: proc(fd: ^os.File) -> (fs.Volume, fs.FS_Error) {
	master, merr := fs.read_master_record(fd)
	if merr != .None {
		return {}, merr
	}

	vol := fs.Volume {
		disk   = fd,
		master = master,
	}

	fs.alloc_cache_init(&vol.cache, &vol.master)
	fs.dir_cache_init(&vol.dir_cache)
	return vol, .None
}

main :: proc() {
	if err := os.make_directory_all("tests/golden"); err != nil && err != .Exist {
		fail("mkdir tests/golden: %v", err)
	}
	for spec in SPECS {
		gen_one(spec)
	}
}
