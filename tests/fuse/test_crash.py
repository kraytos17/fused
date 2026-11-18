# tests/test_crash.py — Crash-consistency: SIGKILL the daemon, remount, verify.
#
# Unlike the error-path suites (which drive failing syscalls), these tests
# simulate power loss: data synced by close+fsync must survive a kill -9
# with no unmount, and the image must pass `check` afterwards. Each test
# formats a private image so crashes never perturb the shared test image.
#
# The die-after-writes tests (FUSED_DIE_AFTER_WRITES=N) go further: the
# daemon SIGKILLs itself as the Nth sector write starts — real process
# death mid-op. The syscall may raise (the connection dies with the
# daemon); whatever persisted by then is what recovery must make sense
# of, so the verifier accepts every legal crash-window outcome for the
# op and only rejects impossible ones.

import os

import pytest

from fused_test.io import assert_check_clean, write_synced
from fused_test.mount import mount_fuse_killable


@pytest.mark.fuse
def test_kill_then_data_intact(fused_bin, clean_image, check_bin, mount_dir,
                               logs_dir):
    """Written+fsynced files across several clusters survive kill -9."""

    payload = bytes((i * 31 + 7) % 256 for i in range(40 * 1024))
    with mount_fuse_killable(fused_bin, clean_image, mount_dir, logs_dir,
                             log_name="crash1.log") as mnt:
        os.mkdir(os.path.join(mnt.mount, "sub"))
        write_synced(os.path.join(mnt.mount, "small.txt"), b"hello crash\n")
        write_synced(os.path.join(mnt.mount, "big.bin"), payload)
        write_synced(os.path.join(mnt.mount, "sub", "nested.txt"), b"nested\n")
        mnt.kill9()
        mnt.detach()

    with mount_fuse_killable(fused_bin, clean_image, mount_dir, logs_dir,
                             log_name="crash2.log") as mnt:
        try:
            assert open(os.path.join(mnt.mount, "small.txt"), "rb").read() == b"hello crash\n"
            assert open(os.path.join(mnt.mount, "big.bin"), "rb").read() == payload
            assert open(os.path.join(mnt.mount, "sub", "nested.txt"), "rb").read() == b"nested\n"
            assert sorted(os.listdir(mnt.mount)) == ["Kernel", "big.bin", "small.txt", "sub"]
        finally:
            mnt.kill9()
            mnt.detach()

    assert_check_clean(check_bin, clean_image)


@pytest.mark.fuse
def test_kill_after_truncate_extend(fused_bin, clean_image, check_bin, mount_dir,
                                    logs_dir):
    """A truncate-extended chain (fresh allocation) survives kill -9."""

    with mount_fuse_killable(fused_bin, clean_image, mount_dir, logs_dir,
                             log_name="crasht1.log") as mnt:
        p = os.path.join(mnt.mount, "grow.bin")
        write_synced(p, b"head\n")
        fd = os.open(p, os.O_WRONLY)
        try:
            os.ftruncate(fd, 3 * 512 + 100)
            os.fsync(fd)
        finally:
            os.close(fd)
        mnt.kill9()
        mnt.detach()

    with mount_fuse_killable(fused_bin, clean_image, mount_dir, logs_dir,
                             log_name="crasht2.log") as mnt:
        try:
            p = os.path.join(mnt.mount, "grow.bin")
            assert os.stat(p).st_size == 3 * 512 + 100
            with open(p, "rb") as fh:
                assert fh.read(5) == b"head\n"
        finally:
            mnt.kill9()
            mnt.detach()

    assert_check_clean(check_bin, clean_image)


