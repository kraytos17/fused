import errno
import os

import pytest

from fused_test.io import make_dir, make_file


@pytest.mark.fuse
def test_rmdir_file_enotdir(mounted_fs: str):
    with make_file(os.path.join(mounted_fs, "notadir_file"), b"x") as f:
        with pytest.raises(OSError) as exc:
            os.rmdir(f)
        assert exc.value.errno == errno.ENOTDIR


@pytest.mark.fuse
def test_rmdir_nonempty_enotempty(mounted_fs: str):
    with (make_dir(os.path.join(mounted_fs, "nonempty_dir")) as d,
          make_file(os.path.join(d, "child"), b"x")):
        with pytest.raises(OSError) as exc:
            os.rmdir(d)
        assert exc.value.errno == errno.ENOTEMPTY


@pytest.mark.fuse
def test_open_readonly_for_write_eacces(mounted_fs: str):
    with make_file(os.path.join(mounted_fs, "readonly_file"), b"x") as f:
        os.chmod(f, 0o444)
        with pytest.raises(OSError) as exc:
            os.open(f, os.O_WRONLY)
        assert exc.value.errno == errno.EACCES
        os.chmod(f, 0o644)


@pytest.mark.fuse
def test_stat_nonexistent_enoent(mounted_fs: str):
    with pytest.raises(OSError) as exc:
        os.stat(os.path.join(mounted_fs, "does_not_exist_xyz"))
    assert exc.value.errno == errno.ENOENT


@pytest.mark.fuse
def test_mkdir_existing_eexist(mounted_fs: str):
    with make_dir(os.path.join(mounted_fs, "eexist_dir")):
        with pytest.raises(OSError) as exc:
            os.mkdir(os.path.join(mounted_fs, "eexist_dir"))
        assert exc.value.errno == errno.EEXIST


@pytest.mark.fuse
def test_unimplemented_link_returns_error(mounted_fs: str):
    src = os.path.join(mounted_fs, "enosys_src")
    dst = os.path.join(mounted_fs, "enosys_dst")
    with make_file(src, b"x"), pytest.raises(OSError):
        os.link(src, dst)
