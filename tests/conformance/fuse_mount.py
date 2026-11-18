#!/usr/bin/env python3
# tests/conformance/fuse_mount.py — FUSE mount lifecycle primitive.
#
# The one place that owns "mount a fused image, wait for it, tear it down
# cleanly": spawn the daemon, poll /proc/self/mountinfo (stat-based checks
# fail closed on corrupt images — never stat the mount to test liveness),
# unmount with fusermount3 -u → -uz fallback, then WAITPID on the daemon so
# its final journal checkpoint lands before any checker touches the image.
# Replaces the bash mount/unmount/trap dances in pjdfstest.sh and fsx.sh
# (T-01/T-02 Python port); fuzz_image.py adopts this for its live path.
#
# Everything is stdlib. No globals. Every cleanup path runs even on
# exceptions (context manager), matching the old bash traps — but without
# the subshell/exit semantics that bit us repeatedly.
"""FUSE mount lifecycle for the oracle harnesses."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

MOUNT_POLL_INTERVAL = 0.1
MOUNT_TIMEOUT = 10.0
DAEMON_EXIT_WAIT = 10.0

_SCAN_RE = re.compile(r"scan: (\d+) errors, (\d+) warnings")


class MountError(RuntimeError):
    """The mount did not come up (daemon died or timed out)."""

    def __init__(self, message: str, log_tail: str = ""):
        super().__init__(message)
        self.log_tail = log_tail


def is_mounted(mnt: str) -> bool:
    """Mount-table membership via /proc/self/mountinfo (no FUSE touch).

    mountpoint(1)/os.path.ismount stat the path; on a fail-closed mount the
    stat itself returns ENOENT and would hide a present-but-useless mount.
    Mountpoint is field 5 of mountinfo; our paths never contain spaces or
    the \\040 escape, so a plain split is exact.
    """
    try:
        with open("/proc/self/mountinfo") as f:
            for line in f:
                parts = line.rstrip("\n").split(" ")
                if len(parts) > 4 and parts[4] == mnt:
                    return True
    except OSError:
        pass
    return False


def format_image(format_bin: str, image: str, size: str = "64M",
                 cluster_size: str = "16") -> None:
    """Format a fresh image; raises on any failure."""
    r = subprocess.run(
        [format_bin, "--force", f"--output={image}", f"--size={size}",
         f"--cluster-size={cluster_size}"],
        capture_output=True, text=True, timeout=120, check=False,
    )  # returncode handled below
    if r.returncode != 0:
        raise RuntimeError(f"format failed rc={r.returncode}: {r.stderr.strip()}")


def check_image_clean(check_bin: str, image: str) -> tuple[bool, int, int, str]:
    """Gate an image: read-only scan first (recovery must not hide a crash
    bug), then RW. Both must report 0 errors AND 0 warnings — orphans after
    an exerciser workload are leaks until proven otherwise.

    Returns (ok, errors, warnings, combined_output).
    """
    combined = []
    errors = warnings = -1
    for mode in (["--read-only"], []):
        r = subprocess.run(
            [check_bin, *mode, image, "--log-level=warn"],
            capture_output=True, text=True, timeout=300, check=False,
        )  # returncode decides below
        combined.append(r.stdout)
        if r.returncode != 0:
            combined.append(r.stderr)
            return False, errors, warnings, "".join(combined)
        m = _SCAN_RE.search(r.stdout)
        if not m:
            return False, errors, warnings, "".join(combined)
        errors, warnings = int(m.group(1)), int(m.group(2))
        if errors != 0 or warnings != 0:
            return False, errors, warnings, "".join(combined)
    return True, errors, warnings, "".join(combined)


class FusedMount:
    """Mount a fused image; unmount + waitpid on exit.

    Usage:
        with FusedMount(fused_bin, image, args=[...]) as mnt:
            ... run things under mnt ...

    Teardown order: fusermount3 -u, then -uz if that fails; then wait up to
    DAEMON_EXIT_WAIT for the daemon (its final checkpoint must land before
    the next user of the image); terminate→kill if it hangs. If we created
    the mount dir ourselves it is removed on exit.
    """

    def __init__(self, fused_bin: str, image: str, *,
                 mount_dir: str | None = None,
                 args: list[str] | None = None,
                 timeout: float = MOUNT_TIMEOUT):
        self.fused_bin = fused_bin
        self.image = image
        self.args = list(args or [])
        self.timeout = timeout
        self._owns_dir = mount_dir is None
        self.mount_dir = mount_dir or tempfile.mkdtemp(
            prefix="fused_mnt_", dir="/dev/shm")
        self.proc: subprocess.Popen | None = None
        self.log_path: str | None = None
        self._mounted = False

    # -- lifecycle ------------------------------------------------------
    def mount(self) -> str:
        os.makedirs(self.mount_dir, exist_ok=True)
        cmd = [self.fused_bin, *self.args, self.image, "-f", self.mount_dir]
        self.proc = subprocess.Popen(
            cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise MountError(
                    f"daemon died during mount (rc={self.proc.returncode})",
                    self.log_tail(),
                )
            if is_mounted(self.mount_dir):
                self._mounted = True
                return self.mount_dir
            time.sleep(MOUNT_POLL_INTERVAL)
        self.unmount()
        raise MountError("mount never appeared", self.log_tail())

    def unmount(self) -> None:
        if self.proc is None:
            return
        self._mounted = False
        if is_mounted(self.mount_dir):
            r = subprocess.run(["fusermount3", "-u", self.mount_dir],
                               capture_output=True, timeout=30, check=False)
            if r.returncode != 0:
                subprocess.run(["fusermount3", "-uz", self.mount_dir],
                               capture_output=True, timeout=30, check=False)
        try:
            self.proc.wait(timeout=DAEMON_EXIT_WAIT)
        except subprocess.TimeoutExpired:
            # Daemon ignored fusermount's FINISH: hard-stop it (its exit
            # status is reported by the caller's liveness check).
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
        if self._owns_dir:
            shutil.rmtree(self.mount_dir, ignore_errors=True)
        self.mount_dir = "" if self._owns_dir else self.mount_dir

    def __enter__(self) -> str:
        return self.mount()

    def __exit__(self, exc_type, exc, tb) -> None:
        self.unmount()

    def __del__(self):
        # Best-effort backstop (kill -9 of a namespace skips __exit__).
        if self.proc is not None and self.proc.poll() is None:
            try:
                self.unmount()
            except Exception as e:  # noqa: BLE001 — __del__ must not raise
                print(f"fused_mount: backstop unmount failed: {e}",
                      file=sys.stderr)

    # -- introspection ---------------------------------------------------
    @property
    def alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    @property
    def returncode(self) -> int | None:
        return self.proc.returncode if self.proc is not None else None

    def log_tail(self, n: int = 20) -> str:
        if self.log_path is None:
            return ""
        try:
            with open(self.log_path, errors="replace") as f:
                return "".join(f.readlines()[-n:])
        except OSError:
            return ""
