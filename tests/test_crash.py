# tests/test_crash.py — Crash-consistency: SIGKILL the daemon, remount, verify.
#
# Unlike the error-path suites (which drive failing syscalls), these tests
# simulate power loss: data synced by close+fsync must survive a kill -9
# with no unmount, and the image must pass `check` afterwards. Each test
# formats a private image so crashes never perturb the shared test image.

import os

import pytest

from fused_test.io import run_cli
from fused_test.mount import mount_fuse_killable


def _fresh_image(disker_bin: str, dst: str) -> None:
    r = run_cli(disker_bin, "--output", dst, "--size", "1M", "--force")
    assert r.returncode == 0, f"format failed:\n{r.stdout}\n{r.stderr}"


def _check_clean(check_bin: str, image: str) -> None:
    r = run_cli(check_bin, image)
    assert r.returncode == 0, f"check failed:\n{r.stdout}\n{r.stderr}"


def _sync_file(path: str, data: bytes) -> None:
    """Write data fully synced: file fsync + containing-dir fsync."""
    fd = os.open(path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o644)
    try:
        # Chunked writes force multi-sector chains on larger payloads.
        for off in range(0, len(data), 8192):
            os.write(fd, data[off:off + 8192])
        os.fsync(fd)
    finally:
        os.close(fd)
    dir_fd = os.open(os.path.dirname(path) or ".", os.O_DIRECTORY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)


@pytest.mark.fuse
def test_kill_then_data_intact(fused_bin, disker_bin, check_bin, mount_dir,
                               logs_dir, tmp_path):
    """Written+fsynced files across several clusters survive kill -9."""
    img = str(tmp_path / "crash.img")
    _fresh_image(disker_bin, img)

    payload = bytes((i * 31 + 7) % 256 for i in range(40 * 1024))
    with mount_fuse_killable(fused_bin, img, mount_dir, logs_dir,
                             log_name="crash1.log") as mnt:
        os.mkdir(os.path.join(mnt.mount, "sub"))
        _sync_file(os.path.join(mnt.mount, "small.txt"), b"hello crash\n")
        _sync_file(os.path.join(mnt.mount, "big.bin"), payload)
        _sync_file(os.path.join(mnt.mount, "sub", "nested.txt"), b"nested\n")
        mnt.kill9()
        mnt.detach()

    with mount_fuse_killable(fused_bin, img, mount_dir, logs_dir,
                             log_name="crash2.log") as mnt:
        try:
            assert open(os.path.join(mnt.mount, "small.txt"), "rb").read() == b"hello crash\n"
            assert open(os.path.join(mnt.mount, "big.bin"), "rb").read() == payload
            assert open(os.path.join(mnt.mount, "sub", "nested.txt"), "rb").read() == b"nested\n"
            assert sorted(os.listdir(mnt.mount)) == ["Kernel", "big.bin", "small.txt", "sub"]
        finally:
            mnt.kill9()
            mnt.detach()

    _check_clean(check_bin, img)


@pytest.mark.fuse
def test_kill_after_truncate_extend(fused_bin, disker_bin, check_bin, mount_dir,
                                    logs_dir, tmp_path):
    """A truncate-extended chain (fresh allocation) survives kill -9."""
    img = str(tmp_path / "crash_trunc.img")
    _fresh_image(disker_bin, img)

    with mount_fuse_killable(fused_bin, img, mount_dir, logs_dir,
                             log_name="crasht1.log") as mnt:
        p = os.path.join(mnt.mount, "grow.bin")
        _sync_file(p, b"head\n")
        fd = os.open(p, os.O_WRONLY)
        try:
            os.ftruncate(fd, 3 * 512 + 100)
            os.fsync(fd)
        finally:
            os.close(fd)
        mnt.kill9()
        mnt.detach()

    with mount_fuse_killable(fused_bin, img, mount_dir, logs_dir,
                             log_name="crasht2.log") as mnt:
        try:
            p = os.path.join(mnt.mount, "grow.bin")
            assert os.stat(p).st_size == 3 * 512 + 100
            with open(p, "rb") as fh:
                assert fh.read(5) == b"head\n"
        finally:
            mnt.kill9()
            mnt.detach()

    _check_clean(check_bin, img)


