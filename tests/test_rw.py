import os
import stat
import subprocess

import pytest

from fused_test.io import make_dir, make_file, read, write


@pytest.mark.fuse
def test_echo_cat(private_mount: str):
    with make_file(os.path.join(private_mount, "file1"), b"hello\n") as f:
        assert read(f) == b"hello\n"


@pytest.mark.fuse
def test_append(private_mount: str):
    with make_file(os.path.join(private_mount, "file1"), b"hello\n") as f:
        with open(f, "ab") as fh:
            fh.write(b"world\n")
        assert b"world" in read(f)


@pytest.mark.fuse
def test_cp_via_shell(private_mount: str):
    f1 = os.path.join(private_mount, "file1")
    f2 = os.path.join(private_mount, "file2")
    with make_file(f1, b"hello\n"):
        try:
            subprocess.run(["cp", f1, f2], check=True)
            assert b"hello" in read(f2)
        finally:
            os.unlink(f2)


@pytest.mark.fuse
def test_dd_10_sectors(private_mount: str):
    path = os.path.join(private_mount, "big")
    subprocess.run(["dd", "if=/dev/zero", f"of={path}", "bs=512", "count=10"], check=True,
                   capture_output=True)
    try:
        assert os.stat(path).st_size >= 5120
    finally:
        os.unlink(path)


@pytest.mark.fuse
def test_mkdir_rmdir(private_mount: str):
    with (make_dir(os.path.join(private_mount, "d1")) as d,
          make_file(os.path.join(d, "f"), b"data\n") as f):
        assert read(f) == b"data\n"
    assert not os.path.exists(os.path.join(private_mount, "d1"))


@pytest.mark.fuse
def test_symlink(private_mount: str):
    with make_file(os.path.join(private_mount, "target"), b"hello\n"):
        link = os.path.join(private_mount, "link")
        try:
            os.symlink("target", link)
            assert os.readlink(link) == "target"
            assert stat.S_ISLNK(os.lstat(link).st_mode)
        finally:
            os.unlink(link)


@pytest.mark.fuse
def test_chmod(private_mount: str):
    with make_file(os.path.join(private_mount, "chmod_file"), b"x") as f:
        os.chmod(f, 0o444)
        assert stat.S_IMODE(os.stat(f).st_mode) in (0o444, 0o440)
        os.chmod(f, 0o644)
        assert stat.S_IMODE(os.stat(f).st_mode) in (0o644, 0o640)


@pytest.mark.fuse
def test_fallocate_extend(private_mount: str):
    with make_file(os.path.join(private_mount, "falloc_file"), b"x" * 100) as f:
        with open(f, "r+b") as fh:
            os.posix_fallocate(fh.fileno(), 0, 8192)
        assert os.stat(f).st_size == 8192


@pytest.mark.fuse
def test_copy_file_range(private_mount: str):
    src = os.path.join(private_mount, "cp_src")
    dst = os.path.join(private_mount, "cp_dst")
    with make_file(src, b"hello_copy"):
        try:
            subprocess.run(["cp", src, dst], check=True)
            assert b"hello_copy" in read(dst)
        finally:
            os.unlink(dst)


@pytest.mark.fuse
def test_deep_nesting(private_mount: str):
    d = os.path.join(private_mount, *["d"] * 10)
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
def test_fsync(private_mount: str):
    with make_file(os.path.join(private_mount, "fsync_file"), b"fsynced\n") as f:
        with open(f, "r+b") as fh:
            os.fsync(fh.fileno())
        assert read(f) == b"fsynced\n"


@pytest.mark.fuse
def test_truncate(private_mount: str):
    with make_file(os.path.join(private_mount, "trunc_file"), b"hello world") as f:
        # Shrink
        with open(f, "r+") as fh:
            fh.truncate(5)
        assert os.stat(f).st_size == 5
        # Grow
        with open(f, "r+") as fh:
            fh.truncate(20)
        assert os.stat(f).st_size == 20


@pytest.mark.fuse
def test_utimens(private_mount: str):
    with make_file(os.path.join(private_mount, "utimens_file"), b"x") as f:
        atime = 1000000000
        mtime = 2000000000
        os.utime(f, (atime, mtime))
        st = os.stat(f)
        assert st.st_atime == atime
        assert st.st_mtime == mtime
