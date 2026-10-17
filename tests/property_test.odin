// property_test.odin — randomized operation sequences with a model oracle
// and a final checker scan (audit roadmap: property-based testing).
//
// A deterministic PRNG drives mixed mutating ops (mkdir/rmdir, create,
// symlink, write, truncate, unlink, same-dir rename, cross-directory
// move, readdir verification, readlink verification, xattr set/remove)
// against a scratch image through the mounter API. An in-memory model tracks the expected tree and file
// contents; every read and listing is verified immediately and all files
// are re-verified at the end. A final journal+allocation checker scan
// must be completely clean: leftover chains on a clean shutdown path
// mean a leak.
//
// Directories are flat (all live directly under root) and names are a
// mix of short and long (>16 bytes, exercising the LFN path). Moves
// refresh the open handle via fused_open: handles name directory slots
// (ADR-003), so a handle opened before a cross-directory move would
// keep pointing at the old slot.
//
// Deterministic by construction: fixed seed, unique names, hermetic
// scratch image. To explore, change PROP_SEED and rerun; the op log
// printed on failure replays the exact scenario.
// scope: scratch image
#+build linux
package tests

import "core:c"
import "core:fmt"
import "core:os"
import "base:runtime"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "src:fs"
import "src:fuse3"
import "src:mounter"

PROP_SCRATCH := "/dev/shm/fused_prop_test.img"
PROP_SEED :: u64(0xC0FFEE11)
PROP_OPS :: 300
PROP_MAX_LIVE :: 8
PROP_MAX_DIRS :: 4

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
	dir:       int, // parent dir id; 0 is the root
	name:      string, // heap clone of the leaf name
	is_link:   bool,
	target:    string, // heap clone of the link target (links only)
	data:      [dynamic]u8, // regular files only
	has_xattr: bool, // regular files only
	xattr:     [dynamic]u8, // regular files only
	fi:        fuse3.File_Info, // regular files only
}

Prop_Dir :: struct {
	id:     int,
	parent: int, // parent dir id; 0 is the root
	depth:  int, // ancestor count (root is 0); mkdir caps at PROP_MAX_DEPTH
}

// Depth cap for new subdirectories (moves respect it too, so formatted
// paths always fit the stack buffers).
PROP_MAX_DEPTH :: 3

// log_op records a human-readable op line (heap copy: temp arenas are
// reset by begin_op, so tprintf results would dangle).
log_op :: proc(oplog: ^[dynamic]string, msg: string) {
	append(oplog, strings.clone(msg))
}

// prop_make_name generates a unique leaf name: short by default, long
// (>16 bytes, exercising the LFN path) one op in four. Heap-allocated;
// the caller owns it.
prop_make_name :: proc(rng: ^Prop_Rng, id: int) -> string {
	if prop_below(rng, 4) == 0 {
		return strings.clone(fmt.tprintf("ptest_%d_longname_%d", id, prop_below(rng, 1000)))
	}
	return strings.clone(fmt.tprintf("ptest_%d", id))
}

// prop_dir_parent returns the parent id of dir, or -1 if unknown
// (defensive: the model never drops a live dir).
prop_dir_parent :: proc(dirs: [dynamic]Prop_Dir, dir: int) -> int {
	if dir == 0 { return -1 }
	for d in dirs {
		if d.id == dir {
			return d.parent
		}
	}
	return -1
}

// prop_is_descendant reports whether d is anc itself or below it.
prop_is_descendant :: proc(dirs: [dynamic]Prop_Dir, anc, d: int) -> bool {
	cur := d
	for i := 0; i <= len(dirs); i += 1 {
		if cur == anc { return true }
		if cur == 0 { return false }
		cur = prop_dir_parent(dirs, cur)
		if cur < 0 { return false }
	}
	return false
}

