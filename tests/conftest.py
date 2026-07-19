# tests/conftest.py — Shared pytest fixtures for fused test suites.
import os

import pytest

from fused_test.mount import mount_fuse


def pytest_addoption(parser):
    parser.addoption("--fused", default="build/fused", help="Path to the fused binary")
    parser.addoption("--image", default="fused.img", help="Path to the disk image")
    parser.addoption("--mount", default="mnt", help="Mount point directory")
    parser.addoption("--logs", default="logs", help="Logs output directory")
    parser.addoption("--stress-duration", type=int, default=15, help="Duration in seconds for stress test")
    parser.addoption("--disker", default="build/format", help="Path to the format tool binary")
    parser.addoption("--imgdump", default="build/imgdump", help="Path to the imgdump tool binary")


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
def mounted_fs(fused_bin: str, fused_image: str, mount_dir: str, logs_dir: str):
    """Mount the FUSE filesystem and yield the mount point path."""
    os.makedirs(mount_dir, exist_ok=True)
    with mount_fuse(fused_bin, fused_image, mount_dir, logs_dir) as mp:
        yield mp
