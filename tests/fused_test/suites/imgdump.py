# tests/fused_test/suites/imgdump.py — Validate imgdump JSON/text/hex output.

import json
import os
import subprocess

from ..result import TestSuite, TestResult


def run(imgdump: str, image: str) -> TestSuite:
    suite = TestSuite(name="Imgdump tests")

    if not os.path.isfile(imgdump):
        suite.add(TestResult(name="binary", passed=False, detail=f"not found: {imgdump}"))
        return suite
    if not os.path.isfile(image):
        suite.add(TestResult(name="image", passed=False, detail=f"not found: {image}"))
        return suite

    _test_json_validates(suite, imgdump, image)
    _test_json_deep(suite, imgdump, image)
    _test_text_output(suite, imgdump, image)
    _test_hex_shows_name(suite, imgdump, image)
    _test_hex_dir_error(suite, imgdump, image)
    _test_hex_size(suite, imgdump, image)

    return suite


def run_custom(imgdump: str, image: str, cluster_size: int = 32) -> TestSuite:
    """Run with custom cluster size expectations."""
    suite = TestSuite(name="Custom cluster-size validation")
    _test_json_custom(suite, imgdump, image, cluster_size)
    return suite


def run_no_demo(imgdump: str, image: str) -> TestSuite:
    """Run with no-demo (empty) image expectations."""
    suite = TestSuite(name="Empty image validation")
    _test_json_no_demo(suite, imgdump, image)
    return suite


def run_large(imgdump: str, image: str) -> TestSuite:
    """Run with 4M image expectations."""
    suite = TestSuite(name="Large image validation")
    _test_json_large(suite, imgdump, image)
    _test_text_output(suite, imgdump, image)
    return suite


def run_cli(imgdump: str) -> TestSuite:
    """Run CLI error-handling tests."""
    suite = TestSuite(name="CLI error handling")
    _test_help_text(suite, imgdump)
    _test_missing_path(suite, imgdump)
    _test_invalid_path(suite, imgdump)
    return suite


def _run(imgdump, args):
    p = subprocess.run([imgdump] + args, capture_output=True, text=True)
    return p.stdout, p.stderr, p.returncode


def _get_json(imgdump, image):
    stdout, stderr, rc = _run(imgdump, ["--json", image])
    if rc != 0:
        return None, stderr
    try:
        return json.loads(stdout), None
    except json.JSONDecodeError as e:
        return None, str(e)


def _check(suite, name, ok, detail=""):
    suite.add(TestResult(name=name, passed=ok, detail=detail))


def _test_json_validates(suite, imgdump, image):
    d, err = _get_json(imgdump, image)
    if d is None:
        return _check(suite, "json-validates", False, f"parse error: {err}")
    checks = [
        (d["master"]["rev_min"] == 5, f"rev_min={d['master']['rev_min']}"),
        (d["master"]["rev_max"] == 5, f"rev_max={d['master']['rev_max']}"),
        (d["master"]["cluster_size"] == 16, f"cluster_size={d['master']['cluster_size']}"),
        ("Kernel" in d["root"], "Kernel missing from root"),
        (d["root"]["Kernel"]["kind"] == "FILE", f"kind={d['root']['Kernel']['kind']}"),
        (d["root"]["Kernel"]["size"] == 60, f"size={d['root']['Kernel']['size']}"),
    ]
    for ok, detail in checks:
        _check(suite, "json-validates" if ok else "", ok, detail if not ok else "")
    if all(c[0] for c in checks):
        _check(suite, "json-validates", True)


