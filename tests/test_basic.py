import os
import stat
import subprocess
import pytest
from fused_test.io import read, write


@pytest.mark.fuse
def test_ls_kernel(mounted_fs: str):
    entries = os.listdir(mounted_fs)
    assert "Kernel" in entries


@pytest.mark.fuse
def test_mode_644(mounted_fs: str):
    st = os.stat(os.path.join(mounted_fs, "Kernel"))
    assert stat.S_IMODE(st.st_mode) == 0o644


@pytest.mark.fuse
def test_size_60(mounted_fs: str):
    st = os.stat(os.path.join(mounted_fs, "Kernel"))
    assert st.st_size == 60


@pytest.mark.fuse
def test_header_bytes(mounted_fs: str):
    data = read(os.path.join(mounted_fs, "Kernel"))
    expected = bytes([0x82, 0x00, 0x0D, 0x00])
    assert data[:4] == expected


@pytest.mark.fuse
def test_write_and_read(mounted_fs: str):
    path = os.path.join(mounted_fs, "write_test")
    write(path, b"hello_fuse")
    data = read(path)
    assert data == b"hello_fuse"
    os.unlink(path)


@pytest.mark.fuse
def test_multi_sector_write(mounted_fs: str):
    path = os.path.join(mounted_fs, "multi")
    data = os.urandom(3 * 512)
    write(path, data)
    st = os.stat(path)
    assert st.st_size >= 1500
    os.unlink(path)


@pytest.mark.fuse
def test_nested_subdir(mounted_fs: str):
    sub = os.path.join(mounted_fs, "subdir", "a", "b")
    os.makedirs(sub, exist_ok=True)
    fpath = os.path.join(sub, "f")
    write(fpath, b"deep")
    data = read(fpath)
    assert data == b"deep"
    os.unlink(fpath)
    os.rmdir(sub)
    os.rmdir(os.path.join(mounted_fs, "subdir", "a"))
    os.rmdir(os.path.join(mounted_fs, "subdir"))


@pytest.mark.fuse
def test_statvfs_basic(mounted_fs: str):
    s = os.statvfs(mounted_fs)
    assert s.f_bsize > 0


@pytest.mark.fuse
def test_statvfs_values(mounted_fs: str):
    s = os.statvfs(mounted_fs)
    assert s.f_namemax == 255
    assert s.f_bsize == 512


@pytest.mark.fuse
def test_max_filename(mounted_fs: str):
    name = "a" * 255
    path = os.path.join(mounted_fs, name)
    write(path, b"ok")
    data = read(path)
    assert data == b"ok"
    os.unlink(path)


@pytest.mark.fuse
def test_log_format_opts(fused_bin: str):
    for fmt in ["short", "long", "full"]:
        r = subprocess.run([fused_bin, "--log-format=" + fmt, "--help"],
                           capture_output=True, text=True)
        assert r.returncode == 0, f"log-format={fmt} exit={r.returncode}"
