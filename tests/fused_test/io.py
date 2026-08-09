# tests/fused_test/io.py — Shared file/cli helpers for FUSE test suites.

import os
import subprocess
from contextlib import contextmanager
from pathlib import Path


def read(path: str | os.PathLike) -> bytes:
    return Path(path).read_bytes()


def write(path: str | os.PathLike, data: bytes) -> None:
    Path(path).write_bytes(data)


def run_cli(bin_path: str, *args: str) -> subprocess.CompletedProcess:
    """Run a fused CLI binary and capture stdout/stderr."""
    return subprocess.run([bin_path, *args], capture_output=True, text=True, check=False)


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
