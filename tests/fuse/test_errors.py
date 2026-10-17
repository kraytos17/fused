import errno
import os

import pytest

from fused_test.io import make_dir, make_file


@pytest.mark.fuse
def test_rmdir_file_enotdir(private_mount: str):
    with make_file(os.path.join(private_mount, "notadir_file"), b"x") as f:
        with pytest.raises(OSError) as exc:
            os.rmdir(f)
        assert exc.value.errno == errno.ENOTDIR


@pytest.mark.fuse
def test_rmdir_nonempty_enotempty(private_mount: str):
    with (make_dir(os.path.join(private_mount, "nonempty_dir")) as d,
          make_file(os.path.join(d, "child"), b"x")):
        with pytest.raises(OSError) as exc:
            os.rmdir(d)
        assert exc.value.errno == errno.ENOTEMPTY


@pytest.mark.fuse
def test_open_readonly_for_write_eacces(private_mount: str):
    with make_file(os.path.join(private_mount, "readonly_file"), b"x") as f:
        os.chmod(f, 0o444)
        with pytest.raises(OSError) as exc:
            os.open(f, os.O_WRONLY)
        assert exc.value.errno == errno.EACCES
        os.chmod(f, 0o644)


@pytest.mark.fuse
def test_stat_nonexistent_enoent(private_mount: str):
    with pytest.raises(OSError) as exc:
        os.stat(os.path.join(private_mount, "does_not_exist_xyz"))
    assert exc.value.errno == errno.ENOENT


@pytest.mark.fuse
def test_mkdir_existing_eexist(private_mount: str):
    with make_dir(os.path.join(private_mount, "eexist_dir")):
        with pytest.raises(OSError) as exc:
            os.mkdir(os.path.join(private_mount, "eexist_dir"))
        assert exc.value.errno == errno.EEXIST


@pytest.mark.fuse
def test_unimplemented_link_returns_error(private_mount: str):
    src = os.path.join(private_mount, "enosys_src")
    dst = os.path.join(private_mount, "enosys_dst")
    with make_file(src, b"x"), pytest.raises(OSError):
        os.link(src, dst)
