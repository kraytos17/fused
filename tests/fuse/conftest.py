# tests/fuse/conftest.py — Mount and image fixtures for FUSE tests.
import os

import pytest

from fused_test.io import run_cli
from fused_test.mount import mount_fuse


@pytest.fixture
def mounted_fs(fused_bin: str, fused_image: str, mount_dir: str, logs_dir: str):
    """Mount the shared demo filesystem and yield the mount point path.

    Only test_basic.py uses this (it asserts the embedded /Kernel);
    everything else mounts a private image via private_mount.
    """
    os.makedirs(mount_dir, exist_ok=True)
    with mount_fuse(fused_bin, fused_image, mount_dir, logs_dir) as mp:
        yield mp


@pytest.fixture
def clean_image(disker_bin: str, tmp_path):
    """Format a private 1M image and return its path.

    Tests that write use this instead of the shared fused.img, so no
    test can perturb another via image residue. tmp_path owns cleanup.
    """
    img = str(tmp_path / "clean.img")
    r = run_cli(disker_bin, "--output", img, "--size", "1M", "--force")
    assert r.returncode == 0, f"format failed:\n{r.stdout}\n{r.stderr}"
    return img


@pytest.fixture
def private_mount(fused_bin: str, clean_image: str, tmp_path):
    """Mount a private image and yield the mount point.

    Hermetic mount per test: format + mount + unmount, all under
    tmp_path. Prefer over mounted_fs for any test that writes.
    """
    mount = str(tmp_path / "mnt")
    logs = str(tmp_path / "logs")
    with mount_fuse(fused_bin, clean_image, mount, logs) as mp:
        yield mp
