import errno
import os
import pytest


@pytest.mark.fuse
def test_rmdir_file_enotdir(mounted_fs: str):
    f = os.path.join(mounted_fs, "notadir_file")
    with open(f, "w") as fh:
        fh.write("x")
    with pytest.raises(OSError) as exc:
        os.rmdir(f)
    assert exc.value.errno == errno.ENOTDIR
    os.unlink(f)


@pytest.mark.fuse
def test_rmdir_nonempty_enotempty(mounted_fs: str):
    d = os.path.join(mounted_fs, "nonempty_dir")
    os.mkdir(d)
    f = os.path.join(d, "child")
    with open(f, "w") as fh:
        fh.write("x")
    with pytest.raises(OSError) as exc:
        os.rmdir(d)
    assert exc.value.errno == errno.ENOTEMPTY
    os.unlink(f)
    os.rmdir(d)


@pytest.mark.fuse
def test_open_readonly_for_write_eacces(mounted_fs: str):
    f = os.path.join(mounted_fs, "readonly_file")
    with open(f, "w") as fh:
        fh.write("x")
    os.chmod(f, 0o444)
    with pytest.raises(OSError) as exc:
        os.open(f, os.O_WRONLY)
    assert exc.value.errno == errno.EACCES
    os.chmod(f, 0o644)
    os.unlink(f)


@pytest.mark.fuse
def test_stat_nonexistent_enoent(mounted_fs: str):
    with pytest.raises(OSError) as exc:
        os.stat(os.path.join(mounted_fs, "does_not_exist_xyz"))
    assert exc.value.errno == errno.ENOENT


@pytest.mark.fuse
def test_mkdir_existing_eexist(mounted_fs: str):
    d = os.path.join(mounted_fs, "eexist_dir")
    os.mkdir(d)
    with pytest.raises(OSError) as exc:
        os.mkdir(d)
    assert exc.value.errno == errno.EEXIST
    os.rmdir(d)


@pytest.mark.fuse
def test_unimplemented_link_returns_error(mounted_fs: str):
    src = os.path.join(mounted_fs, "enosys_src")
    dst = os.path.join(mounted_fs, "enosys_dst")
    with open(src, "w") as fh:
        fh.write("x")
    with pytest.raises(OSError):
        os.link(src, dst)
    os.unlink(src)


@pytest.mark.fuse
def test_access_ok(mounted_fs: str):
    f = os.path.join(mounted_fs, "access_file")
    with open(f, "w") as fh:
        fh.write("x")
    assert os.access(f, os.R_OK)
    assert os.access(f, os.W_OK)
    os.chmod(f, 0o444)
    with pytest.raises(OSError) as exc:
        os.open(f, os.O_WRONLY)
    assert exc.value.errno == errno.EACCES
    os.chmod(f, 0o644)
    os.unlink(f)
