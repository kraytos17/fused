# tests/fuse/test_trace.py — JSONL op tracing (mount --trace).
import errno
import json
import os

import pytest

from fused_test.io import assert_cli_ok, run_cli
from fused_test.mount import mount_fuse


def _read_trace(path: str) -> list:
    with open(path) as f:
        lines = [ln for ln in f.read().splitlines() if ln.strip()]
    events = [json.loads(ln) for ln in lines]
    for e in events:
        assert set(e) >= {"op", "path", "rc", "err", "dur_us"}, e
        assert isinstance(e["dur_us"], int) and e["dur_us"] >= 0, e
    return events


@pytest.mark.fuse
def test_trace_all_records_ops(fused_bin: str, clean_image: str, tmp_path):
    """--trace=all emits one JSONL event per op with result codes."""
    trace = str(tmp_path / "all.jsonl")
    mp = str(tmp_path / "mnt")
    with mount_fuse(
        fused_bin, clean_image, mp, str(tmp_path / "logs"),
        opts=["--trace=all", f"--trace-out={trace}"],
    ):
        with open(os.path.join(mp, "t.txt"), "w") as fh:
            fh.write("hello trace\n")
        with open(os.path.join(mp, "t.txt")) as fh:
            assert fh.read() == "hello trace\n"
        st = os.stat(os.path.join(mp, "t.txt"))
        assert st.st_size == len("hello trace\n")

    events = _read_trace(trace)
    by_op = [e["op"] for e in events]
    # init always first; the file lifecycle must appear in order.
    assert by_op[0] == "init"
    assert "create" in by_op and "getattr" in by_op
    assert "write" in by_op or "write_buf" in by_op
    create = next(e for e in events if e["op"] == "create")
    assert create["path"] == "/t.txt" and create["rc"] == 0 and not create["err"]
    # Every error flag agrees with its return code.
    for e in events:
        assert e["err"] == (e["rc"] < 0), e


@pytest.mark.fuse
def test_trace_errors_only(fused_bin: str, clean_image: str, tmp_path):
    """--trace=errors records only failing ops."""
    trace = str(tmp_path / "err.jsonl")
    mp = str(tmp_path / "mnt")
    with mount_fuse(
        fused_bin, clean_image, mp, str(tmp_path / "logs"),
        opts=["--trace=errors", f"--trace-out={trace}"],
    ):
        with open(os.path.join(mp, "ok.txt"), "w") as fh:
            fh.write("x")
        try:
            os.stat(os.path.join(mp, "missing.txt"))
            raise AssertionError("stat should have raised")
        except FileNotFoundError:
            pass

    events = _read_trace(trace)
    assert len(events) >= 1, "expected at least the ENOENT"
    assert all(e["err"] for e in events), events
    assert any(e["op"] == "getattr" and e["rc"] == -errno.ENOENT for e in events)


@pytest.mark.fuse
def test_trace_requires_out(fused_bin: str, clean_image: str, tmp_path):
    """--trace without --trace-out fails fast instead of mounting."""
    import errno

    r = run_cli(
        fused_bin, clean_image, str(tmp_path / "mnt"),
        "--trace=all", timeout=15,
    )
    assert r.returncode != 0
    assert "trace-out" in r.stderr
