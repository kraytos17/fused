// main.odin — fused FUSE mounter binary entry point.
#+build linux
package main

import "base:runtime"
import "src:mounter"

// main is the binary entry point. It parses flags, opens the image,
// sets up logging, and calls mounter.run() via the FUSE event loop.
main :: proc() {
	context = runtime.default_context()
	mounter.run()
}
