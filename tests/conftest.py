# tests/conftest.py — Shared pytest options and binary-path fixtures.
#
# Mount/image fixtures live in fuse/conftest.py (used only by FUSE
# tests); tool and static suites need just the binaries below.
import pytest


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
