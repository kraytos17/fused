# tests/fuse/test_basic.py — Smoke tests against the demo image.
#
# Asserts the embedded demo file (/Kernel) on a private mount; like
# every other fuse suite, never touches the shared fused.img.
import os
import stat

import pytest

from fused_test.io import make_file, read, run_cli


@pytest.mark.fuse
def test_ls_kernel(private_mount: str):
    entries = os.listdir(private_mount)
    assert "Kernel" in entries


@pytest.mark.fuse
def test_mode_644(private_mount: str):
    st = os.stat(os.path.join(private_mount, "Kernel"))
    assert stat.S_IMODE(st.st_mode) == 0o644


@pytest.mark.fuse
def test_size_60(private_mount: str):
    st = os.stat(os.path.join(private_mount, "Kernel"))
    assert st.st_size == 60


@pytest.mark.fuse
def test_header_bytes(private_mount: str):
    data = read(os.path.join(private_mount, "Kernel"))
    expected = bytes([0x82, 0x00, 0x0D, 0x00])
    assert data[:4] == expected


@pytest.mark.fuse
def test_statvfs_values(private_mount: str):
    s = os.statvfs(private_mount)
    assert s.f_namemax == 255
    assert s.f_bsize == 512


@pytest.mark.fuse
def test_max_filename(private_mount: str):
    name = "a" * 255
    path = os.path.join(private_mount, name)
    with make_file(path, b"ok") as f:
        assert read(f) == b"ok"


@pytest.mark.fuse
def test_log_format_opts(fused_bin: str):
    for fmt in ["short", "long", "full"]:
        r = run_cli(fused_bin, "--log-format=" + fmt, "--help")
        assert r.returncode == 0, f"log-format={fmt} exit={r.returncode}"