def _test_json_deep(suite, imgdump, image):
    d, err = _get_json(imgdump, image)
    if d is None:
        return _check(suite, "json-deep", False, f"parse error: {err}")
    for k in ["master", "clusters", "allocated", "free", "total", "root"]:
        if k not in d:
            return _check(suite, "json-deep", False, f"missing key '{k}'")
    if len(d["clusters"]) != 128:
        return _check(suite, "json-deep", False, f"got {len(d['clusters'])} clusters")
    for ci, c in enumerate(d["clusters"]):
        for k in ["idx", "flags", "sector_index"]:
            if k not in c:
                return _check(suite, "json-deep", False, f"cluster[{ci}] missing '{k}'")
    if d["free"] + d["allocated"] != d["total"]:
        return _check(suite, "json-deep", False, f"{d['free']}+{d['allocated']}!={d['total']}")
    rk = d["root"]["Kernel"]
    for k in ["kind", "size", "cluster", "sector", "dt"]:
        if k not in rk:
            return _check(suite, "json-deep", False, f"Kernel missing '{k}'")
    _check(suite, "json-deep", True)


def _test_json_custom(suite, imgdump, image, cluster_size=32):
    d, err = _get_json(imgdump, image)
    if d is None:
        return _check(suite, "json-custom", False, f"parse error: {err}")
    ok = (d["master"]["cluster_size"] == cluster_size and
          d["master"]["cluster_map_size"] == 128 and
          d["allocated"] == 1)
    detail = "" if ok else f"cs={d['master']['cluster_size']} cms={d['master']['cluster_map_size']} a={d['allocated']}"
    _check(suite, "json-custom", ok, detail)


def _test_json_no_demo(suite, imgdump, image):
    d, err = _get_json(imgdump, image)
    if d is None:
        return _check(suite, "json-no-demo", False, f"parse error: {err}")
    ok = d["allocated"] == 1 and len(d["root"]) == 0
    detail = "" if ok else f"allocated={d['allocated']} root_entries={len(d['root'])}"
    _check(suite, "json-no-demo", ok, detail)


def _test_json_large(suite, imgdump, image):
    d, err = _get_json(imgdump, image)
    if d is None:
        return _check(suite, "json-large", False, f"parse error: {err}")
    ok = (d["master"]["cluster_size"] == 16 and
          d["free"] + d["allocated"] == d["total"] and
          len(d["clusters"]) == d["total"])
    detail = "" if ok else f"cs={d['master']['cluster_size']} free+alloc={d['free']+d['allocated']} total={d['total']}"
    _check(suite, "json-large", ok, detail)


def _test_text_output(suite, imgdump, image):
    stdout, _, rc = _run(imgdump, [image])
    if rc != 0:
        return _check(suite, "txt-output", False, f"exit {rc}")
    for keyword in ["MasterRecord", "ALLOCATED", "Directory Tree", "Kernel", "CE[00]"]:
        if keyword not in stdout:
            return _check(suite, "txt-output", False, f"missing '{keyword}'")
    _check(suite, "txt-output", True)


def _test_hex_shows_name(suite, imgdump, image):
    stdout, _, _ = _run(imgdump, ["--hex=/Kernel", image])
    _check(suite, "hex-shows-name", "Kernel" in stdout)


def _test_hex_dir_error(suite, imgdump, image):
    stdout, stderr, rc = _run(imgdump, ["--hex=/", image])
    _check(suite, "hex-dir-error", rc == 1, f"exit={rc}")
    _check(suite, "hex-dir-error-msg", "is a directory" in (stderr + stdout))


def _test_hex_size(suite, imgdump, image, expected_size=60):
    stdout, _, _ = _run(imgdump, ["--hex=/Kernel", image])
    lines = len([li for li in stdout.split("\n") if li.strip()])
    expected_lines = (expected_size + 15) // 16 + 1
    _check(suite, "hex-size", lines == expected_lines, f"got {lines} want {expected_lines}")


def _test_help_text(suite, imgdump):
    stdout, _, _ = _run(imgdump, ["--help"])
    _check(suite, "help-text", "Usage:" in stdout)


def _test_missing_path(suite, imgdump):
    _, _, rc = _run(imgdump, [])
    _check(suite, "missing-path-exit", rc == 1, f"exit={rc}")


def _test_invalid_path(suite, imgdump):
    _, _, rc = _run(imgdump, ["/nonexistent"])
    _check(suite, "invalid-path-exit", rc == 1, f"exit={rc}")
