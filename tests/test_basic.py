import os
import stat
import subprocess

import pytest

from fused_test.io import make_file, read


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
def test_statvfs_values(mounted_fs: str):
    s = os.statvfs(mounted_fs)
    assert s.f_namemax == 255
    assert s.f_bsize == 512


@pytest.mark.fuse
def test_max_filename(mounted_fs: str):
    name = "a" * 255
    path = os.path.join(mounted_fs, name)
    with make_file(path, b"ok") as f:
        assert read(f) == b"ok"


@pytest.mark.fuse
def test_log_format_opts(fused_bin: str):
    for fmt in ["short", "long", "full"]:
        r = subprocess.run([fused_bin, "--log-format=" + fmt, "--help"],
                           capture_output=True, text=True)
        assert r.returncode == 0, f"log-format={fmt} exit={r.returncode}"
