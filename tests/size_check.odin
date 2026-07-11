// size_check.odin — Runtime sanity check for cross-FFI struct sizes.
// Compiled with `odin test` (or `odin run -file`).
// Each expect_value mirrors a #assert in src/fuse3/types.odin; if the
// #assert ever gets bypassed or the binding is used without rebuilding,
// this catches it at startup.
#+build linux
package tests

import "core:fmt"
import "core:testing"
import "src:fuse3"

@test
test_struct_sizes :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(fuse3.Operations), 344)
	testing.expect_value(t, size_of(fuse3.File_Info), 64)
	testing.expect_value(t, size_of(fuse3.Stat), 144)
	testing.expect_value(t, size_of(fuse3.Conn_Info), 128)
	testing.expect_value(t, size_of(fuse3.Config), 520)
	testing.expect_value(t, size_of(fuse3.Libfuse_Version), 16)
	testing.expect_value(t, size_of(fuse3.Args), 24)
	testing.expect_value(t, size_of(fuse3.Opt), 24)
	testing.expect_value(t, size_of(fuse3.Loop_Config), 8)
	testing.expect_value(t, size_of(fuse3.Context), 40)
	testing.expect_value(t, size_of(fuse3.Buf), 48)
	testing.expect_value(t, size_of(fuse3.Bufvec), 72)
}

main :: proc() {
	fmt.println("=== Odin struct sizes (linux/amd64, fuse3 3.18) ===")
	fmt.printf("  Operations     = %d\n", size_of(fuse3.Operations))
	fmt.printf("  File_Info      = %d\n", size_of(fuse3.File_Info))
	fmt.printf("  Stat           = %d\n", size_of(fuse3.Stat))
	fmt.printf("  Conn_Info      = %d\n", size_of(fuse3.Conn_Info))
	fmt.printf("  Config         = %d\n", size_of(fuse3.Config))
	fmt.printf("  Libfuse_Version = %d\n", size_of(fuse3.Libfuse_Version))
	fmt.printf("  Args           = %d\n", size_of(fuse3.Args))
	fmt.printf("  Opt            = %d\n", size_of(fuse3.Opt))
	fmt.printf("  Loop_Config    = %d\n", size_of(fuse3.Loop_Config))
	fmt.printf("  Context        = %d\n", size_of(fuse3.Context))
	fmt.printf("  Buf            = %d\n", size_of(fuse3.Buf))
	fmt.printf("  Bufvec         = %d\n", size_of(fuse3.Bufvec))
}
