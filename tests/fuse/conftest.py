# tests/fuse/conftest.py — Mount and image fixtures for FUSE tests.
import pytest

from fused_test.io import run_cli
from fused_test.mount import mount_fuse


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
    tmp_path. Every fuse test uses this; the shared fused.img is
    read-only input for tool tests only.
    """
    mount = str(tmp_path / "mnt")
    logs = str(tmp_path / "logs")
    with mount_fuse(fused_bin, clean_image, mount, logs) as mp:
        yield mp
