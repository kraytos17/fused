// property_test.odin — randomized operation sequences with a model oracle
// and a final checker scan (audit roadmap: property-based testing).
//
// A deterministic PRNG drives mixed mutating ops (create, write,
// truncate, unlink, same-dir rename, xattr set/remove) against a scratch
// image through the mounter API. An in-memory model tracks expected file
// contents; every read is verified immediately and all files are
// re-verified at the end. A final journal+allocation checker scan must be
// completely clean: leftover chains on a clean shutdown path mean a leak.
//
// Deterministic by construction: fixed seed, unique names, hermetic
// scratch image. To explore, change PROP_SEED and rerun; the op log
// printed on failure replays the exact scenario.
#+build linux
package tests

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "src:fs"
import "src:fuse3"
import "src:mounter"

PROP_SCRATCH := "/dev/shm/fused_prop_test.img"
PROP_SEED :: u64(0xC0FFEE11)
PROP_OPS :: 200
PROP_MAX_LIVE :: 8

Prop_Rng :: struct {
	s: u64,
}

// prop_next advances a Knuth MMIX LCG; high bits are the usable output.
prop_next :: proc(rng: ^Prop_Rng) -> u64 {
	rng.s = rng.s * 6364136223846793005 + 1442695040888963407
	return rng.s >> 33
}

prop_below :: proc(rng: ^Prop_Rng, n: int) -> int {
	if n <= 0 {
		return 0
	}
	return int(prop_next(rng) % u64(n))
}

Prop_File :: struct {
	id:        int,
	data:      [dynamic]u8,
	has_xattr: bool,
	xattr:     [dynamic]u8,
	fi:        fuse3.File_Info,
}

prop_setup :: proc(t: ^testing.T, fsys: ^mounter.FS, vol: ^fs.Volume) -> bool {
	fd, ok := jtxn_format(t, PROP_SCRATCH)
	if !ok { return false }
	v, vok := open_volume_on_fd(fd)
	if !vok {
		os.close(fd)
		os.remove(PROP_SCRATCH)
		return false
	}
	vol^ = v
	fsys^ = {}
	mounter.init_fs_for_test(fsys, vol^)
	ctx := fuse3.Context {
		uid        = 1000,
		gid        = 1000,
		private_data = fsys,
	}
	fuse3.set_test_context(&ctx)
	return true
}

prop_teardown :: proc(fsys: ^mounter.FS) {
	// Mirror teardown_mounter: the live volume state (alloc cache) lives
	// in fsys.vol after init_fs_state, not in the caller's by-value copy.
	v := fsys.vol
	mounter.destroy_fs_for_test(fsys)
	close_test_volume(&v)
	os.remove(PROP_SCRATCH)
}

// log_op records a human-readable op line (heap copy: temp arenas are
// reset by begin_op, so tprintf results would dangle).
log_op :: proc(oplog: ^[dynamic]string, msg: string) {
	append(oplog, strings.clone(msg))
}

