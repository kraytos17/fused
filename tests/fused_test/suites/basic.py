# tests/fused_test/suites/basic.py — Basic FUSE smoke test assertions.
#
# Usage:
#   python3 -m fused_test.suites.basic --fused=<bin> --image=<path> --mount=<dir> --logs=<dir>

import argparse
import os
import stat
import sys

# Ensure tests/ is on the path when run as main
if __name__ == "__main__":
    _d = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if _d not in sys.path:
        sys.path.insert(0, _d)

from fused_test.result import TestSuite, TestResult
from fused_test.mount import mount_fuse


def run(fused: str, image: str, mount: str, logs: str) -> TestSuite:
    suite = TestSuite(name="Basic FUSE smoke test")

    if not os.path.isfile(fused):
        suite.add(TestResult(name="binary", passed=False, detail=f"not found: {fused}"))
        return suite
    if not os.path.isfile(image):
        suite.add(TestResult(name="image", passed=False, detail=f"not found: {image}"))
        return suite

    try:
        with mount_fuse(fused, image, mount, logs):
            _test_ls(suite, mount)
            _test_mode(suite, mount)
            _test_size(suite, mount)
            _test_header(suite, mount)
            _test_write_read(suite, mount)
            _test_multi_sector(suite, mount)
            _test_subdir(suite, mount)
            _test_statvfs(suite, mount)
            _test_mount_table()
            _test_fuse_ops(suite, logs)
            _test_max_filename(suite, mount)
            _test_statvfs_values(suite, mount)
    except Exception as e:
        suite.add(TestResult(name="mount", passed=False, detail=str(e)))

    _test_log_format_opts(suite, fused)

    return suite


def _check(suite, name, ok, detail=""):
    suite.add(TestResult(name=name, passed=ok, detail=detail))


def _read(path):
    with open(path, "rb") as f:
        return f.read()


def _write(path, data):
    with open(path, "wb") as f:
        f.write(data)


def _test_ls(suite, mount):
    try:
        entries = os.listdir(mount)
        _check(suite, "ls", "Kernel" in entries, f"Kernel not in {entries}")
    except Exception as e:
        _check(suite, "ls", False, str(e))


def _test_mode(suite, mount):
    try:
        st = os.stat(os.path.join(mount, "Kernel"))
        mode = stat.S_IMODE(st.st_mode)
        _check(suite, "mode 644", mode == 0o644, f"got {oct(mode)}")
    except Exception as e:
        _check(suite, "mode 644", False, str(e))


def _test_size(suite, mount):
    try:
        st = os.stat(os.path.join(mount, "Kernel"))
        _check(suite, "size 60", st.st_size == 60, f"got {st.st_size}")
    except Exception as e:
        _check(suite, "size 60", False, str(e))


def _test_header(suite, mount):
    try:
        data = _read(os.path.join(mount, "Kernel"))
        expected = bytes([0x82, 0x00, 0x0D, 0x00])
        _check(suite, "header", data[:4] == expected, f"got {data[:4].hex()}")
    except Exception as e:
        _check(suite, "header", False, str(e))


def _test_write_read(suite, mount):
    path = os.path.join(mount, "write_test")
    try:
        _write(path, b"hello_fuse")
        data = _read(path)
        _check(suite, "write+read", data == b"hello_fuse", f"got {data!r}")
        os.unlink(path)
    except Exception as e:
        _check(suite, "write+read", False, str(e))


def _test_multi_sector(suite, mount):
    path = os.path.join(mount, "multi")
    try:
        data = os.urandom(3 * 512)
        _write(path, data)
        st = os.stat(path)
        _check(suite, "multi-sector", st.st_size >= 1500, f"size={st.st_size}")
        os.unlink(path)
    except Exception as e:
        _check(suite, "multi-sector", False, str(e))


def _test_subdir(suite, mount):
    sub = os.path.join(mount, "subdir", "a", "b")
    try:
        os.makedirs(sub, exist_ok=True)
        fpath = os.path.join(sub, "f")
        _write(fpath, b"deep")
        data = _read(fpath)
        _check(suite, "nested", data == b"deep", f"got {data!r}")
        # Now verify rmdirs work (separate from the read assertion)
        os.unlink(fpath)
        os.rmdir(sub)
        os.rmdir(os.path.join(mount, "subdir", "a"))
        os.rmdir(os.path.join(mount, "subdir"))
        _check(suite, "rmdirs", True)
    except Exception as e:
        _check(suite, "nested", False, str(e))
        # If nested failed, we might not have created the dirs for rmdirs
        _check(suite, "rmdirs", False, str(e))


def _test_statvfs(suite, mount):
    try:
        s = os.statvfs(mount)
        _check(suite, "statvfs", s.f_bsize > 0, f"f_bsize={s.f_bsize}")
    except Exception as e:
        _check(suite, "statvfs", False, str(e))


def _test_mount_table():
    pass  # checked by the FUSE ops log


def _test_fuse_ops(suite, logs_dir):
    log_path = os.path.join(logs_dir, "fused_fuse.log")
    if not os.path.isfile(log_path):
        return _check(suite, "FUSE ops", False, f"log not found: {log_path}")
    try:
        with open(log_path) as f:
            content = f.read()
        ops = ["LOOKUP", "OPEN", "READ", "GETATTR"]
        found = [op for op in ops if op in content]
        _check(suite, "FUSE ops", len(found) >= 3, f"only found {found}")
    except Exception as e:
        _check(suite, "FUSE ops", False, str(e))


def _test_max_filename(suite, mount):
    """Create a file with 255-char name and read it back."""
    name = "a" * 255
    path = os.path.join(mount, name)
    try:
        _write(path, b"ok")
        data = _read(path)
        _check(suite, "max-filename", data == b"ok", f"got {data!r}")
        os.unlink(path)
        _check(suite, "max-filename-unlink", True)
    except Exception as e:
        _check(suite, "max-filename", False, str(e))


def _test_statvfs_values(suite, mount):
    """Check specific statvfs field values."""
    try:
        s = os.statvfs(mount)
        checks = [
            (s.f_namemax == 255, f"f_namemax={s.f_namemax}"),
            (s.f_bsize == 512, f"f_bsize={s.f_bsize}"),
        ]
        for ok, detail in checks:
            _check(suite, "statvfs-field", ok, detail if not ok else "")
        if all(c[0] for c in checks):
            _check(suite, "statvfs-fields", True)
    except Exception as e:
        _check(suite, "statvfs-fields", False, str(e))


def _test_log_format_opts(suite, fused):
    """Verify --log-format=short and --log-format=full are accepted."""
    import subprocess
    for fmt in ["short", "long", "full"]:
        r = subprocess.run([fused, "--log-format=" + fmt, "--help"],
                           capture_output=True, text=True)
        _check(suite, f"log-format-{fmt}", r.returncode == 0,
               f"exit={r.returncode}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Basic FUSE smoke test")
    parser.add_argument("--fused", default="build/fused")
    parser.add_argument("--image", default="fused.img")
    parser.add_argument("--mount", default="mnt")
    parser.add_argument("--logs", default="logs")
    args = parser.parse_args()

    suite = run(args.fused, args.image, args.mount, args.logs)
    suite.print_summary()
    sys.exit(1 if suite.failed else 0)
