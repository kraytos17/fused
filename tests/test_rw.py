import os
import stat
import subprocess
import pytest
from fused_test.io import read, write


@pytest.mark.fuse
def test_echo_cat(mounted_fs: str):
    f = os.path.join(mounted_fs, "file1")
    write(f, b"hello\n")
    data = read(f)
    assert data == b"hello\n"
    os.unlink(f)


@pytest.mark.fuse
def test_append(mounted_fs: str):
    f = os.path.join(mounted_fs, "file1")
    write(f, b"hello\n")
    with open(f, "ab") as fh:
        fh.write(b"world\n")
    data = read(f)
    assert b"world" in data
    os.unlink(f)


@pytest.mark.fuse
def test_cp_via_shell(mounted_fs: str):
    subprocess.run(["bash", "-c", f"echo hello > {mounted_fs}/file1"], check=True)
    subprocess.run(["cp", f"{mounted_fs}/file1", f"{mounted_fs}/file2"], check=True)
    data = read(os.path.join(mounted_fs, "file2"))
    assert b"hello" in data
    os.unlink(os.path.join(mounted_fs, "file1"))
    os.unlink(os.path.join(mounted_fs, "file2"))


@pytest.mark.fuse
def test_dd_10_sectors(mounted_fs: str):
    path = os.path.join(mounted_fs, "big")
    subprocess.run(["dd", "if=/dev/zero", f"of={path}", "bs=512", "count=10"], check=True,
                   capture_output=True)
    st = os.stat(path)
    assert st.st_size >= 5120
    os.unlink(path)


@pytest.mark.fuse
def test_mkdir_rmdir(mounted_fs: str):
    d = os.path.join(mounted_fs, "d1")
    os.mkdir(d)
    f = os.path.join(d, "f")
    write(f, b"data\n")
    data = read(f)
    assert data == b"data\n"
    os.unlink(f)
    os.rmdir(d)
    assert not os.path.exists(d)


@pytest.mark.fuse
def test_symlink(mounted_fs: str):
    target = os.path.join(mounted_fs, "target")
    write(target, b"hello\n")
    link = os.path.join(mounted_fs, "link")
    os.symlink("target", link)
    got = os.readlink(link)
    assert got == "target"
    lst = os.lstat(link)
    assert stat.S_ISLNK(lst.st_mode)
    os.unlink(link)
    os.unlink(target)


@pytest.mark.fuse
def test_chmod(mounted_fs: str):
    f = os.path.join(mounted_fs, "chmod_file")
    write(f, b"x")
    stat.S_IMODE(os.stat(f).st_mode)
    os.chmod(f, 0o444)
    assert stat.S_IMODE(os.stat(f).st_mode) in (0o444, 0o440)
    os.chmod(f, 0o644)
    assert stat.S_IMODE(os.stat(f).st_mode) in (0o644, 0o640)
    os.unlink(f)


@pytest.mark.fuse
def test_fallocate_extend(mounted_fs: str):
    f = os.path.join(mounted_fs, "falloc_file")
    write(f, b"x" * 100)
    fd = os.open(f, os.O_RDWR)
    try:
        os.posix_fallocate(fd, 0, 8192)
    finally:
        os.close(fd)
    st = os.stat(f)
    assert st.st_size == 8192
    os.unlink(f)


@pytest.mark.fuse
def test_copy_file_range(mounted_fs: str):
    src = os.path.join(mounted_fs, "cp_src")
    write(src, b"hello_copy")
    dst = os.path.join(mounted_fs, "cp_dst")
    subprocess.run(["cp", src, dst], check=True)
    data = read(dst)
    assert b"hello_copy" in data
    os.unlink(src)
    os.unlink(dst)


@pytest.mark.fuse
def test_deep_nesting(mounted_fs: str):
    d = os.path.join(mounted_fs, *["d"] * 10)
    os.makedirs(d, exist_ok=True)
    f = os.path.join(d, "f")
    write(f, b"deep\n")
    data = read(f)
    assert data == b"deep\n"
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
    f = os.path.join(mounted_fs, "fsync_file")
    write(f, b"fsynced\n")
    fd = os.open(f, os.O_RDWR)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    data = read(f)
    assert data == b"fsynced\n"
    os.unlink(f)


@pytest.mark.fuse
def test_truncate(mounted_fs: str):
    f = os.path.join(mounted_fs, "trunc_file")
    write(f, b"hello world")
    # Shrink
    with open(f, "r+") as fh:
        fh.truncate(5)
    st = os.stat(f)
    assert st.st_size == 5
    # Grow
    with open(f, "r+") as fh:
        fh.truncate(20)
    st = os.stat(f)
    assert st.st_size == 20
    os.unlink(f)


@pytest.mark.fuse
def test_utimens(mounted_fs: str):
    f = os.path.join(mounted_fs, "utimens_file")
    write(f, b"x")
    atime = 1000000000
    mtime = 2000000000
    os.utime(f, (atime, mtime))
    st = os.stat(f)
    assert st.st_atime == atime
    assert st.st_mtime == mtime
    os.unlink(f)
