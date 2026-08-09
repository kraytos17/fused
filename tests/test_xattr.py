import errno
import os
import shutil

import pytest

from fused_test.io import make_dir, make_file
from fused_test.mount import mount_fuse


@pytest.mark.fuse
def test_xattr_set_get(mounted_fs: str):
    with make_file(os.path.join(mounted_fs, "xfile"), b"data") as f:
        os.setxattr(f, "user.color", b"red")
        assert os.getxattr(f, "user.color") == b"red"

        os.setxattr(f, "user.empty", b"")
        assert os.getxattr(f, "user.empty") == b""

        names = os.listxattr(f)
        assert "user.color" in names
        assert "user.empty" in names


@pytest.mark.fuse
def test_xattr_replace_flags(mounted_fs: str):
    with make_file(os.path.join(mounted_fs, "xflag"), b"x") as f:
        os.setxattr(f, "user.a", b"1")
        with pytest.raises(FileExistsError):
            os.setxattr(f, "user.a", b"2", os.XATTR_CREATE)
        os.setxattr(f, "user.a", b"2", os.XATTR_REPLACE)
        assert os.getxattr(f, "user.a") == b"2"
        with pytest.raises(OSError) as exc:
            os.setxattr(f, "user.missing", b"1", os.XATTR_REPLACE)
        assert exc.value.errno == errno.ENODATA


@pytest.mark.fuse
def test_xattr_get_missing_raises(mounted_fs: str):
    with make_file(os.path.join(mounted_fs, "xmiss"), b"x") as f:
        with pytest.raises(OSError) as exc:
            os.getxattr(f, "user.nope")
        assert exc.value.errno == errno.ENODATA


@pytest.mark.fuse
def test_xattr_list_empty_and_remove(mounted_fs: str):
    with make_file(os.path.join(mounted_fs, "xlist"), b"x") as f:
        assert os.listxattr(f) == []
        os.setxattr(f, "user.k", b"v")
        os.setxattr(f, "user.j", b"w")
        assert sorted(os.listxattr(f)) == ["user.j", "user.k"]

        os.removexattr(f, "user.j")
        assert os.listxattr(f) == ["user.k"]

        with pytest.raises(OSError) as exc:
            os.removexattr(f, "user.j")
        assert exc.value.errno == errno.ENODATA


@pytest.mark.fuse
def test_xattr_large_value_persists(mounted_fs: str):
    with make_file(os.path.join(mounted_fs, "xbig"), b"x") as f:
        big = bytes(range(256)) * 8  # 2048 bytes, spans multiple sectors
        os.setxattr(f, "user.big", big)
        assert os.getxattr(f, "user.big") == big


@pytest.mark.fuse
def test_xattr_on_directory(mounted_fs: str):
    with make_dir(os.path.join(mounted_fs, "xdir")) as d:
        os.setxattr(d, "user.d", b"dirval")
        assert os.getxattr(d, "user.d") == b"dirval"
        assert "user.d" in os.listxattr(d)


@pytest.mark.fuse
def test_xattr_survives_remount(fused_bin: str, fused_image: str, mount_dir: str, logs_dir: str, tmp_path: str):
    # Use an isolated copy so we control the full lifecycle.
    img = os.path.join(tmp_path, "xpersist.img")
    shutil.copyfile(fused_image, img)
    mp = os.path.join(tmp_path, "mnt")
    f = os.path.join(mp, "xpersist")
    with (mount_fuse(fused_bin, img, mp, logs_dir),
          open(f, "wb") as fh):
        fh.write(b"data")
        os.setxattr(f, "user.p", b"keepme")
        assert os.getxattr(f, "user.p") == b"keepme"

    # Remount the same image: xattr must still be there.
    with mount_fuse(fused_bin, img, mp, logs_dir):
        assert os.getxattr(f, "user.p") == b"keepme"
        os.unlink(f)
