# tests/fused_test/io.py — Shared file/cli helpers for FUSE test suites.

import os
import subprocess
from contextlib import contextmanager
from pathlib import Path


def read(path: str | os.PathLike) -> bytes:
    return Path(path).read_bytes()


def write(path: str | os.PathLike, data: bytes) -> None:
    Path(path).write_bytes(data)


def run_cli(bin_path: str, *args: str, timeout: float | None = None) -> subprocess.CompletedProcess:
    """Run a fused CLI binary and capture stdout/stderr."""
    return subprocess.run([bin_path, *args], capture_output=True, text=True, check=False, timeout=timeout)


def assert_cli_ok(result: subprocess.CompletedProcess) -> None:
    """Assert a CLI completed with returncode 0, dumping output on failure."""
    assert result.returncode == 0, f"cli failed:\n{result.stdout}\n{result.stderr}"


def assert_check_clean(check_bin: str, image: str) -> None:
    """Assert `check` passes on image, dumping output on failure."""
    assert_cli_ok(run_cli(check_bin, image))


@contextmanager
def make_file(path: str, data: bytes = b""):
    """Create a file (parent must exist), yield its path, unlink on exit."""
    with open(path, "wb") as fh:
        fh.write(data)
    try:
        yield path
    finally:
        os.unlink(path)


@contextmanager
def make_dir(path: str):
    """Create a directory, yield its path, rmdir on exit (must be empty)."""
    os.mkdir(path)
    try:
        yield path
    finally:
        os.rmdir(path)


def write_synced(path: str | os.PathLike, data: bytes) -> None:
    """Write data fully synced: file fsync + containing-dir fsync.

    Chunked writes force multi-sector chains on larger payloads.
    """
    fd = os.open(path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o644)
    try:
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