@pytest.mark.fuse
def test_kill_after_unlink(fused_bin, clean_image, check_bin, mount_dir,
                           logs_dir):
    """A synced unlink survives kill -9; siblings are undisturbed."""

    with mount_fuse_killable(fused_bin, clean_image, mount_dir, logs_dir,
                             log_name="crashu1.log") as mnt:
        write_synced(os.path.join(mnt.mount, "gone.txt"), b"bye\n")
        write_synced(os.path.join(mnt.mount, "stays.txt"), b"hi\n")
        os.unlink(os.path.join(mnt.mount, "gone.txt"))
        dir_fd = os.open(mnt.mount, os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
        mnt.kill9()
        mnt.detach()

    with mount_fuse_killable(fused_bin, clean_image, mount_dir, logs_dir,
                             log_name="crashu2.log") as mnt:
        try:
            assert sorted(os.listdir(mnt.mount)) == ["Kernel", "stays.txt"]
            assert open(os.path.join(mnt.mount, "stays.txt"), "rb").read() == b"hi\n"
        finally:
            mnt.kill9()
            mnt.detach()

    assert_check_clean(check_bin, clean_image)


@pytest.mark.fuse
def test_kill_after_truncate_shrink(fused_bin, clean_image, check_bin, mount_dir,
                                    logs_dir):
    """A truncate-shrunk multi-extent chain survives kill -9 with content."""
    # Sector-tagged pattern: sector i holds byte (i % 256) throughout.
    data = b"".join(bytes([i % 256]) * 512 for i in range(40))

    with mount_fuse_killable(fused_bin, clean_image, mount_dir, logs_dir,
                             log_name="crashs1.log") as mnt:
        p = os.path.join(mnt.mount, "shrink.bin")
        write_synced(p, data)
        fd = os.open(p, os.O_WRONLY)
        try:
            os.ftruncate(fd, 20 * 512)
            os.fsync(fd)
        finally:
            os.close(fd)
        mnt.kill9()
        mnt.detach()

    with mount_fuse_killable(fused_bin, clean_image, mount_dir, logs_dir,
                             log_name="crashs2.log") as mnt:
        try:
            p = os.path.join(mnt.mount, "shrink.bin")
            assert os.stat(p).st_size == 20 * 512
            with open(p, "rb") as fh:
                assert fh.read() == data[:20 * 512]
        finally:
            mnt.kill9()
            mnt.detach()

    assert_check_clean(check_bin, clean_image)


@pytest.mark.fuse
def test_kill_after_rename_long_names(fused_bin, clean_image, check_bin,
                                      mount_dir, logs_dir):
    """Rename of a long name survives kill -9; the sibling name is intact."""
    n1 = "a" * 60
    n2 = "b" * 60
    n3 = "c" * 60

    with mount_fuse_killable(fused_bin, clean_image, mount_dir, logs_dir,
                             log_name="crashr1.log") as mnt:
        write_synced(os.path.join(mnt.mount, n1), b"first\n")
        write_synced(os.path.join(mnt.mount, n2), b"second\n")
        os.rename(os.path.join(mnt.mount, n1), os.path.join(mnt.mount, n3))
        dir_fd = os.open(mnt.mount, os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
        mnt.kill9()
        mnt.detach()

    with mount_fuse_killable(fused_bin, clean_image, mount_dir, logs_dir,
                             log_name="crashr2.log") as mnt:
        try:
            assert sorted(os.listdir(mnt.mount)) == ["Kernel", n2, n3]
            assert open(os.path.join(mnt.mount, n2), "rb").read() == b"second\n"
            assert open(os.path.join(mnt.mount, n3), "rb").read() == b"first\n"
        finally:
            mnt.kill9()
            mnt.detach()

    assert_check_clean(check_bin, clean_image)


# die-after-writes: the daemon kills itself mid-op at an exact write
# index (T-05 slice 2). The injected-fault sweep (crash_sweep_test.odin)
# enumerates every cut point in-process; these tests anchor the same
# model to a real SIGKILL against the real daemon and FUSE teardown.


def _die_run(fused_bin, image, mount_dir, logs_dir, log_name, n_writes, op):
    """Mount with FUSED_DIE_AFTER_WRITES=N armed and run op. The daemon
    dies mid-op (or the op completes if N overshoots its write count —
    both are fine; the verifier accepts every legal outcome)."""
    os.environ["FUSED_DIE_AFTER_WRITES"] = str(n_writes)
    try:
        with mount_fuse_killable(fused_bin, image, mount_dir, logs_dir,
                                 log_name=log_name) as mnt:
            try:
                op(mnt.mount)
            except OSError:
                pass  # the connection died with the daemon
            mnt.detach()
    finally:
        os.environ.pop("FUSED_DIE_AFTER_WRITES", None)


def _remount_verify(fused_bin, image, mount_dir, logs_dir, log_name,
                    check_bin, verify):
    """Remount, verify the crash-window state, prove the FS still works."""
    with mount_fuse_killable(fused_bin, image, mount_dir, logs_dir,
                             log_name=log_name) as mnt:
        try:
            verify(mnt.mount)
            probe = os.path.join(mnt.mount, "probe-after-die")
            with open(probe, "wb") as fh:
                fh.write(b"ok\n")
            os.unlink(probe)
        finally:
            mnt.kill9()
            mnt.detach()
    assert_check_clean(check_bin, image)


@pytest.mark.fuse
def test_die_after_writes_create(fused_bin, clean_image, check_bin, mount_dir,
                                 logs_dir):
    """A create cut mid-op by real SIGKILL leaves a legal state."""
    name = "d" * 60  # LFN path, several writes per create

    def op(mount):
        with open(os.path.join(mount, name), "w"):
            pass

    def verify(mount):
        p = os.path.join(mount, name)
        if os.path.exists(p):
            assert os.stat(p).st_size == 0

    _die_run(fused_bin, clean_image, mount_dir, logs_dir,
             "diew1.log", 3, op)
    _remount_verify(fused_bin, clean_image, mount_dir, logs_dir,
                    "diew2.log", check_bin, verify)


@pytest.mark.fuse
def test_die_after_writes_rename_overwrite(fused_bin, clean_image, check_bin,
                                           mount_dir, logs_dir):
    """A rename-overwrite cut mid-op never loses either name."""

    def setup(mount):
        with open(os.path.join(mount, "src"), "wb") as fh:
            fh.write(b"first\n")
            fh.flush()
            os.fsync(fh.fileno())
        with open(os.path.join(mount, "dst"), "wb") as fh:
            fh.write(b"old\n")
            fh.flush()
            os.fsync(fh.fileno())

    def op(mount):
        os.rename(os.path.join(mount, "src"), os.path.join(mount, "dst"))

    def verify(mount):
        src = os.path.join(mount, "src")
        dst = os.path.join(mount, "dst")
        assert os.path.exists(dst)  # the target never vanishes
        if os.path.exists(src):
            # not applied, or the moved entry took over while src lives
            assert open(dst, "rb").read() in (b"old\n", b"first\n")
        else:
            assert open(dst, "rb").read() == b"first\n"

    with mount_fuse_killable(fused_bin, clean_image, mount_dir, logs_dir,
                             log_name="dier0.log") as mnt:
        try:
            setup(mnt.mount)
        finally:
            mnt.kill9()
            mnt.detach()
    assert_check_clean(check_bin, clean_image)

    _die_run(fused_bin, clean_image, mount_dir, logs_dir,
             "dier1.log", 3, op)
    _remount_verify(fused_bin, clean_image, mount_dir, logs_dir,
                    "dier2.log", check_bin, verify)


@pytest.mark.fuse
def test_die_after_writes_truncate_shrink(fused_bin, clean_image, check_bin,
                                          mount_dir, logs_dir):
    """A truncate-shrink cut mid-op keeps the entry sane and readable."""
    data = b"".join(bytes([i % 256]) * 512 for i in range(32))

    def op(mount):
        p = os.path.join(mount, "shr.bin")
        fd = os.open(p, os.O_WRONLY)
        try:
            os.ftruncate(fd, 0)
        finally:
            os.close(fd)

    def verify(mount):
        p = os.path.join(mount, "shr.bin")
        size = os.stat(p).st_size
        assert size in (0, 32 * 512)
        if size == 32 * 512:
            with open(p, "rb") as fh:
                assert fh.read() == data

    with mount_fuse_killable(fused_bin, clean_image, mount_dir, logs_dir,
                             log_name="dies0.log") as mnt:
        try:
            with open(os.path.join(mnt.mount, "shr.bin"), "wb") as fh:
                fh.write(data)
                fh.flush()
                os.fsync(fh.fileno())
        finally:
            mnt.kill9()
            mnt.detach()
    assert_check_clean(check_bin, clean_image)

    _die_run(fused_bin, clean_image, mount_dir, logs_dir,
             "dies1.log", 4, op)
    _remount_verify(fused_bin, clean_image, mount_dir, logs_dir,
                    "dies2.log", check_bin, verify)