// prop_subtree_height returns the longest descendant chain below dir
// (0 for a leaf). Bounded: the model never holds a cycle.
prop_subtree_height :: proc(dirs: [dynamic]Prop_Dir, dir: int) -> int {
	best := 0
	for d in dirs {
		if d.parent == dir {
			h := 1 + prop_subtree_height(dirs, d.id)
			if h > best { best = h }
		}
	}
	return best
}

// prop_format_path renders the full path of (dir, name) by walking
// ancestors root-ward (cycle-guarded; the model never holds one).
prop_format_path :: proc(buf: []u8, dirs: [dynamic]Prop_Dir, dir: int, name: string) -> cstring {
	chain: [PROP_MAX_DEPTH + 4]int
	n := 0
	cur := dir
	for cur != 0 && n < len(chain) {
		chain[n] = cur
		n += 1
		cur = prop_dir_parent(dirs, cur)
		if cur < 0 { break }
	}
	pos := 0
	for i := n - 1; i >= 0; i -= 1 {
		s := fmt.bprintf(buf[pos:], "/pdir_%d", chain[i])
		pos += len(s)
	}
	s := fmt.bprintf(buf[pos:], "/%s", name)
	pos += len(s)
	buf[pos] = 0
	return cstring(raw_data(buf))
}

// prop_format_dir renders a directory path (root is "/").
prop_format_dir :: proc(buf: []u8, dirs: [dynamic]Prop_Dir, dir: int) -> cstring {
	if dir == 0 {
		buf[0] = '/'
		buf[1] = 0
		return cstring(raw_data(buf))
	}
	chain: [PROP_MAX_DEPTH + 4]int
	n := 0
	cur := dir
	for cur != 0 && n < len(chain) {
		chain[n] = cur
		n += 1
		cur = prop_dir_parent(dirs, cur)
		if cur < 0 { break }
	}
	pos := 0
	for i := n - 1; i >= 0; i -= 1 {
		s := fmt.bprintf(buf[pos:], "/pdir_%d", chain[i])
		pos += len(s)
	}
	buf[pos] = 0
	return cstring(raw_data(buf))
}

// Prop_Name_List collects readdir results into inline storage (no heap:
// the filler is a "c" proc outside the test's tracking-allocator
// context, so heap ownership across the boundary mis-frees). Capacity
// covers PROP_MAX_LIVE files + PROP_MAX_DIRS subdirs; overflow stops
// the fill, which fails the comparison loudly instead of truncating
// silently.
Prop_Name_List :: struct {
	buf:   [PROP_MAX_LIVE + PROP_MAX_DIRS][64]u8,
	lens:  [PROP_MAX_LIVE + PROP_MAX_DIRS]int,
	count: int,
}

prop_collect :: proc "c" (
	buf: rawptr,
	name: cstring,
	stbuf: ^fuse3.Stat,
	off: posix.off_t,
	flags: c.int,
) -> c.int {
	context = runtime.default_context()
	l := (^Prop_Name_List)(buf)
	s := string(name)
	if s == "." || s == ".." { return 0 }
	if l.count >= len(l.buf) || len(s) >= len(l.buf[0]) { return 1 }
	copy(l.buf[l.count][:], s)
	l.lens[l.count] = len(s)
	l.count += 1
	return 0
}

// prop_list_at views collected entry i (valid while l is alive).
prop_list_at :: proc(l: ^Prop_Name_List, i: int) -> string {
	return string(l.buf[i][:l.lens[i]])
}

