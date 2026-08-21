import errno
import fcntl
import multiprocessing as mp
import os
import struct
from contextlib import contextmanager

import pytest


def _lockf_hold_worker(path, cmd, ready, release):
    """Holds a lockf lock on [0,100) until release is set, signaling ready
    first."""
    fd = os.open(path, os.O_RDWR)
    fcntl.lockf(fd, cmd, 100, 0)
    ready.set()
    release.wait()
    fcntl.lockf(fd, fcntl.LOCK_UN, 100, 0)
    os.close(fd)


def _flock_hold_worker(path, cmd, ready, release):
    fd = os.open(path, os.O_RDWR)
    fcntl.flock(fd, cmd)
    ready.set()
    release.wait()
    fcntl.flock(fd, fcntl.LOCK_UN)
    os.close(fd)


@contextmanager
def _with_lock_holder(path, lock_cmd, holder_fn):
    """Runs a child that holds `lock_cmd` on `path`; yields control to the
    parent while the child holds the lock."""
    ctx = mp.get_context("fork")
    ready = ctx.Event()
    release = ctx.Event()
    proc = ctx.Process(target=holder_fn, args=(path, lock_cmd, ready, release))
    proc.start()
    try:
        assert ready.wait(10), "lock holder never acquired the lock"
        yield
    finally:
        release.set()
        proc.join(10)
        assert not proc.is_alive(), "lock holder did not exit"


@pytest.mark.fuse
def test_lockf_exclusive_conflicts_with_other_process(mounted_fs: str):
    f = os.path.join(mounted_fs, "lockf1")
    with open(f, "wb") as fh:
        fh.write(b"x" * 512)
    try:
        with _with_lock_holder(f, fcntl.LOCK_EX, _lockf_hold_worker):
            fd = os.open(f, os.O_RDWR)
            try:
                # Child holds EX on the whole file; parent EX conflicts.
                with pytest.raises(OSError) as exc:
                    fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                assert exc.value.errno == errno.EAGAIN
                # Parent SH also conflicts.
                with pytest.raises(OSError) as exc:
                    fcntl.lockf(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
                assert exc.value.errno == errno.EAGAIN
                # Non-overlapping region succeeds.
                fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB, 100, 1024)
            finally:
                os.close(fd)
    finally:
        os.unlink(f)


@pytest.mark.fuse
def test_lockf_shared_allows_other_process_shared(mounted_fs: str):
    f = os.path.join(mounted_fs, "lockf2")
    with open(f, "wb") as fh:
        fh.write(b"x" * 512)
    try:
        with _with_lock_holder(f, fcntl.LOCK_SH, _lockf_hold_worker):
            fd = os.open(f, os.O_RDWR)
            try:
                # Child holds SH; parent SH succeeds.
                fcntl.lockf(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
                # Parent EX conflicts (child SH).
                with pytest.raises(OSError) as exc:
                    fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                assert exc.value.errno == errno.EAGAIN
                fcntl.lockf(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)
    finally:
        os.unlink(f)


@pytest.mark.fuse
def test_flock_exclusive_conflicts_with_other_fd(mounted_fs: str):
    f = os.path.join(mounted_fs, "flock1")
    with open(f, "wb") as fh:
        fh.write(b"x")
    try:
        fd1 = os.open(f, os.O_RDWR)
        fd2 = os.open(f, os.O_RDWR)
        try:
            # flock locks are per open-file-description: same process, two
            # fds, so they ARE different owners.
            fcntl.flock(fd1, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with pytest.raises(OSError) as exc:
                fcntl.flock(fd2, fcntl.LOCK_EX | fcntl.LOCK_NB)
            assert exc.value.errno == errno.EAGAIN
            fcntl.flock(fd1, fcntl.LOCK_UN)
            fcntl.flock(fd2, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(fd1)
            os.close(fd2)
    finally:
        os.unlink(f)


@pytest.mark.fuse
def test_flock_shared_allows_other_fd_shared(mounted_fs: str):
    f = os.path.join(mounted_fs, "flock2")
    with open(f, "wb") as fh:
        fh.write(b"x")
    try:
        fd1 = os.open(f, os.O_RDWR)
        fd2 = os.open(f, os.O_RDWR)
        try:
            # Two shared holders (different open file descriptions).
            fcntl.flock(fd1, fcntl.LOCK_SH | fcntl.LOCK_NB)
            fcntl.flock(fd2, fcntl.LOCK_SH | fcntl.LOCK_NB)
            # Exclusive conflicts with the shared holders.
            fd3 = os.open(f, os.O_RDWR)
            try:
                with pytest.raises(OSError) as exc:
                    fcntl.flock(fd3, fcntl.LOCK_EX | fcntl.LOCK_NB)
                assert exc.value.errno == errno.EAGAIN
            finally:
                os.close(fd3)
            fcntl.flock(fd1, fcntl.LOCK_UN)
            fcntl.flock(fd2, fcntl.LOCK_UN)
        finally:
            os.close(fd1)
            os.close(fd2)
    finally:
        os.unlink(f)


@pytest.mark.fuse
def test_flock_release_drops_lock(mounted_fs: str):
    f = os.path.join(mounted_fs, "flock3")
    with open(f, "wb") as fh:
        fh.write(b"x")
    try:
        fd1 = os.open(f, os.O_RDWR)
        # Acquire EX, close the fd (release drops the lock), then another
        # fd can take EX immediately.
        fcntl.flock(fd1, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.close(fd1)
        fd2 = os.open(f, os.O_RDWR)
        try:
            fcntl.flock(fd2, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(fd2)
    finally:
        os.unlink(f)


@pytest.mark.fuse
def test_lockf_getlk_reports_conflict(mounted_fs: str):
    f = os.path.join(mounted_fs, "lockf3")
    with open(f, "wb") as fh:
        fh.write(b"x" * 512)
    try:
        with _with_lock_holder(f, fcntl.LOCK_EX, _lockf_hold_worker):
            fd = os.open(f, os.O_RDWR)
            try:
                # F_GETLK via fcntl() with a struct flock.
                flk = struct.pack("hhqqi", fcntl.F_WRLCK, 0, 0, 100, 0)
                res = fcntl.fcntl(fd, fcntl.F_GETLK, flk)
                l_type, _whence, _start, _len, _pid = struct.unpack("hhqqi", res)
                assert l_type == fcntl.F_WRLCK
            finally:
                os.close(fd)
    finally:
        os.unlink(f)