// test_prop_random_ops — randomized create/write/truncate/rename/unlink/xattr
// sequence against an in-memory model, verified by reads throughout and a
// clean checker scan at the end.
@(test)
test_prop_random_ops :: proc(t: ^testing.T) {
	fsys: mounter.FS
	vol: fs.Volume
	if !prop_setup(t, &fsys, &vol) {
		testing.fail(t)
		return
	}
	defer prop_teardown(&fsys)

	files := make([dynamic]^Prop_File, 0, 8, context.allocator)
	defer {
		for f in files {
			delete(f.data)
			delete(f.xattr)
			free(f)
		}
		delete(files)
	}
	oolog := make([dynamic]string, 0, PROP_OPS, context.allocator)
	defer {
		for s in oolog {
			delete(s)
		}
		delete(oolog)
	}
	failed := false
	next_id := 0
	rng := Prop_Rng{s = PROP_SEED}

	for op := 0; op < PROP_OPS && !failed; op += 1 {
		choice := prop_below(&rng, 100)

		if choice < 15 && len(files) < PROP_MAX_LIVE {
			// create a fresh file (unique name: no aliasing, no reuse)
			id := next_id
			next_id += 1
			pbuf: [32]u8
			s := fmt.bprintf(pbuf[:], "/ptest_%d", id)
			pbuf[len(s)] = 0
			f := new(Prop_File, context.allocator)
			f.id = id
			f.data = make([dynamic]u8, 0, 0, context.allocator)
			f.xattr = make([dynamic]u8, 0, 0, context.allocator)
			log_op(&oolog, fmt.tprintf("op %d: create %d", op, id))
			if rc := mounter.fused_create(cstring(raw_data(pbuf[:])), posix.mode_t{.IRUSR, .IWUSR}, &f.fi); rc != 0 {
				testing.expect(t, false, oolog[len(oolog) - 1])
				failed = true
				free(f)
				continue
			}
			append(&files, f)
		} else if choice < 45 && len(files) > 0 {
			// write random bytes at a random offset (gaps zero-fill).
			// A zero-byte write is a no-op (kernel parity: it does not
			// extend the file), so the model only grows when n > 0.
			f := files[prop_below(&rng, len(files))]
			off := prop_below(&rng, len(f.data) + 16)
			n := prop_below(&rng, 49)
			// NOTE: stack, not temp: fused_* resets the temp arena on
			// entry (begin_op), so a temp caller buffer would be
			// clobbered by the callee's own temp allocations.
			chunk_buf: [48]u8
			chunk := chunk_buf[:n]
			for i in 0 ..< n {
				chunk[i] = u8(prop_next(&rng) & 0xff)
			}
			if n > 0 {
				need := off + n
				if len(f.data) < need {
					resize(&f.data, need)
				}
				copy(f.data[off:], chunk[:n])
			}
			pbuf: [32]u8
			s := fmt.bprintf(pbuf[:], "/ptest_%d", f.id)
			pbuf[len(s)] = 0
			log_op(&oolog, fmt.tprintf("op %d: write %d off=%d n=%d", op, f.id, off, n))
			got := mounter.fused_write(cstring(raw_data(pbuf[:])), raw_data(chunk), c.size_t(n), posix.off_t(off), &f.fi)
			if int(got) != n {
				testing.expect(t, false, oolog[len(oolog) - 1])
				failed = true
			}
		} else if choice < 57 && len(files) > 0 {
			// truncate (grow zero-fills, shrink drops the tail)
			f := files[prop_below(&rng, len(files))]
			new_size := prop_below(&rng, len(f.data) + 32)
			resize(&f.data, new_size)
			pbuf: [32]u8
			s := fmt.bprintf(pbuf[:], "/ptest_%d", f.id)
			pbuf[len(s)] = 0
			log_op(&oolog, fmt.tprintf("op %d: truncate %d to %d", op, f.id, new_size))
			if rc := mounter.fused_truncate(cstring(raw_data(pbuf[:])), posix.off_t(new_size), &f.fi); rc != 0 {
				testing.expect(t, false, oolog[len(oolog) - 1])
				failed = true
			}
		} else if choice < 77 && len(files) > 0 {
			// read back and compare against the model
			f := files[prop_below(&rng, len(files))]
			total := len(f.data)
			off := prop_below(&rng, total + 1)
			n := prop_below(&rng, 65)
			want_len := 0
			if off < total {
				want_len = min(n, total - off)
			}
			rbuf: [1024]u8
			buf := rbuf[:]
			pbuf: [32]u8
			s := fmt.bprintf(pbuf[:], "/ptest_%d", f.id)
			pbuf[len(s)] = 0
			log_op(&oolog, fmt.tprintf("op %d: read %d off=%d n=%d", op, f.id, off, n))
			got := mounter.fused_read(cstring(raw_data(pbuf[:])), raw_data(buf), c.size_t(n), posix.off_t(off), &f.fi)
			if int(got) != want_len || !bytes_equal(buf[:int(got)], f.data[off:off + want_len]) {
				testing.expectf(t, false, "op %d: read %d off=%d n=%d want=%d got=%d", op, f.id, off, n, want_len, int(got))
				failed = true
			}
		} else if choice < 85 && len(files) > 0 {
			// unlink (model forgets the file; teardown removes leftovers)
			idx := prop_below(&rng, len(files))
			f := files[idx]
			pbuf: [32]u8
			s := fmt.bprintf(pbuf[:], "/ptest_%d", f.id)
			pbuf[len(s)] = 0
			log_op(&oolog, fmt.tprintf("op %d: unlink %d", op, f.id))
			if rc := mounter.fused_unlink(cstring(raw_data(pbuf[:]))); rc != 0 {
				testing.expect(t, false, oolog[len(oolog) - 1])
				failed = true
				continue
			}
			ordered_remove(&files, idx)
			delete(f.data)
			delete(f.xattr)
			free(f)
		} else if choice < 92 && len(files) > 0 {
			// same-dir rename (slot stays put, so the open handle stays valid)
			f := files[prop_below(&rng, len(files))]
			id := next_id
			next_id += 1
			oldp: [32]u8
			os := fmt.bprintf(oldp[:], "/ptest_%d", f.id)
			oldp[len(os)] = 0
			newp: [32]u8
			ns := fmt.bprintf(newp[:], "/ptest_%d", id)
			newp[len(ns)] = 0
			log_op(&oolog, fmt.tprintf("op %d: rename %d -> %d", op, f.id, id))
			if rc := mounter.fused_rename(cstring(raw_data(oldp[:])), cstring(raw_data(newp[:])), 0); rc != 0 {
				testing.expect(t, false, oolog[len(oolog) - 1])
				failed = true
				continue
			}
			f.id = id
		} else if len(files) > 0 {
			// xattr set/remove/get cycle
			f := files[prop_below(&rng, len(files))]
			pbuf: [32]u8
			s := fmt.bprintf(pbuf[:], "/ptest_%d", f.id)
			pbuf[len(s)] = 0
			path := cstring(raw_data(pbuf[:]))
			if !f.has_xattr || prop_below(&rng, 2) == 0 {
				n := 1 + prop_below(&rng, 16)
				vbuf: [16]u8
				val := vbuf[:n]
				for i in 0 ..< n {
					val[i] = u8(prop_next(&rng) & 0xff)
				}
				log_op(&oolog, fmt.tprintf("op %d: setxattr %d len=%d", op, f.id, n))
				if rc := mounter.fused_setxattr(path, "user.k", raw_data(val), c.size_t(n), 0); rc != 0 {
					testing.expect(t, false, oolog[len(oolog) - 1])
					failed = true
					continue
				}
				resize(&f.xattr, 0)
				append(&f.xattr, ..val)
				f.has_xattr = true
			} else {
				log_op(&oolog, fmt.tprintf("op %d: removexattr %d", op, f.id))
				if rc := mounter.fused_removexattr(path, "user.k"); rc != 0 {
					testing.expectf(t, false, "op %d: removexattr %d rc=%d", op, f.id, int(rc))
					failed = true
					continue
				}
				clear(&f.xattr)
				f.has_xattr = false
			}
			// read back immediately (missing → -ENODATA, never 0)
			pb: [64]u8
			probe := pb[:]
			got := mounter.fused_getxattr(path, "user.k", raw_data(probe), c.size_t(len(probe)))
			if f.has_xattr {
				if int(got) != len(f.xattr) || !bytes_equal(probe[:int(got)], f.xattr[:]) {
					testing.expectf(t, false, "op %d: getxattr %d want=%d got=%d", op, f.id, len(f.xattr), int(got))
					failed = true
				}
			} else if got != -c.int(posix.ENODATA) {
				testing.expectf(t, false, "op %d: getxattr %d after remove want=-ENODATA got=%d", op, f.id, int(got))
				failed = true
			}
		}
	}

	if failed {
		for s in oolog {
			fmt.println(s)
		}
		return
	}

	// Full re-verification: every file reads back exactly.
	for f in files {
		pbuf: [32]u8
		s := fmt.bprintf(pbuf[:], "/ptest_%d", f.id)
		pbuf[len(s)] = 0
		path := cstring(raw_data(pbuf[:]))
		buf := make([]u8, len(f.data) + 16, context.allocator)
		defer delete(buf)
		got := mounter.fused_read(path, raw_data(buf), c.size_t(len(buf)), 0, &f.fi)
		testing.expect(t, int(got) == len(f.data), "final content length matches model")
		testing.expect(t, bytes_equal(buf[:int(got)], f.data[:]), "final content matches model")
		if f.has_xattr {
			probe := make([]u8, 64, context.allocator)
			defer delete(probe)
			n := mounter.fused_getxattr(path, "user.k", raw_data(probe), c.size_t(len(probe)))
			testing.expect(t, int(n) == len(f.xattr), "final xattr size matches model")
			testing.expect(t, bytes_equal(probe[:int(n)], f.xattr[:]), "final xattr matches model")
		}
	}

	// Checker scan must be completely clean: no overlaps, no dangling
	// links, no orphans, no free-space drift.
	rep := fs.check_image(&fsys.vol)
	defer fs.check_report_destroy(&rep)
	testing.expect_value(t, rep.errors, 0)
	testing.expect_value(t, rep.warnings, 0)
	if rep.errors != 0 || rep.warnings != 0 {
		for &fnd in rep.findings {
			fmt.println(fnd.code, fnd.detail)
		}
	}

	// Best-effort cleanup so the scratch image stays tidy (it is deleted
	// below regardless).
	for f in files {
		pbuf: [32]u8
		s := fmt.bprintf(pbuf[:], "/ptest_%d", f.id)
		pbuf[len(s)] = 0
		mounter.fused_unlink(cstring(raw_data(pbuf[:])))
	}
}
