# tests/conftest.py — Shared pytest fixtures for fused test suites.
import os

import pytest

from fused_test.io import assert_check_clean, run_cli
from fused_test.mount import mount_fuse


def pytest_addoption(parser):
    parser.addoption("--fused", default="build/fused", help="Path to the fused binary")
    parser.addoption("--image", default="fused.img", help="Path to the disk image")
    parser.addoption("--mount", default="mnt", help="Mount point directory")
    parser.addoption("--logs", default="logs", help="Logs output directory")
    parser.addoption("--disker", default="build/format", help="Path to the format tool binary")
    parser.addoption("--imgdump", default="build/imgdump", help="Path to the imgdump tool binary")
    parser.addoption("--check", default="build/check", help="Path to the fsck-like check binary")


@pytest.fixture
def fused_bin(request: pytest.FixtureRequest) -> str:
    return request.config.getoption("--fused")


@pytest.fixture
def fused_image(request: pytest.FixtureRequest) -> str:
    return request.config.getoption("--image")


@pytest.fixture
def mount_dir(request: pytest.FixtureRequest) -> str:
    return request.config.getoption("--mount")


@pytest.fixture
def logs_dir(request: pytest.FixtureRequest) -> str:
    return request.config.getoption("--logs")


@pytest.fixture
def disker_bin(request: pytest.FixtureRequest) -> str:
    return request.config.getoption("--disker")


@pytest.fixture
def imgdump_bin(request: pytest.FixtureRequest) -> str:
    return request.config.getoption("--imgdump")


@pytest.fixture
def check_bin(request: pytest.FixtureRequest) -> str:
    return request.config.getoption("--check")


@pytest.fixture
def mounted_fs(fused_bin: str, fused_image: str, mount_dir: str, logs_dir: str):
    """Mount the FUSE filesystem and yield the mount point path."""
    os.makedirs(mount_dir, exist_ok=True)
    with mount_fuse(fused_bin, fused_image, mount_dir, logs_dir) as mp:
        yield mp


@pytest.fixture
def path_for(mounted_fs: str):
    """Return a helper that joins names onto the mount point."""
    return lambda name: os.path.join(mounted_fs, name)


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
