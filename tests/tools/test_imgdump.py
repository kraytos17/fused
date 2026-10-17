import json
import os

import pytest

from fused_test.io import assert_cli_ok, run_cli


def get_json(imgdump: str, image: str) -> dict:
    r = run_cli(imgdump, "--json", image)
    assert_cli_ok(r)
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
    assert_cli_ok(r)
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


def _root_location(imgdump_bin: str, src_image: str):
    """Root dir location from the image itself (no hardcoded geometry)."""
    d = get_json(imgdump_bin, src_image)
    assert d["master"]["rev_min"] == 8 and d["master"]["rev_max"] == 8
    return d["master"]["cluster_size"], d["master"]["root_cluster"], d["master"]["root_sector_index"]


def _plant_root_entries(src_image: str, dst_path: str, entries: list, rc: int, ro: int, cs: int) -> None:
    """Copy src_image to dst_path, then write raw 64-byte directory entries
    into free slots of the root directory's first sector.

    entries: list of (name: bytes, flags: int, cluster: int, offset: int).
    Layout: flags u16 @0, name[16] @2, sector_index u16 @18,
    stored_cluster u64 @20 (rev-8 layout asserted by the caller).
    """
    import shutil
    import struct

    shutil.copy(src_image, dst_path)
    with open(dst_path, "r+b") as f:
        f.seek((rc * cs + ro) * 512)
        sec = bytearray(f.read(512))
        slot = 0
        for name, flags, cluster, offset in entries:
            while struct.unpack_from("<H", sec, slot * 64)[0] != 0:
                slot += 1
                assert slot < 8, "root dir first sector full"
            off = slot * 64
            struct.pack_into("<H", sec, off, flags)
            assert len(name) <= 16
            # Zero the whole name field: free slots may hold stale bytes
            # from deleted entries, which would otherwise extend the name.
            sec[off + 2 : off + 18] = bytes(16)
            sec[off + 2 : off + 2 + len(name)] = name
            struct.pack_into("<H", sec, off + 18, offset)
            struct.pack_into("<Q", sec, off + 20, cluster)
            slot += 1
        f.seek((rc * cs + ro) * 512)
        f.write(sec)


@pytest.mark.tool
def test_json_cycle_terminates(imgdump_bin: str, fused_image: str, tmp_path: str, check_bin: str):
    """A directory cycle must terminate the dumpers, not hang/crash them."""
    import json

    dst = str(tmp_path / "cycle.img")
    cs, rc, ro = _root_location(imgdump_bin, fused_image)
    # Subdirectory whose chain IS the root chain: root -> loop -> root.
    _plant_root_entries(fused_image, dst, [(b"loop", 0x25, rc, ro)], rc, ro, cs)

    r = run_cli(imgdump_bin, dst, timeout=30)
    assert_cli_ok(r)
    assert "<cycle>" in r.stdout

    r = run_cli(imgdump_bin, "--json", dst, timeout=30)
    assert_cli_ok(r)
    d = json.loads(r.stdout)
    assert "loop" in d["root"]
    assert "<cycle>" in d["root"]["loop"].get("children", {})

    r = run_cli(check_bin, dst)
    assert r.returncode != 0
    assert "DirCycle" in (r.stdout + r.stderr)


@pytest.mark.tool
def test_json_duplicate_names_surfaced(imgdump_bin: str, fused_image: str, tmp_path: str):
    """Duplicate names in one directory must all surface, not overwrite."""
    import json

    dst = str(tmp_path / "dups.img")
    cs, rc, ro = _root_location(imgdump_bin, fused_image)
    _plant_root_entries(
        fused_image,
        dst,
        [(b"dup", 0x21, rc, ro), (b"dup", 0x21, rc, ro)],
        rc,
        ro,
        cs,
    )

    r = run_cli(imgdump_bin, "--json", dst, timeout=30)
    assert_cli_ok(r)
    d = json.loads(r.stdout)
    assert "dup" in d["root"]
    assert "dup#dup2" in d["root"]

    r = run_cli(imgdump_bin, dst, timeout=30)
    assert_cli_ok(r)
    assert r.stdout.count('"dup"') == 2


@pytest.mark.tool
def test_check_read_only_clean_image(
    check_bin: str, disker_bin: str, tmp_path: str
):
    """--read-only checks a healthy image without writing to it."""
    import hashlib

    img = str(tmp_path / "ro.img")
    r = run_cli(disker_bin, "--force", "--size=1M", f"--output={img}")
    assert_cli_ok(r)
    with open(img, "rb") as f:
        digest_before = hashlib.sha256(f.read()).hexdigest()
    r = run_cli(check_bin, "--read-only", img)
    assert_cli_ok(r)
    assert "read-only mode" in r.stdout
    assert ": OK" in r.stdout
    with open(img, "rb") as f:
        digest_after = hashlib.sha256(f.read()).hexdigest()
    assert digest_before == digest_after


@pytest.mark.tool
def test_check_read_only_rejects_garbage(check_bin: str, tmp_path: str):
    path = os.path.join(tmp_path, "zero.img")
    with open(path, "wb") as f:
        f.write(b"\0" * 512)
    r = run_cli(check_bin, "--read-only", path)
    assert r.returncode == 1
