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


@contextlib.contextmanager
def mount_fuse(bin: str, image: str, mount: str, logs_dir: str = "logs",
               opts: list[str] | None = None):
    """Mount a fused filesystem and unmount on exit.

    Yields the mount point path.
    Raises MountError if the mount doesn't appear within 5 seconds.
    """
    opts = opts or []
    os.makedirs(mount, exist_ok=True)
    os.makedirs(logs_dir, exist_ok=True)

    log_path = os.path.join(logs_dir, "fused_fuse.log")
    fuse_out = open(log_path, "w")
    proc = subprocess.Popen(
        [bin, image, "-f", "-d", mount] + opts,
        stdout=fuse_out, stderr=subprocess.STDOUT,
    )

    try:
        # Wait up to 5 seconds for the mount to appear
        for _ in range(50):
            if os.path.ismount(mount):
                break
            time.sleep(0.1)
        else:
            fuse_out.close()
            proc.kill()
            with open(log_path) as f:
                log = f.read()
            raise MountError(f"mount did not appear after 5s\n{log}")

        yield mount

    finally:
        _umount_fuse(proc, mount)
        fuse_out.close()


def _umount_fuse(proc: subprocess.Popen, mount: str) -> None:
    """Try clean unmount, then force-kill the daemon."""
    # Try fusermount3 -u first (graceful)
    subprocess.run(["fusermount3", "-u", mount],
                   capture_output=True, timeout=5)

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
                   capture_output=True, timeout=5)
