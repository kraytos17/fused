// main.odin — fused read-write FUSE mounter.
// Placeholder.  Opens a disk image, validates the MasterRecord,
// and prints a summary.
#+build linux
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "src:fs"

main :: proc() {
	context = runtime.default_context()
	if len(os.args) < 2 {
		fmt.eprintln("usage: fused <image-path>")
		os.exit(1)
	}

	path := os.args[1]
	fd, open_err := os.open(path, {.Read, .Write})
	if open_err != nil {
		fmt.eprintln("cannot open", path, ":", open_err)
		os.exit(1)
	}
	defer os.close(fd)

	master, ok := fs.read_master_record(fd)
	if !ok {
		fmt.eprintln("failed to read MasterRecord")
		os.exit(1)
	}

	fi, stat_err := os.stat(path, context.temp_allocator)
	image_size := u64(0)
	if stat_err == nil {
		image_size = u64(fi.size)
	}

	err := fs.validate_master(&master, image_size)
	if err != .None {
		fmt.eprintln("validation failed:", err)
		os.exit(1)
	}

	fmt.printf("sig=FUSED  rev=%d  cluster_size=%d  total_clusters=%d  root_cluster=%d\n",
		master.rev, master.cluster_size, master.cluster_map_size, master.root_cluster)
	fmt.println("MasterRecord valid.")
}
