# tests/fused_test/mount.py — FUSE mount lifecycle as a context manager.
#
# Usage:
#   with MountContext(bin="build/fused", image="fused.img", mount="mnt") as ctx:
#       # ctx.mount is the mount point
#       os.listdir(ctx.mount)

import contextlib
import os
import subprocess
import time


class MountError(Exception):
    pass


class LiveMount:
    """A running daemon + its mount point, with crash-test controls.

    Unlike mount_fuse, exiting the killable context does NOT unmount: the
    caller owns teardown (kill9 + detach, or a manual clean unmount).
    """

    def __init__(self, proc: subprocess.Popen, mount: str, log_path: str):
        self.proc = proc
        self.mount = mount
        self.log_path = log_path

    def kill9(self) -> None:
        """SIGKILL the daemon: simulates power loss. No unmount, no flush,
        no teardown — exactly what -uz + a fresh mount must survive."""
        self.proc.kill()
        self.proc.wait()

    def detach(self, timeout: float = 5.0) -> None:
        """Lazy-unmount a dead mount point and wait until it disappears,
        so a remount cannot attach over (or observe) the dying mount."""
        subprocess.run(["fusermount3", "-uz", self.mount],
                       capture_output=True, timeout=5, check=False)
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        deadline = time.time() + timeout
        while os.path.ismount(self.mount) and time.time() < deadline:
            time.sleep(0.05)


def _wait_for_mount(proc: subprocess.Popen, mount: str, log_path: str) -> None:
    """Wait up to 5 seconds for the mount to appear; kill + raise on timeout."""
    for _ in range(50):
        if os.path.ismount(mount):
            return
        time.sleep(0.1)
    proc.kill()
    with open(log_path) as f:
        log = f.read()
    raise MountError(f"mount did not appear after 5s\n{log}")


def _spawn(bin: str, image: str, mount: str, logs_dir: str,
           opts: list[str], log_name: str, stack: contextlib.ExitStack):
    """Spawn the daemon; returns (proc, log_path). Log file is stack-bound."""
    os.makedirs(mount, exist_ok=True)
    os.makedirs(logs_dir, exist_ok=True)
    log_path = os.path.join(logs_dir, log_name)
    fuse_out = stack.enter_context(open(log_path, "w"))
    proc = subprocess.Popen(
        [bin, image, "-f", "-d", mount] + opts,
        stdout=fuse_out, stderr=subprocess.STDOUT,
    )
    return proc, log_path


@contextlib.contextmanager
def mount_fuse_killable(bin: str, image: str, mount: str, logs_dir: str = "logs",
                        opts: list[str] | None = None, log_name: str = "fused_fuse.log"):
    """Mount without teardown-on-exit; yields a LiveMount.

    The caller must finish with either kill9()+detach() (crash path) or a
    manual clean unmount. On exception the daemon is reaped gracefully and
    a stale mount is detached lazily, so failures never leak mounts.
    """
    opts = opts or []
    with contextlib.ExitStack() as stack:
        proc, log_path = _spawn(bin, image, mount, logs_dir, opts, log_name, stack)
        try:
            _wait_for_mount(proc, mount, log_path)
            yield LiveMount(proc, mount, log_path)
        finally:
            if proc.poll() is None:
                _umount_fuse(proc, mount)
            else:
                proc.wait()
                subprocess.run(["fusermount3", "-uz", mount],
                               capture_output=True, timeout=5, check=False)


@contextlib.contextmanager
def mount_fuse(bin: str, image: str, mount: str, logs_dir: str = "logs",
               opts: list[str] | None = None):
    """Mount a fused filesystem and unmount on exit.

    Yields the mount point path.
    Raises MountError if the mount doesn't appear within 5 seconds.
    """
    with contextlib.ExitStack() as stack:
        proc, log_path = _spawn(bin, image, mount, logs_dir, opts or [], "fused_fuse.log", stack)
        try:
            _wait_for_mount(proc, mount, log_path)
            yield mount

        finally:
            _umount_fuse(proc, mount)


def _umount_fuse(proc: subprocess.Popen, mount: str) -> None:
    """Try clean unmount, then force-kill the daemon."""
    # Try fusermount3 -u first (graceful)
    subprocess.run(["fusermount3", "-u", mount],
                   capture_output=True, timeout=5, check=False)

    if proc.poll() is not None:
        return  # daemon exited cleanly

    # Graceful kill
    proc.terminate()
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()

    # Lazy unmount in case anything is left
    subprocess.run(["fusermount3", "-uz", mount],
                   capture_output=True, timeout=5, check=False)
