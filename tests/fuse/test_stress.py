# tests/test_stress.py — Multi-threaded stress as pytest (marker: fuse).
#
# Short (5s) variant of the smoke-mt gate (15s, shared image) on a
# private image. Exercises concurrent readers/writers through the
# kernel; transient worker errors are tolerated, dead workers fail.
import pytest

from fused_test.suites.stress import run


@pytest.mark.fuse
def test_stress_short(fused_bin: str, clean_image: str, tmp_path):
    res = run(fused_bin, clean_image, str(tmp_path / "mnt"), str(tmp_path / "logs"), duration=5)
    assert res.failed == 0, f"stress failed: {res.results}"
    assert res.passed >= 3, f"stress incomplete: {res.results}"