// prop_verify_dir lists dir through readdir and compares the full entry
// set against the model. Returns false (after reporting) on mismatch.
prop_verify_dir :: proc(
	t: ^testing.T,
	fsys: ^mounter.FS,
	files: [dynamic]^Prop_File,
	dirs: [dynamic]Prop_Dir,
	dir: int,
) -> bool {
	dbuf: [192]u8
	dpath := prop_format_dir(dbuf[:], dirs, dir)
	list: Prop_Name_List
	if rc := mounter.fused_readdir(dpath, &list, prop_collect, 0, nil, 0); rc != 0 {
		testing.expectf(t, false, "readdir dir %d rc=%d", dir, int(rc))
		return false
	}
	// Model set: files parented here, plus subdirs parented here.
	// (tprintf temporaries: each call allocates fresh arena memory, so
	// no two entries alias — the stack-copy trap that bit the checker's
	// DupName scan.)
	want := make([dynamic]string, 0, 16, context.temp_allocator)
	defer delete(want)
	for f in files {
		if f.dir == dir {
			append(&want, f.name)
		}
	}
	for d in dirs {
		if d.parent == dir {
			append(&want, fmt.tprintf("pdir_%d", d.id))
		}
	}
	if list.count != len(want) {
		testing.expectf(t, false, "readdir dir %d: got %d entries, want %d", dir, list.count, len(want))
		return false
	}
	for i in 0 ..< list.count {
		got := prop_list_at(&list, i)
		found := false
		for w in want {
			if got == w {
				found = true
				break
			}
		}
		if !found {
			testing.expectf(t, false, "readdir dir %d: unexpected entry %q", dir, got)
			return false
		}
	}
	return true
}

