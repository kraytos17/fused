# tests/fused_test/suites/disker.py — Integration tests for disker and imgdump.
#
# Usage:
#   python3 -m fused_test.suites.disker --disker=<bin> --imgdump=<bin> [--workdir=<dir>]

import argparse
import os
import subprocess
import sys
import tempfile

if __name__ == "__main__":
    _d = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if _d not in sys.path:
        sys.path.insert(0, _d)

from fused_test.result import TestSuite, TestResult
from fused_test.suites import imgdump as imgdump_suite


def run(disker: str, imgdump: str, workdir: str | None = None) -> TestSuite:
    suite = TestSuite(name="Disker + Imgdump integration")

    if not os.path.isfile(disker):
        suite.add(TestResult(name="disker-binary", passed=False, detail=f"not found: {disker}"))
        return suite
    if not os.path.isfile(imgdump):
        suite.add(TestResult(name="imgdump-binary", passed=False, detail=f"not found: {imgdump}"))
        return suite

    tmpdir = workdir or tempfile.mkdtemp(prefix="fused_disktest_")
    cleanup = not workdir

    try:
        _test_disker_basic(suite, disker, tmpdir)
        _test_imgdump_standard(suite, imgdump, disker, tmpdir)
        _test_cross_tool(suite, imgdump, disker, tmpdir)
    finally:
        if cleanup:
            import shutil
            shutil.rmtree(tmpdir, ignore_errors=True)

    return suite


def _check(suite, name, ok, detail=""):
    suite.add(TestResult(name=name, passed=ok, detail=detail))


def _run_disker(disker, args):
    return subprocess.run([disker] + args, capture_output=True, text=True)


def _test_disker_basic(suite, disker, tmpdir):
    """Pure disker CLI tests: formatting, help, error handling."""
    def i(n):
        return os.path.join(tmpdir, f"{n:02d}.img")

    # Default format
    r = _run_disker(disker, ["--force", "--output", i(1)])
    sz = os.path.getsize(i(1)) if r.returncode == 0 else 0
    _check(suite, "default-format", r.returncode == 0 and sz == 1048576, f"size={sz}")

    # Custom size
    r = _run_disker(disker, ["--force", "--output", i(2), "--size=4M"])
    sz = os.path.getsize(i(2)) if r.returncode == 0 else 0
    _check(suite, "custom-size-4M", sz == 4 * 1024 * 1024, f"size={sz}")

    # Custom cluster
    r = _run_disker(disker, ["--force", "--output", i(3), "--size=8M", "--cluster-size=64"])
    sz = os.path.getsize(i(3)) if r.returncode == 0 else 0
    _check(suite, "custom-cluster-64", sz == 8 * 1024 * 1024, f"size={sz}")

    # Positional output
    r = _run_disker(disker, ["--force", i(4)])
    _check(suite, "positional-output", r.returncode == 0 and os.path.isfile(i(4)))

    # Help
    r = _run_disker(disker, ["--help"])
    _check(suite, "help", "disker" in r.stdout)

    # Force guard
    r = _run_disker(disker, ["--force", "--output", i(1)])
    r2 = _run_disker(disker, ["--output", i(1)])
    _check(suite, "force-guard", r2.returncode == 1, f"exit={r2.returncode}")

    # Size validation
    r = _run_disker(disker, ["--force", "--output", i(7), "--size=1K"])
    _check(suite, "size-validation", r.returncode == 1, f"exit={r.returncode}")


def _test_imgdump_standard(suite, imgdump, disker, tmpdir):
    """Standard imgdump JSON/text/hex tests on default 1M image."""
    image = os.path.join(tmpdir, "09.img")
    r = _run_disker(disker, ["--force", "--output", image])
    if r.returncode != 0:
        return _check(suite, "imgdump-standard", False, "disker failed")

    sub = imgdump_suite.run(imgdump, image)
    for result in sub.results:
        suite.results.append(result)


def _test_cross_tool(suite, imgdump, disker, tmpdir):
    """Cross-tool validation with various image configurations."""
    # Custom cluster size
    image = os.path.join(tmpdir, "18.img")
    r = _run_disker(disker, ["--force", "--output", image, "--size=2M", "--cluster-size=32"])
    if r.returncode == 0:
        sub = imgdump_suite.run_custom(imgdump, image, cluster_size=32)
        for result in sub.results:
            suite.results.append(result)

    # No-demo image
    image = os.path.join(tmpdir, "19.img")
    r = _run_disker(disker, ["--force", "--output", image, "--no-demo"])
    if r.returncode == 0:
        sub = imgdump_suite.run_no_demo(imgdump, image)
        for result in sub.results:
            suite.results.append(result)

    # Large image
    image = os.path.join(tmpdir, "20.img")
    r = _run_disker(disker, ["--force", "--output", image, "--size=4M"])
    if r.returncode == 0:
        sub = imgdump_suite.run_large(imgdump, image)
        for result in sub.results:
            suite.results.append(result)

    # CLI error handling
    sub = imgdump_suite.run_cli(imgdump)
    for result in sub.results:
        suite.results.append(result)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Disker + Imgdump integration tests")
    parser.add_argument("--disker", default="build/disker")
    parser.add_argument("--imgdump", default="build/imgdump")
    parser.add_argument("--workdir", default=None)
    args = parser.parse_args()

    suite = run(args.disker, args.imgdump, args.workdir)
    suite.print_summary()
    sys.exit(1 if suite.failed else 0)
