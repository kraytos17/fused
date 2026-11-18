# tests/fuse/test_golden_mount.py — golden images mount through the kernel (T-09).
#
# Copies tests/golden/rev{7,8}.img to a tmp path (fixtures are read-only),
# mounts each copy, and verifies the fixed tree end to end: listing,
# file bytes incl. the LFN entry, symlink target, and (rev 8) the xattr.
import os
import shutil

import pytest

from fused_test.mount import mount_fuse

GOLDEN = os.path.join(os.path.dirname(__file__), "..", "..", "tests", "golden")


def _stage(tmp_path, name: str) -> str:
    src = os.path.normpath(os.path.join(GOLDEN, name))
    assert os.path.isfile(src), f"missing fixture {src} (run `make golden`)"
    dst = str(tmp_path / name)
    shutil.copy(src, dst)
    return dst


def _check_tree(mp: str, want_xattr: bool):
    assert sorted(os.listdir(mp)) == sorted(
        ["Kernel", "docs", "this_is_a_long_file_name_01.txt", "link"]
    )
    with open(os.path.join(mp, "Kernel"), "rb") as fh:
        assert fh.read() == (
            b"golden kernel payload 0123456789 abcdefghijklmnopqrstuvwxyz\n"
        )
    with open(os.path.join(mp, "docs", "readme.txt"), "rb") as fh:
        assert fh.read() == b"golden readme\n"
    with open(os.path.join(mp, "this_is_a_long_file_name_01.txt"), "rb") as fh:
        assert fh.read() == b"long name content\n"
    assert os.readlink(os.path.join(mp, "link")) == "/Kernel"
    if want_xattr:
        v = os.getxattr(os.path.join(mp, "Kernel"), "user.comment")
        assert v == b"golden-rev8"


@pytest.mark.fuse
def test_golden_rev8_mounts(fused_bin: str, tmp_path):
    img = _stage(tmp_path, "rev8.img")
    mount = str(tmp_path / "mnt")
    logs = str(tmp_path / "logs")
    with mount_fuse(fused_bin, img, mount, logs) as mp:
        _check_tree(mp, want_xattr=True)


@pytest.mark.fuse
def test_golden_rev7_mounts(fused_bin: str, tmp_path):
    img = _stage(tmp_path, "rev7.img")
    mount = str(tmp_path / "mnt")
    logs = str(tmp_path / "logs")
    with mount_fuse(fused_bin, img, mount, logs) as mp:
        _check_tree(mp, want_xattr=False)
