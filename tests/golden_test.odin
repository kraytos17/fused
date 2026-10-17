// golden_test.odin — byte-stability fixtures for the on-disk format.
//
// Formats a deterministic scratch image per supported revision (no demo
// data: demo entries carry wall-clock timestamps) and compares FNV-1a
// hashes of the full image and of each 64 KiB chunk against stored
// constants. Any format drift — struct reorder, padding, geometry,
// zeroing — fails loudly naming the first differing chunk; the actual
// image is kept at GOLDEN_SCRATCH for xxd diffing. Regeneration is a
// deliberate act: paste the printed constants after verifying the diff
// is the intended format change (ADR-002), never blindly.
//
// The goldens also pin that fresh formats validate and that formatting
// twice yields identical bytes (no nondeterminism creep).
#+build linux
package tests

import "core:fmt"
import "core:os"
import "core:testing"
import "src:fs"

GOLDEN_SCRATCH := "/dev/shm/fused_golden_test.img"
GOLDEN_SIZE :: 1 << 20
GOLDEN_CHUNK :: 1 << 16

// golden_fnv1a hashes bytes with 64-bit FNV-1a (change detection only).
golden_fnv1a :: proc(data: []u8) -> u64 {
	h: u64 = 14695981039346656037
	for b in data {
		h = (h ~ u64(b)) * 1099511628211
	}
	return h
}

// Golden_Image pins one supported revision's fresh-format bytes.
Golden_Image :: struct {
	rev_min: u8,
	rev_max: u8,
	full:    u64,
	chunks:  [GOLDEN_SIZE / GOLDEN_CHUNK]u64,
}

GOLDENS := [2]Golden_Image {
	{
		rev_min = 7, rev_max = 7,
		full = 0x64359bbc07aa41a6,
		chunks = {
			0xbde039a20ac241a6,
			0xeb05052ea5b62325, 0xeb05052ea5b62325, 0xeb05052ea5b62325,
			0xeb05052ea5b62325, 0xeb05052ea5b62325, 0xeb05052ea5b62325,
			0xeb05052ea5b62325, 0xeb05052ea5b62325, 0xeb05052ea5b62325,
			0xeb05052ea5b62325, 0xeb05052ea5b62325, 0xeb05052ea5b62325,
			0xeb05052ea5b62325, 0xeb05052ea5b62325, 0xeb05052ea5b62325,
		},
	},
	{
		rev_min = 8, rev_max = 8,
		full = 0xf6380274d5fe82ec,
		chunks = {
			0xa7062bec92ae82ec,
			0xeb05052ea5b62325, 0xeb05052ea5b62325, 0xeb05052ea5b62325,
			0xeb05052ea5b62325, 0xeb05052ea5b62325, 0xeb05052ea5b62325,
			0xeb05052ea5b62325, 0xeb05052ea5b62325, 0xeb05052ea5b62325,
			0xeb05052ea5b62325, 0xeb05052ea5b62325, 0xeb05052ea5b62325,
			0xeb05052ea5b62325, 0xeb05052ea5b62325, 0xeb05052ea5b62325,
		},
	},
}

golden_format :: proc(t: ^testing.T, rev_min, rev_max: u8) -> bool {
	fd, ferr := os.open(GOLDEN_SCRATCH, {.Read, .Write, .Create, .Trunc})
	testing.expect_value(t, ferr, nil)
	if ferr != nil { return false }
	features := fs.Features{.Uid_Gid}
	if rev_max >= 8 {
		features += {.XAttr}
	}
	ferr2 := fs.format_image(
		fd,
		{
			size = GOLDEN_SIZE,
			cluster_size = 16,
			features = features,
			rev_min = rev_min,
			rev_max = rev_max,
		},
	)
	testing.expect_value(t, ferr2, fs.FS_Error.None)
	os.close(fd)
	return ferr2 == .None
}

golden_hash_image :: proc(t: ^testing.T, full: ^u64, chunks: ^[GOLDEN_SIZE / GOLDEN_CHUNK]u64) -> bool {
	data, rerr := os.read_entire_file(GOLDEN_SCRATCH, context.allocator)
	if rerr != nil {
		testing.expect(t, false, "read golden image")
		return false
	}
	defer delete(data)
	if len(data) != GOLDEN_SIZE {
		testing.expectf(t, false, "golden size %d, want %d", len(data), GOLDEN_SIZE)
		return false
	}
	full^ = golden_fnv1a(data)
	for i in 0 ..< len(chunks) {
		chunks[i] = golden_fnv1a(data[i * GOLDEN_CHUNK:(i + 1) * GOLDEN_CHUNK])
	}
	return true
}

// test_golden_format_bytes — fresh formats match the stored goldens.
@(test)
test_golden_format_bytes :: proc(t: ^testing.T) {
	defer os.remove(GOLDEN_SCRATCH)
	for &g in GOLDENS {
		if !golden_format(t, g.rev_min, g.rev_max) { continue }

		// Fresh formats validate (goldens are mountable images).
		raw, rerr := os.read_entire_file(GOLDEN_SCRATCH, context.temp_allocator)
		testing.expect_value(t, rerr, nil)
		if rerr == nil && len(raw) >= fs.SECTOR_SIZE {
			master := (^fs.Master_Record)(raw_data(raw[:fs.SECTOR_SIZE]))^
			testing.expect_value(t, fs.validate_master(&master, fs.Byte_Offset(len(raw))), fs.FS_Error.None)
		}

		full: u64
		chunks: [GOLDEN_SIZE / GOLDEN_CHUNK]u64
		if !golden_hash_image(t, &full, &chunks) { continue }
		if full != g.full {
			fmt.println("GOLDEN MISMATCH rev", g.rev_min, ": full", fmt.tprintf("%16x", full), "want", fmt.tprintf("%16x", g.full))
			for i in 0 ..< len(chunks) {
				if chunks[i] != g.chunks[i] {
					fmt.println("  first differing chunk:", i, "(offset", fmt.tprintf("0x%x", i * GOLDEN_CHUNK), ")")
					break
				}
			}
			fmt.println("  actual full: ", fmt.tprintf("0x%16x", full))
			fmt.println("  actual chunks:")
			for c, i in chunks {
				fmt.println("   ", fmt.tprintf("0x%16x", c), "," if i < len(chunks) - 1 else "")
			}
			// Keep the drifting image for xxd diffing (the deferred
			// remove then finds nothing to delete).
			keep := fmt.tprintf("%s.rev%d.keep", GOLDEN_SCRATCH, g.rev_min)
			os.rename(GOLDEN_SCRATCH, keep)
			testing.expectf(t, false, "golden bytes drifted for rev %d (image kept at %s)", g.rev_min, keep)
			continue
		}
		testing.expect(t, true, "golden matches")
	}
}

// test_golden_format_deterministic — formatting twice yields identical bytes.
@(test)
test_golden_format_deterministic :: proc(t: ^testing.T) {
	defer os.remove(GOLDEN_SCRATCH)
	if !golden_format(t, 8, 8) { return }
	a: u64
	ca: [GOLDEN_SIZE / GOLDEN_CHUNK]u64
	if !golden_hash_image(t, &a, &ca) { return }
	if !golden_format(t, 8, 8) { return }
	b: u64
	cb: [GOLDEN_SIZE / GOLDEN_CHUNK]u64
	if !golden_hash_image(t, &b, &cb) { return }
	testing.expect_value(t, a, b)
	testing.expect(t, ca == cb, "chunks deterministic")
}
