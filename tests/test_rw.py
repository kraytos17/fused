import os
import stat
import subprocess

import pytest

from fused_test.io import make_dir, make_file, read, write


@pytest.mark.fuse
def test_echo_cat(mounted_fs: str):
    with make_file(os.path.join(mounted_fs, "file1"), b"hello\n") as f:
        assert read(f) == b"hello\n"


@pytest.mark.fuse
def test_append(mounted_fs: str):
    with make_file(os.path.join(mounted_fs, "file1"), b"hello\n") as f:
        with open(f, "ab") as fh:
            fh.write(b"world\n")
        assert b"world" in read(f)


@pytest.mark.fuse
def test_cp_via_shell(mounted_fs: str):
    f1 = os.path.join(mounted_fs, "file1")
    f2 = os.path.join(mounted_fs, "file2")
    with make_file(f1, b"hello\n"):
        try:
            subprocess.run(["cp", f1, f2], check=True)
            assert b"hello" in read(f2)
        finally:
            os.unlink(f2)


@pytest.mark.fuse
def test_dd_10_sectors(mounted_fs: str):
    path = os.path.join(mounted_fs, "big")
    subprocess.run(["dd", "if=/dev/zero", f"of={path}", "bs=512", "count=10"], check=True,
                   capture_output=True)
    try:
        assert os.stat(path).st_size >= 5120
    finally:
        os.unlink(path)


@pytest.mark.fuse
def test_mkdir_rmdir(mounted_fs: str):
    with (make_dir(os.path.join(mounted_fs, "d1")) as d,
          make_file(os.path.join(d, "f"), b"data\n") as f):
        assert read(f) == b"data\n"
    assert not os.path.exists(os.path.join(mounted_fs, "d1"))


@pytest.mark.fuse
def test_symlink(mounted_fs: str):
    with make_file(os.path.join(mounted_fs, "target"), b"hello\n"):
        link = os.path.join(mounted_fs, "link")
        try:
            os.symlink("target", link)
            assert os.readlink(link) == "target"
            assert stat.S_ISLNK(os.lstat(link).st_mode)
        finally:
            os.unlink(link)


@pytest.mark.fuse
def test_chmod(mounted_fs: str):
    with make_file(os.path.join(mounted_fs, "chmod_file"), b"x") as f:
        os.chmod(f, 0o444)
        assert stat.S_IMODE(os.stat(f).st_mode) in (0o444, 0o440)
        os.chmod(f, 0o644)
        assert stat.S_IMODE(os.stat(f).st_mode) in (0o644, 0o640)


@pytest.mark.fuse
def test_fallocate_extend(mounted_fs: str):
    with make_file(os.path.join(mounted_fs, "falloc_file"), b"x" * 100) as f:
        with open(f, "r+b") as fh:
            os.posix_fallocate(fh.fileno(), 0, 8192)
        assert os.stat(f).st_size == 8192


@pytest.mark.fuse
def test_copy_file_range(mounted_fs: str):
    src = os.path.join(mounted_fs, "cp_src")
    dst = os.path.join(mounted_fs, "cp_dst")
    with make_file(src, b"hello_copy"):
        try:
            subprocess.run(["cp", src, dst], check=True)
            assert b"hello_copy" in read(dst)
        finally:
            os.unlink(dst)


@pytest.mark.fuse
def test_deep_nesting(mounted_fs: str):
    d = os.path.join(mounted_fs, *["d"] * 10)
    os.makedirs(d, exist_ok=True)
    f = os.path.join(d, "f")
    try:
        write(f, b"deep\n")
        assert read(f) == b"deep\n"
    finally:
        os.unlink(f)
        # Clean up bottom-up
        for _ in range(11):
            try:
                os.rmdir(d)
            except OSError:
                break
            d = os.path.dirname(d)


@pytest.mark.fuse
def test_fsync(mounted_fs: str):
    with make_file(os.path.join(mounted_fs, "fsync_file"), b"fsynced\n") as f:
        with open(f, "r+b") as fh:
            os.fsync(fh.fileno())
        assert read(f) == b"fsynced\n"


@pytest.mark.fuse
def test_truncate(mounted_fs: str):
    with make_file(os.path.join(mounted_fs, "trunc_file"), b"hello world") as f:
        # Shrink
        with open(f, "r+") as fh:
            fh.truncate(5)
        assert os.stat(f).st_size == 5
        # Grow
        with open(f, "r+") as fh:
            fh.truncate(20)
        assert os.stat(f).st_size == 20


@pytest.mark.fuse
def test_utimens(mounted_fs: str):
    with make_file(os.path.join(mounted_fs, "utimens_file"), b"x") as f:
        atime = 1000000000
        mtime = 2000000000
        os.utime(f, (atime, mtime))
        st = os.stat(f)
        assert st.st_atime == atime
        assert st.st_mtime == mtime
