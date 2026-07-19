import os
import subprocess
import pytest


@pytest.fixture
def tmp_img(tmp_path: str) -> str:
    return os.path.join(tmp_path, "test.img")


def _run(disker: str, args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run([disker] + args, capture_output=True, text=True)


@pytest.mark.tool
def test_default_format(disker_bin: str, tmp_img: str):
    r = _run(disker_bin, ["--force", "--output", tmp_img])
    assert r.returncode == 0
    assert os.path.getsize(tmp_img) == 1048576


@pytest.mark.tool
def test_custom_size_4M(disker_bin: str, tmp_img: str):
    r = _run(disker_bin, ["--force", "--output", tmp_img, "--size=4M"])
    assert r.returncode == 0
    assert os.path.getsize(tmp_img) == 4 * 1024 * 1024


@pytest.mark.tool
def test_custom_cluster_64(disker_bin: str, tmp_img: str):
    r = _run(disker_bin, ["--force", "--output", tmp_img, "--size=8M", "--cluster-size=64"])
    assert r.returncode == 0
    assert os.path.getsize(tmp_img) == 8 * 1024 * 1024


@pytest.mark.tool
def test_positional_output(disker_bin: str, tmp_img: str):
    r = _run(disker_bin, ["--force", tmp_img])
    assert r.returncode == 0
    assert os.path.isfile(tmp_img)


@pytest.mark.tool
def test_help(disker_bin: str, tmp_img: str):
    r = _run(disker_bin, ["--help"])
    assert "format" in r.stdout


@pytest.mark.tool
def test_force_guard(disker_bin: str, tmp_img: str):
    _run(disker_bin, ["--force", "--output", tmp_img])
    r2 = _run(disker_bin, ["--output", tmp_img])
    assert r2.returncode == 1


@pytest.mark.tool
def test_size_validation(disker_bin: str, tmp_img: str):
    r = _run(disker_bin, ["--force", "--output", tmp_img, "--size=1K"])
    assert r.returncode == 1
