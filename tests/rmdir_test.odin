// rmdir_test.odin — rmdir failure semantics on unreadable listings.
//
// rmdir must fail (not delete) when the directory listing cannot be read.
// Runs on an isolated freshly formatted image: the victim's extension
// sector is pushed past every metadata region, then the image is truncated
// at that sector, so data reads fail as Sector_Read_Error while metadata
// stays intact. Loud sanity checks prove the geometry (listing broken,
// tables readable, root resolvable) instead of assuming it — the scenario
// where removal would succeed under the old code, i.e. the true hazard
// (wrongful delete), not merely a pre-failed removal.
#+build linux
package tests

import "core:os"
import "core:sys/posix"
import "core:testing"
import "src:fs"
import "src:fuse3"
import "src:mounter"

RMDIR_SCRATCH := "/dev/shm/fused_rmdir_test.img"

@(test)
test_rmdir_data_read_fails_is_eio :: proc(t: ^testing.T) {
	fd, ferr := os.open(RMDIR_SCRATCH, {.Read, .Write, .Create, .Trunc})
	testing.expect_value(t, ferr, nil)
	if ferr != nil { return }
	ferr2 := fs.format_image(
		fd,
		{
			size = 1 << 20,
			cluster_size = 16,
			features = fs.Features{.Uid_Gid, .XAttr},
			rev_min = 8,
			rev_max = 8,
			demo_data = {},
		},
	)
	testing.expect_value(t, ferr2, fs.FS_Error.None)
	if ferr2 != .None { os.close(fd); return }

	vol, vok := open_volume_on_fd(fd)
	testing.expect(t, vok, "scratch volume opens")
	if !vok { os.close(fd); return }

	fsys: mounter.FS
	mounter.init_fs_for_test(&fsys, vol)
	ctx := fuse3.Context{uid = 1000, gid = 1000, private_data = &fsys}
	fuse3.set_test_context(&ctx)
	defer {
		v := fsys.vol
		mounter.destroy_fs_for_test(&fsys)
		close_test_volume(&v)
		os.remove(RMDIR_SCRATCH)
	}

	rc := mounter.fused_mkdir("/v", posix.mode_t{.IRUSR, .IWUSR, .IXUSR})
	testing.expect_value(t, rc, 0)
	if rc != 0 { return }

	// Pad the disk so the victim's extension sector lands past every
	// metadata region (CME, journal, root).
	fi: fuse3.File_Info
	rc = mounter.fused_create("/v/big", posix.mode_t{.IRUSR, .IWUSR}, &fi)
	testing.expect_value(t, rc, 0)
	if rc != 0 { return }
	rc = mounter.fused_fallocate("/v/big", 0, 0, 500 * fs.SECTOR_SIZE, &fi)
	testing.expect_value(t, rc, 0)
	if rc != 0 { return }

	// Fill the victim's first sector to force an extension sector.
	pbuf: [16]u8
	copy(pbuf[:], "/v/F00")
	extended := false
	for i in 0 ..< 12 {
		pbuf[4] = u8('0' + (i / 10))
		pbuf[5] = u8('0' + (i % 10))
		pbuf[6] = 0
		fi2: fuse3.File_Info
		rc = mounter.fused_create(cstring(raw_data(pbuf[:])), posix.mode_t{.IRUSR, .IWUSR}, &fi2)
		if rc != 0 { break }
		if chain_sectors(t, &fsys, "/v") > 1 { extended = true; break }
	}
	testing.expect(t, extended, "victim extended past one sector")
	if !extended { return }

	vloc := victim_loc(t, &fsys)
	smax := max_chain_sector(&fsys, vloc)
	cut := smax * u64(fs.SECTOR_SIZE)
	testing.expect(t, smax > 0, "victim has data sectors")
	terr := os.truncate(fd, i64(cut))
	testing.expect_value(t, terr, nil)
	fs.dir_cache_invalidate(&fsys.vol.dir_cache, vloc)

	// Geometry sanity, all loud: root resolves (metadata intact), the
	// victim listing read fails, but its cluster table still reads (so a
	// removal walk would succeed — the discriminating condition).
	_, _, _, _, root_err := mounter.resolve_path_cached(&fsys, "/", context.temp_allocator)
	testing.expect_value(t, root_err, fs.FS_Error.None)
	_, list_err := fs.read_directory_entries(&fsys.vol, vloc.cluster, vloc.offset)
	testing.expect(t, list_err != .None, "victim listing broken")
	ctable: [fs.CLUSTER_ENTRIES_PER_SECTOR]fs.Cluster_Entry
	testing.expect_value(
		t,
		fs.read_cluster_entry_table(&fsys.vol, fs.Cluster(u64(smax) / fsys.vol.master.cluster_size), &ctable),
		fs.FS_Error.None,
	)

	// Must fail with EIO (returned 0, deleting, before the fix).
	rc = mounter.fused_rmdir("/v")
	expect_errno(t, rc, .EIO)

	// Disk truth via cold caches: reopen and resolve past every cache.
	vol2, vok2 := open_volume_on_fd(fd)
	testing.expect(t, vok2, "reopen scratch volume")
	if !vok2 { return }
	defer fs.alloc_cache_destroy(&vol2.cache)
	defer fs.dir_cache_destroy(&vol2.dir_cache)
	_, rerr2 := fs.resolve_path(&vol2, "/v", context.temp_allocator)
	testing.expect_value(t, rerr2, fs.FS_Error.None)
}

// chain_sectors counts the sectors in a path's data chain (fresh walk,
// no caches involved).
chain_sectors :: proc(t: ^testing.T, fsys: ^mounter.FS, path: string) -> u64 {
	entry, _, _, _, rerr := mounter.resolve_path_cached(fsys, path, context.temp_allocator)
	if rerr != .None { return 0 }
	runs, xerr := fs.resolve_extents(
		&fsys.vol,
		fs.Chain_Location{fs.Cluster(entry.stored_cluster), fs.Sector_Offset(entry.sector_index)},
	)
	defer delete(runs)
	if xerr != .None { return 0 }
	total: u64
	for r in runs { total += u64(r.count) }
	return total
}

// victim_loc resolves a path to its data chain start.
victim_loc :: proc(t: ^testing.T, fsys: ^mounter.FS) -> fs.Chain_Location {
	entry, _, _, _, rerr := mounter.resolve_path_cached(fsys, "/v", context.temp_allocator)
	testing.expect_value(t, rerr, fs.FS_Error.None)
	return {fs.Cluster(entry.stored_cluster), fs.Sector_Offset(entry.sector_index)}
}

// max_chain_sector returns the highest physical sector in a chain.
max_chain_sector :: proc(fsys: ^mounter.FS, loc: fs.Chain_Location) -> u64 {
	runs, xerr := fs.resolve_extents(&fsys.vol, loc)
	defer delete(runs)
	if xerr != .None { return 0 }
	top: u64
	for r in runs { top = max(top, u64(r.sector) + u64(r.count) - 1) }
	return top
}