@pytest.mark.fuse
def test_kill_after_unlink(fused_bin, disker_bin, check_bin, mount_dir,
                           logs_dir, tmp_path):
    """A synced unlink survives kill -9; siblings are undisturbed."""
    img = str(tmp_path / "crash_unlink.img")
    _fresh_image(disker_bin, img)

    with mount_fuse_killable(fused_bin, img, mount_dir, logs_dir,
                             log_name="crashu1.log") as mnt:
        _sync_file(os.path.join(mnt.mount, "gone.txt"), b"bye\n")
        _sync_file(os.path.join(mnt.mount, "stays.txt"), b"hi\n")
        os.unlink(os.path.join(mnt.mount, "gone.txt"))
        dir_fd = os.open(mnt.mount, os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
        mnt.kill9()
        mnt.detach()

    with mount_fuse_killable(fused_bin, img, mount_dir, logs_dir,
                             log_name="crashu2.log") as mnt:
        try:
            assert sorted(os.listdir(mnt.mount)) == ["Kernel", "stays.txt"]
            assert open(os.path.join(mnt.mount, "stays.txt"), "rb").read() == b"hi\n"
        finally:
            mnt.kill9()
            mnt.detach()

    _check_clean(check_bin, img)


@pytest.mark.fuse
def test_kill_after_truncate_shrink(fused_bin, disker_bin, check_bin, mount_dir,
                                    logs_dir, tmp_path):
    """A truncate-shrunk multi-extent chain survives kill -9 with content."""
    img = str(tmp_path / "crash_shrink.img")
    _fresh_image(disker_bin, img)
    # Sector-tagged pattern: sector i holds byte (i % 256) throughout.
    data = b"".join(bytes([i % 256]) * 512 for i in range(40))

    with mount_fuse_killable(fused_bin, img, mount_dir, logs_dir,
                             log_name="crashs1.log") as mnt:
        p = os.path.join(mnt.mount, "shrink.bin")
        _sync_file(p, data)
        fd = os.open(p, os.O_WRONLY)
        try:
            os.ftruncate(fd, 20 * 512)
            os.fsync(fd)
        finally:
            os.close(fd)
        mnt.kill9()
        mnt.detach()

    with mount_fuse_killable(fused_bin, img, mount_dir, logs_dir,
                             log_name="crashs2.log") as mnt:
        try:
            p = os.path.join(mnt.mount, "shrink.bin")
            assert os.stat(p).st_size == 20 * 512
            with open(p, "rb") as fh:
                assert fh.read() == data[:20 * 512]
        finally:
            mnt.kill9()
            mnt.detach()

    _check_clean(check_bin, img)


@pytest.mark.fuse
def test_kill_after_rename_long_names(fused_bin, disker_bin, check_bin,
                                      mount_dir, logs_dir, tmp_path):
    """Rename of a long name survives kill -9; the sibling name is intact."""
    img = str(tmp_path / "crash_rename.img")
    _fresh_image(disker_bin, img)
    n1 = "a" * 60
    n2 = "b" * 60
    n3 = "c" * 60

    with mount_fuse_killable(fused_bin, img, mount_dir, logs_dir,
                             log_name="crashr1.log") as mnt:
        _sync_file(os.path.join(mnt.mount, n1), b"first\n")
        _sync_file(os.path.join(mnt.mount, n2), b"second\n")
        os.rename(os.path.join(mnt.mount, n1), os.path.join(mnt.mount, n3))
        dir_fd = os.open(mnt.mount, os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
        mnt.kill9()
        mnt.detach()

    with mount_fuse_killable(fused_bin, img, mount_dir, logs_dir,
                             log_name="crashr2.log") as mnt:
        try:
            assert sorted(os.listdir(mnt.mount)) == ["Kernel", n2, n3]
            assert open(os.path.join(mnt.mount, n2), "rb").read() == b"second\n"
            assert open(os.path.join(mnt.mount, n3), "rb").read() == b"first\n"
        finally:
            mnt.kill9()
            mnt.detach()

    _check_clean(check_bin, img)
