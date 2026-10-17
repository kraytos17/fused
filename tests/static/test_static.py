# tests/test_static.py — Static analysis as pytest (marker: static).
#
# Same three suites as ci.py's static phase (struct sizes, audit, vet),
# runnable via `pytest -m static`. Slow (odin builds); excluded from the
# fast loop by selecting -m "tool or fuse".
import subprocess

import pytest


def _make(target: str) -> subprocess.CompletedProcess:
    return subprocess.run(["make", target], capture_output=True, text=True, check=False, timeout=300)


@pytest.mark.static
def test_struct_sizes():
    r = _make("check")
    assert r.returncode == 0, f"make check failed:\n{r.stdout}\n{r.stderr}"


@pytest.mark.static
def test_audit_strict():
    r = subprocess.run(["make", "audit", "AUDIT_FLAGS=--strict"], capture_output=True, text=True, check=False, timeout=300)
    assert r.returncode == 0, f"make audit failed:\n{r.stdout}\n{r.stderr}"


@pytest.mark.static
def test_vet():
    r = _make("vet")
    assert r.returncode == 0, f"make vet failed:\n{r.stdout}\n{r.stderr}"
