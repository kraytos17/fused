import json
import os

import pytest

from fused_test.io import run_cli


def get_json(imgdump: str, image: str) -> dict:
    r = run_cli(imgdump, "--json", image)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


@pytest.mark.tool
def test_json_validates(imgdump_bin: str, fused_image: str):
    d = get_json(imgdump_bin, fused_image)
    assert d["master"]["rev_min"] == 8
    assert d["master"]["rev_max"] == 8
    assert d["master"]["cluster_size"] == 16
    assert "Kernel" in d["root"]
    assert d["root"]["Kernel"]["kind"] == "FILE"
    assert d["root"]["Kernel"]["size"] == 60


@pytest.mark.tool
def test_json_deep(imgdump_bin: str, fused_image: str):
    d = get_json(imgdump_bin, fused_image)
    for k in ["master", "clusters", "allocated", "free", "total", "root"]:
        assert k in d, f"missing key '{k}'"
    assert len(d["clusters"]) == 128
    for ci, c in enumerate(d["clusters"]):
        for k in ["idx", "flags", "sector_index"]:
            assert k in c, f"cluster[{ci}] missing '{k}'"
    assert d["free"] + d["allocated"] == d["total"]
    rk = d["root"]["Kernel"]
    for k in ["kind", "size", "cluster", "sector", "dt"]:
        assert k in rk, f"Kernel missing '{k}'"


@pytest.mark.tool
def test_text_output(imgdump_bin: str, fused_image: str):
    r = run_cli(imgdump_bin, fused_image)
    assert r.returncode == 0
    for keyword in ["MasterRecord", "ALLOCATED", "Directory Tree", "Kernel", "CE[00]"]:
        assert keyword in r.stdout, f"missing '{keyword}'"


@pytest.mark.tool
def test_hex_shows_name(imgdump_bin: str, fused_image: str):
    r = run_cli(imgdump_bin, "--hex=/Kernel", fused_image)
    assert "Kernel" in r.stdout


@pytest.mark.tool
def test_hex_dir_error(imgdump_bin: str, fused_image: str):
    r = run_cli(imgdump_bin, "--hex=/", fused_image)
    assert r.returncode == 1
    assert "is a directory" in r.stderr + r.stdout


@pytest.mark.tool
def test_help_text(imgdump_bin: str):
    r = run_cli(imgdump_bin, "--help")
    assert "Usage:" in r.stdout


@pytest.mark.tool
def test_missing_path(imgdump_bin: str):
    r = run_cli(imgdump_bin)
    assert r.returncode == 1


@pytest.mark.tool
def test_invalid_path(imgdump_bin: str):
    r = run_cli(imgdump_bin, "/nonexistent")
    assert r.returncode == 1


@pytest.mark.tool
def test_corrupted_image_zero(imgdump_bin: str, tmp_path: str):
    path = os.path.join(tmp_path, "zero.img")
    with open(path, "wb") as f:
        f.write(b"\0" * 512)
    r = run_cli(imgdump_bin, path)
    assert r.returncode == 1


@pytest.mark.tool
def test_corrupted_image_end_sig(imgdump_bin: str, tmp_path: str):
    path = os.path.join(tmp_path, "bad_sig.img")
    data = bytearray(512)
    data[0:7] = b"FUSED\0\0"
    data[7] = 5
    data[8] = 5
    data[510:512] = b"\x00\x00"
    with open(path, "wb") as f:
        f.write(data)
    r = run_cli(imgdump_bin, path)
    assert r.returncode == 1
