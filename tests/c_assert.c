// tests/c_assert.c — Ground-truth sizes & offsets for every cross-FFI struct.
// Compile:  cc tests/c_assert.c $(pkg-config --cflags fuse3) -o /tmp/c_assert
// Run:      /tmp/c_assert
//
// Used by tests/check_sizes.sh to cross-check the Odin binding's #asserts.

#define FUSE_USE_VERSION 318
#include <sys/stat.h>
#include <sys/types.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>
#include <fuse3/fuse.h>
#include <fuse3/fuse_common.h>
#include <fuse3/fuse_opt.h>
#include <fuse3/fuse_log.h>

#define LINE(s) printf("  %-30s = %3zu\n", #s, (size_t)(s))

int main(void) {
    printf("=== cross-FFI struct sizes (glibc x86_64, fuse3 3.18) ===\n");

    LINE(sizeof(struct stat));
    LINE(sizeof(struct fuse_file_info));
    LINE(sizeof(struct fuse_operations));
    LINE(sizeof(struct fuse_conn_info));
    LINE(sizeof(struct fuse_config));
    LINE(sizeof(struct fuse_loop_config_v1));  /* FUSE_USE_VERSION >= 312 makes v1 the public name */
    LINE(sizeof(struct fuse_context));
    LINE(sizeof(struct libfuse_version));
    LINE(sizeof(struct fuse_args));
    LINE(sizeof(struct fuse_opt));
    LINE(sizeof(struct fuse_buf));
    LINE(sizeof(struct fuse_bufvec));

    printf("\n=== struct stat offsets ===\n");
    LINE(offsetof(struct stat, st_dev));
    LINE(offsetof(struct stat, st_ino));
    LINE(offsetof(struct stat, st_nlink));
    LINE(offsetof(struct stat, st_mode));
    LINE(offsetof(struct stat, st_uid));
    LINE(offsetof(struct stat, st_gid));
    LINE(offsetof(struct stat, st_rdev));
    LINE(offsetof(struct stat, st_size));
    LINE(offsetof(struct stat, st_blksize));
    LINE(offsetof(struct stat, st_blocks));
    LINE(offsetof(struct stat, st_atim));
    LINE(offsetof(struct stat, st_mtim));
    LINE(offsetof(struct stat, st_ctim));
    LINE(sizeof(struct timespec));

    printf("\n=== struct fuse_file_info offsets (non-bitfield only) ===\n");
    LINE(offsetof(struct fuse_file_info, flags));
    LINE(offsetof(struct fuse_file_info, fh));
    LINE(offsetof(struct fuse_file_info, lock_owner));
    LINE(offsetof(struct fuse_file_info, poll_events));
    LINE(offsetof(struct fuse_file_info, backing_id));
    LINE(offsetof(struct fuse_file_info, compat_flags));
    LINE(offsetof(struct fuse_file_info, reserved));

    printf("\n=== struct fuse_operations offsets (sampling) ===\n");
    LINE(offsetof(struct fuse_operations, getattr));
    LINE(offsetof(struct fuse_operations, readlink));
    LINE(offsetof(struct fuse_operations, mknod));
    LINE(offsetof(struct fuse_operations, mkdir));
    LINE(offsetof(struct fuse_operations, unlink));
    LINE(offsetof(struct fuse_operations, rmdir));
    LINE(offsetof(struct fuse_operations, symlink));
    LINE(offsetof(struct fuse_operations, rename));
    LINE(offsetof(struct fuse_operations, link));
    LINE(offsetof(struct fuse_operations, chmod));
    LINE(offsetof(struct fuse_operations, chown));
    LINE(offsetof(struct fuse_operations, truncate));
    LINE(offsetof(struct fuse_operations, open));
    LINE(offsetof(struct fuse_operations, read));
    LINE(offsetof(struct fuse_operations, write));
    LINE(offsetof(struct fuse_operations, statfs));
    LINE(offsetof(struct fuse_operations, flush));
    LINE(offsetof(struct fuse_operations, release));
    LINE(offsetof(struct fuse_operations, fsync));
    LINE(offsetof(struct fuse_operations, setxattr));
    LINE(offsetof(struct fuse_operations, getxattr));
    LINE(offsetof(struct fuse_operations, listxattr));
    LINE(offsetof(struct fuse_operations, removexattr));
    LINE(offsetof(struct fuse_operations, opendir));
    LINE(offsetof(struct fuse_operations, readdir));
    LINE(offsetof(struct fuse_operations, releasedir));
    LINE(offsetof(struct fuse_operations, fsyncdir));
    LINE(offsetof(struct fuse_operations, init));
    LINE(offsetof(struct fuse_operations, destroy));
    LINE(offsetof(struct fuse_operations, access));
    LINE(offsetof(struct fuse_operations, create));
    LINE(offsetof(struct fuse_operations, lock));
    LINE(offsetof(struct fuse_operations, utimens));
    LINE(offsetof(struct fuse_operations, bmap));
    LINE(offsetof(struct fuse_operations, ioctl));
    LINE(offsetof(struct fuse_operations, poll));
    LINE(offsetof(struct fuse_operations, write_buf));
    LINE(offsetof(struct fuse_operations, read_buf));
    LINE(offsetof(struct fuse_operations, flock));
    LINE(offsetof(struct fuse_operations, fallocate));
    LINE(offsetof(struct fuse_operations, copy_file_range));
    LINE(offsetof(struct fuse_operations, lseek));
    LINE(offsetof(struct fuse_operations, statx));

    printf("\n=== struct fuse_conn_info offsets ===\n");
    LINE(offsetof(struct fuse_conn_info, proto_major));
    LINE(offsetof(struct fuse_conn_info, proto_minor));
    LINE(offsetof(struct fuse_conn_info, max_write));
    LINE(offsetof(struct fuse_conn_info, max_read));
    LINE(offsetof(struct fuse_conn_info, max_readahead));
    LINE(offsetof(struct fuse_conn_info, capable));
    LINE(offsetof(struct fuse_conn_info, want));
    LINE(offsetof(struct fuse_conn_info, max_background));
    LINE(offsetof(struct fuse_conn_info, congestion_threshold));
    LINE(offsetof(struct fuse_conn_info, time_gran));
    LINE(offsetof(struct fuse_conn_info, max_backing_stack_depth));
    LINE(offsetof(struct fuse_conn_info, capable_ext));
    LINE(offsetof(struct fuse_conn_info, want_ext));
    LINE(offsetof(struct fuse_conn_info, request_timeout));
    LINE(offsetof(struct fuse_conn_info, reserved));

    printf("\n=== struct fuse_config offsets ===\n");
    LINE(offsetof(struct fuse_config, set_gid));
    LINE(offsetof(struct fuse_config, gid));
    LINE(offsetof(struct fuse_config, set_uid));
    LINE(offsetof(struct fuse_config, uid));
    LINE(offsetof(struct fuse_config, set_mode));
    LINE(offsetof(struct fuse_config, umask));
    LINE(offsetof(struct fuse_config, entry_timeout));
    LINE(offsetof(struct fuse_config, negative_timeout));
    LINE(offsetof(struct fuse_config, attr_timeout));
    LINE(offsetof(struct fuse_config, intr));
    LINE(offsetof(struct fuse_config, intr_signal));
    LINE(offsetof(struct fuse_config, remember));
    LINE(offsetof(struct fuse_config, hard_remove));
    LINE(offsetof(struct fuse_config, use_ino));
    LINE(offsetof(struct fuse_config, readdir_ino));
    LINE(offsetof(struct fuse_config, direct_io));
    LINE(offsetof(struct fuse_config, kernel_cache));
    LINE(offsetof(struct fuse_config, auto_cache));
    LINE(offsetof(struct fuse_config, ac_attr_timeout_set));
    LINE(offsetof(struct fuse_config, ac_attr_timeout));
    LINE(offsetof(struct fuse_config, nullpath_ok));
    LINE(offsetof(struct fuse_config, show_help));
    LINE(offsetof(struct fuse_config, modules));
    LINE(offsetof(struct fuse_config, debug));
    LINE(offsetof(struct fuse_config, fmask));
    LINE(offsetof(struct fuse_config, dmask));
    LINE(offsetof(struct fuse_config, no_rofd_flush));
    LINE(offsetof(struct fuse_config, parallel_direct_writes));
    LINE(offsetof(struct fuse_config, flags));
    LINE(offsetof(struct fuse_config, reserved));

    printf("\n=== struct fuse_context offsets ===\n");
    LINE(offsetof(struct fuse_context, fuse));
    LINE(offsetof(struct fuse_context, uid));
    LINE(offsetof(struct fuse_context, gid));
    LINE(offsetof(struct fuse_context, pid));
    LINE(offsetof(struct fuse_context, private_data));
    LINE(offsetof(struct fuse_context, umask));

    printf("\n=== struct fuse_args offsets ===\n");
    LINE(offsetof(struct fuse_args, argc));
    LINE(offsetof(struct fuse_args, argv));
    LINE(offsetof(struct fuse_args, allocated));

    printf("\n=== struct fuse_opt offsets ===\n");
    LINE(offsetof(struct fuse_opt, templ));
    LINE(offsetof(struct fuse_opt, offset));
    LINE(offsetof(struct fuse_opt, value));

    printf("\n=== struct fuse_loop_config_v1 offsets ===\n");
    LINE(offsetof(struct fuse_loop_config_v1, clone_fd));
    LINE(offsetof(struct fuse_loop_config_v1, max_idle_threads));

    printf("\n=== struct fuse_buf offsets ===\n");
    LINE(offsetof(struct fuse_buf, size));
    LINE(offsetof(struct fuse_buf, flags));
    LINE(offsetof(struct fuse_buf, mem));
    LINE(offsetof(struct fuse_buf, fd));
    LINE(offsetof(struct fuse_buf, pos));
    LINE(offsetof(struct fuse_buf, mem_size));

    printf("\n=== struct fuse_bufvec offsets (incl. flexible-array) ===\n");
    LINE(offsetof(struct fuse_bufvec, count));
    LINE(offsetof(struct fuse_bufvec, idx));
    LINE(offsetof(struct fuse_bufvec, off));
    LINE(offsetof(struct fuse_bufvec, buf));

    printf("\n=== struct libfuse_version offsets ===\n");
    LINE(offsetof(struct libfuse_version, major));
    LINE(offsetof(struct libfuse_version, minor));
    LINE(offsetof(struct libfuse_version, hotfix));
    LINE(offsetof(struct libfuse_version, padding));

    return 0;
}