// test_prop_random_ops — randomized create/symlink/write/truncate/
// rename/move/mkdir/rmdir/readdir/readlink/xattr sequence against an
// in-memory model, verified by reads and listings throughout and a
// clean checker scan at the end.
@(test)
test_prop_random_ops :: proc(t: ^testing.T) {
	fsys: mounter.FS
	if !scratch_fs(t, PROP_SCRATCH, &fsys) {
		testing.fail(t)
		return
	}
	defer close_scratch_fs(&fsys, PROP_SCRATCH)

	files := make([dynamic]^Prop_File, 0, 8, context.allocator)
	defer {
		for f in files {
			delete(f.name)
			delete(f.target)
			delete(f.data)
			delete(f.xattr)
			free(f)
		}
		delete(files)
	}
	dirs := make([dynamic]Prop_Dir, 0, 4, context.allocator)
	defer delete(dirs)
	oolog := make([dynamic]string, 0, PROP_OPS, context.allocator)
	defer {
		for s in oolog {
			delete(s)
		}
		delete(oolog)
	}
	failed := false
	// Entity ids start at 1: id 0 is the implicit root, so no real
	// file or directory may claim it (path formatting keys off 0).
	next_id := 1
	rng := Prop_Rng{s = PROP_SEED}

	for op := 0; op < PROP_OPS && !failed; op += 1 {
		choice := prop_below(&rng, 100)

		if choice < 10 && len(dirs) < PROP_MAX_DIRS {
			// mkdir a fresh directory under a random parent that
			// still has depth headroom (root always qualifies)
			id := next_id
			next_id += 1
			parent := 0
			depth := 1
			if len(dirs) > 0 {
				// collect eligible parents first so the choice is
				// uniform over dirs with headroom, not over retries
				cands: [PROP_MAX_DIRS]int
				nc := 0
				for d in dirs {
					if d.depth < PROP_MAX_DEPTH {
						cands[nc] = d.id
						nc += 1
					}
				}
				if nc > 0 {
					parent = cands[prop_below(&rng, nc)]
					for d in dirs {
						if d.id == parent {
							depth = d.depth + 1
							break
						}
					}
				}
			}
			pbuf: [192]u8
			nbuf: [32]u8
			ns := fmt.bprintf(nbuf[:], "pdir_%d", id)
			p := prop_format_path(pbuf[:], dirs, parent, string(nbuf[:len(ns)]))
			log_op(&oolog, fmt.tprintf("op %d: mkdir %d in dir %d", op, id, parent))
			if rc := mounter.fused_mkdir(p, posix.mode_t{.IRUSR, .IWUSR, .IXUSR}); rc != 0 {
				testing.expect(t, false, oolog[len(oolog) - 1])
				failed = true
				continue
			}
			append(&dirs, Prop_Dir{id = id, parent = parent, depth = depth})
		} else if choice < 15 && len(dirs) > 0 {
			// rmdir an empty directory: no files and no subdirs
			// parented here (non-empty removals are the existing
			// ENOTEMPTY unit tests' territory, not the model)
			idx := -1
			for i in 0 ..< len(dirs) {
				empty := true
				for f in files {
					if f.dir == dirs[i].id {
						empty = false
						break
					}
				}
				if empty {
					for d in dirs {
						if d.parent == dirs[i].id {
							empty = false
							break
						}
					}
				}
				if empty {
					idx = i
					break
				}
			}
			if idx < 0 {
				log_op(&oolog, fmt.tprintf("op %d: skip rmdir (none empty)", op))
				continue
			}
			id := dirs[idx].id
			dbuf: [192]u8
			dpath := prop_format_dir(dbuf[:], dirs, id)
			log_op(&oolog, fmt.tprintf("op %d: rmdir %d", op, id))
			if rc := mounter.fused_rmdir(dpath); rc != 0 {
				testing.expect(t, false, oolog[len(oolog) - 1])
				failed = true
				continue
			}
			ordered_remove(&dirs, idx)
		} else if choice < 17 && len(dirs) > 0 {
			// move a directory: legal unless the target is itself or
			// below itself (circular → EINVAL, tree unchanged), or the
			// target is its current parent (no-op rename onto an
			// existing dir → EISDIR, tree unchanged)
			di := prop_below(&rng, len(dirs))
			D := dirs[di].id
			T := 0
			if prop_below(&rng, 2) == 0 {
				T = dirs[prop_below(&rng, len(dirs))].id
			}
			tdepth := 0
			for d in dirs {
				if d.id == T {
					tdepth = d.depth
					break
				}
			}
			if tdepth + 1 + prop_subtree_height(dirs, D) > PROP_MAX_DEPTH + 1 {
				log_op(&oolog, fmt.tprintf("op %d: skip dirmove %d (too deep)", op, D))
				continue
			}
			nbuf: [32]u8
			ns := fmt.bprintf(nbuf[:], "pdir_%d", D)
			leaf := string(nbuf[:len(ns)])
			oldp: [192]u8
			old := prop_format_path(oldp[:], dirs, dirs[di].parent, leaf)
			newp: [192]u8
			new := prop_format_path(newp[:], dirs, T, leaf)
			st: fuse3.Stat
			if T == dirs[di].parent {
				log_op(&oolog, fmt.tprintf("op %d: dirmove %d no-op (same parent)", op, D))
				if rc := mounter.fused_rename(old, new, 0); rc != -c.int(posix.EISDIR) {
					testing.expectf(t, false, "op %d: dirmove no-op want=-EISDIR got=%d", op, int(rc))
					failed = true
				}
			} else if prop_is_descendant(dirs, D, T) {
				log_op(&oolog, fmt.tprintf("op %d: dirmove %d -> dir %d (circular)", op, D, T))
				if rc := mounter.fused_rename(old, new, 0); rc != -c.int(posix.EINVAL) {
					testing.expectf(t, false, "op %d: dirmove circular want=-EINVAL got=%d", op, int(rc))
					failed = true
					continue
				}
				if rc := mounter.fused_getattr(old, &st, nil); rc != 0 {
					testing.expectf(t, false, "op %d: moved-away source still resolves rc=%d", op, int(rc))
					failed = true
				}
			} else {
				log_op(&oolog, fmt.tprintf("op %d: dirmove %d -> dir %d", op, D, T))
				if rc := mounter.fused_rename(old, new, 0); rc != 0 {
					testing.expectf(t, false, "op %d: dirmove %d rc=%d", op, D, int(rc))
					failed = true
					continue
				}
				delta := (tdepth + 1) - dirs[di].depth
				dirs[di].parent = T
				dirs[di].depth = tdepth + 1
				for i in 0 ..< len(dirs) {
					if i != di && prop_is_descendant(dirs, D, dirs[i].id) {
						dirs[i].depth += delta
					}
				}
			}
		} else if choice < 24 && len(files) < PROP_MAX_LIVE {
			// create a fresh file (or symlink, 1 in 5) in a random
			// directory (unique name: no aliasing, no reuse)
			id := next_id
			next_id += 1
			parent := 0
			if len(dirs) > 0 && prop_below(&rng, 2) == 0 {
				parent = dirs[prop_below(&rng, len(dirs))].id
			}
			name := prop_make_name(&rng, id)
			f := new(Prop_File, context.allocator)
			f.id = id
			f.dir = parent
			f.name = name
			f.data = make([dynamic]u8, 0, 0, context.allocator)
			f.xattr = make([dynamic]u8, 0, 0, context.allocator)
			pbuf: [192]u8
			p := prop_format_path(pbuf[:], dirs, parent, name)
			if prop_below(&rng, 5) == 0 {
				// symlink: short target usually, multi-sector (600 B,
				// exercising the target chain) sometimes
				f.is_link = true
				n := 0
				tbuf: [768]u8
				if prop_below(&rng, 4) == 0 {
					n = copy(tbuf[:], fmt.tprintf("tgt_%d_", id))
					for i := n; i < 600; i += 1 { tbuf[i] = 'x' }
					n = 600
				} else {
					n = copy(tbuf[:], fmt.tprintf("tgt_%d", id))
				}
				tbuf[n] = 0
				f.target = strings.clone(string(tbuf[:n]))
				log_op(&oolog, fmt.tprintf("op %d: symlink %d -> %d bytes in dir %d", op, id, n, parent))
				if rc := mounter.fused_symlink(cstring(raw_data(tbuf[:])), p); rc != 0 {
					testing.expect(t, false, oolog[len(oolog) - 1])
					failed = true
					delete(name)
					delete(f.target)
					free(f)
					continue
				}
				append(&files, f)
				continue
			}
			log_op(&oolog, fmt.tprintf("op %d: create %d in dir %d", op, id, parent))
			if rc := mounter.fused_create(p, posix.mode_t{.IRUSR, .IWUSR}, &f.fi); rc != 0 {
				testing.expect(t, false, oolog[len(oolog) - 1])
				failed = true
				delete(name)
				free(f)
				continue
			}
			append(&files, f)
		} else if choice < 44 && len(files) > 0 {
			// write random bytes at a random offset (gaps zero-fill).
			// A zero-byte write is a no-op (kernel parity: it does not
			// extend the file), so the model only grows when n > 0.
			// Symlinks take no data ops (the kernel only readlinks
			// them); drawing one here is a logged skip.
			f := files[prop_below(&rng, len(files))]
			if f.is_link {
				log_op(&oolog, fmt.tprintf("op %d: skip write (symlink %d)", op, f.id))
				continue
			}
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
			pbuf: [192]u8
			p := prop_format_path(pbuf[:], dirs, f.dir, f.name)
			log_op(&oolog, fmt.tprintf("op %d: write %d off=%d n=%d", op, f.id, off, n))
			got := mounter.fused_write(p, raw_data(chunk), c.size_t(n), posix.off_t(off), &f.fi)
			if int(got) != n {
				testing.expect(t, false, oolog[len(oolog) - 1])
				failed = true
			}
		} else if choice < 52 && len(files) > 0 {
			// truncate (grow zero-fills, shrink drops the tail)
			f := files[prop_below(&rng, len(files))]
			if f.is_link {
				log_op(&oolog, fmt.tprintf("op %d: skip truncate (symlink %d)", op, f.id))
				continue
			}
			new_size := prop_below(&rng, len(f.data) + 32)
			resize(&f.data, new_size)
			pbuf: [192]u8
			p := prop_format_path(pbuf[:], dirs, f.dir, f.name)
			log_op(&oolog, fmt.tprintf("op %d: truncate %d to %d", op, f.id, new_size))
			if rc := mounter.fused_truncate(p, posix.off_t(new_size), &f.fi); rc != 0 {
				testing.expect(t, false, oolog[len(oolog) - 1])
				failed = true
			}
		} else if choice < 66 && len(files) > 0 {
			// read back and compare against the model (readlink for
			// symlinks, verifying the full target including
			// multi-sector ones)
			f := files[prop_below(&rng, len(files))]
			pbuf: [192]u8
			p := prop_format_path(pbuf[:], dirs, f.dir, f.name)
			if f.is_link {
				lbuf: [1024]u8
				log_op(&oolog, fmt.tprintf("op %d: readlink %d", op, f.id))
				if rc := mounter.fused_readlink(p, raw_data(lbuf[:]), c.size_t(len(lbuf))); rc != 0 {
					testing.expectf(t, false, "op %d: readlink %d rc=%d", op, f.id, int(rc))
					failed = true
					continue
				}
				if string(lbuf[:len(f.target)]) != f.target || lbuf[len(f.target)] != 0 {
					testing.expectf(t, false, "op %d: readlink %d target mismatch", op, f.id)
					failed = true
				}
				continue
			}
			total := len(f.data)
			off := prop_below(&rng, total + 1)
			n := prop_below(&rng, 65)
			want_len := 0
			if off < total {
				want_len = min(n, total - off)
			}
			rbuf: [1024]u8
			buf := rbuf[:]
			log_op(&oolog, fmt.tprintf("op %d: read %d off=%d n=%d", op, f.id, off, n))
			got := mounter.fused_read(p, raw_data(buf), c.size_t(n), posix.off_t(off), &f.fi)
			if int(got) != want_len || !bytes_equal(buf[:int(got)], f.data[off:off + want_len]) {
				testing.expectf(t, false, "op %d: read %d off=%d n=%d want=%d got=%d", op, f.id, off, n, want_len, int(got))
				failed = true
			}
		} else if choice < 73 && len(files) > 0 {
			// unlink (model forgets the file; teardown removes leftovers)
			idx := prop_below(&rng, len(files))
			f := files[idx]
			pbuf: [192]u8
			p := prop_format_path(pbuf[:], dirs, f.dir, f.name)
			log_op(&oolog, fmt.tprintf("op %d: unlink %d", op, f.id))
			if rc := mounter.fused_unlink(p); rc != 0 {
				testing.expect(t, false, oolog[len(oolog) - 1])
				failed = true
				continue
			}
			ordered_remove(&files, idx)
			delete(f.name)
			delete(f.target)
			delete(f.data)
			delete(f.xattr)
			free(f)
		} else if choice < 80 && len(files) > 0 {
			// cross-directory move to a fresh name, then refresh the
			// open handle (handles track slots per ADR-003) and pin
			// the old path gone
			f := files[prop_below(&rng, len(files))]
			target := 0
			if len(dirs) > 0 {
				target = dirs[prop_below(&rng, len(dirs))].id
			}
			if target == f.dir && len(dirs) == 0 {
				log_op(&oolog, fmt.tprintf("op %d: skip move (nowhere to go)", op))
				continue
			}
			if target == f.dir {
				// pick a different target: root is always available
				target = 0
			}
			id := next_id
			next_id += 1
			new_name := prop_make_name(&rng, id)
			oldp: [192]u8
			old := prop_format_path(oldp[:], dirs, f.dir, f.name)
			newp: [192]u8
			new := prop_format_path(newp[:], dirs, target, new_name)
			log_op(&oolog, fmt.tprintf("op %d: move %d dir %d -> dir %d", op, f.id, f.dir, target))
			if rc := mounter.fused_rename(old, new, 0); rc != 0 {
				testing.expect(t, false, oolog[len(oolog) - 1])
				delete(new_name)
				failed = true
				continue
			}
			// Old path must be gone...
			st: fuse3.Stat
			if rc := mounter.fused_getattr(old, &st, nil); rc != -c.int(posix.ENOENT) {
				testing.expectf(t, false, "op %d: old path still resolves rc=%d", op, int(rc))
				delete(new_name)
				failed = true
				continue
			}
			// ...and the handle must track the new slot (regular
			// files only; links carry no open handle).
			if !f.is_link {
				if rc := mounter.fused_open(new, &f.fi); rc != 0 {
					testing.expectf(t, false, "op %d: reopen after move rc=%d", op, int(rc))
					delete(new_name)
					failed = true
					continue
				}
			}
			delete(f.name)
			f.name = new_name
			f.dir = target
			f.id = id
		} else if choice < 84 && len(files) > 0 {
			// same-dir rename (slot stays put, so the open handle stays valid)
			f := files[prop_below(&rng, len(files))]
			id := next_id
			next_id += 1
			new_name := prop_make_name(&rng, id)
			oldp: [192]u8
			old := prop_format_path(oldp[:], dirs, f.dir, f.name)
			newp: [192]u8
			new := prop_format_path(newp[:], dirs, f.dir, new_name)
			log_op(&oolog, fmt.tprintf("op %d: rename %d -> %d", op, f.id, id))
			if rc := mounter.fused_rename(old, new, 0); rc != 0 {
				testing.expect(t, false, oolog[len(oolog) - 1])
				delete(new_name)
				failed = true
				continue
			}
			delete(f.name)
			f.name = new_name
			f.id = id
		} else if choice < 90 {
			// list a random directory and compare the full set
			// against the model (also covers the empty listing)
			dir := 0
			if len(dirs) > 0 && prop_below(&rng, 2) == 0 {
				dir = dirs[prop_below(&rng, len(dirs))].id
			}
			log_op(&oolog, fmt.tprintf("op %d: readdir dir %d", op, dir))
			if !prop_verify_dir(t, &fsys, files, dirs, dir) {
				failed = true
			}
		} else if len(files) > 0 {
			// xattr set/remove/get cycle (regular files only)
			f := files[prop_below(&rng, len(files))]
			if f.is_link {
				log_op(&oolog, fmt.tprintf("op %d: skip xattr (symlink %d)", op, f.id))
				continue
			}
			pbuf: [192]u8
			path := prop_format_path(pbuf[:], dirs, f.dir, f.name)
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

	// Full re-verification: every file reads back exactly (readlink
	// for symlinks), and every directory lists exactly the model set.
	for f in files {
		pbuf: [192]u8
		path := prop_format_path(pbuf[:], dirs, f.dir, f.name)
		if f.is_link {
			lbuf: [1024]u8
			rc := mounter.fused_readlink(path, raw_data(lbuf[:]), c.size_t(len(lbuf)))
			testing.expect(t, rc == 0, "final readlink ok")
			testing.expect(t, string(lbuf[:len(f.target)]) == f.target, "final target matches model")
			testing.expect(t, lbuf[len(f.target)] == 0, "final target NUL-terminated")
			continue
		}
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
	if !prop_verify_dir(t, &fsys, files, dirs, 0) {
		failed = true
	}
	for d in dirs {
		if !prop_verify_dir(t, &fsys, files, dirs, d.id) {
			failed = true
		}
	}
	if failed {
		return
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
	// below regardless): files first, then directories leaves-first
	// (parents only become empty once their children are gone).
	for f in files {
		pbuf: [192]u8
		mounter.fused_unlink(prop_format_path(pbuf[:], dirs, f.dir, f.name))
	}
	for pass := 0; pass <= len(dirs) && len(dirs) > 0; pass += 1 {
		progress := false
		for i := len(dirs) - 1; i >= 0; i -= 1 {
			dbuf: [192]u8
			if mounter.fused_rmdir(prop_format_dir(dbuf[:], dirs, dirs[i].id)) == 0 {
				ordered_remove(&dirs, i)
				progress = true
			}
		}
		if !progress { break }
	}
}
