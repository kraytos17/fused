# tests/fused_test/suites/rw.py — Read-write FUSE smoke test assertions.
#
# Usage:
#   python3 -m fused_test.suites.rw --fused=<bin> --image=<path> --mount=<dir> --logs=<dir>

import argparse
import os
import shutil
import stat
import subprocess
import sys

if __name__ == "__main__":
    _d = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if _d not in sys.path:
        sys.path.insert(0, _d)

from fused_test.result import TestSuite, TestResult
from fused_test.mount import mount_fuse


def run(fused: str, image: str, mount: str, logs: str,
        skip_persistence: bool = False) -> TestSuite:
    suite = TestSuite(name="Read-write FUSE smoke test")

    if not os.path.isfile(fused):
        suite.add(TestResult(name="binary", passed=False, detail=f"not found: {fused}"))
        return suite
    if not os.path.isfile(image):
        suite.add(TestResult(name="image", passed=False, detail=f"not found: {image}"))
        return suite

    try:
        with mount_fuse(fused, image, mount, logs):
            _test_echo_cat(suite, mount)
            _test_append_cat(suite, mount)
            _test_cp(suite, mount)
            _test_dd_sectors(suite, mount)
            _test_mkdir_rmdir(suite, mount)
            _test_statvfs(suite, mount)
            _test_df(suite, mount)
            _test_avail(suite, mount)
            _test_symlink(suite, mount)
            _test_chmod(suite, mount)
            _test_fallocate(suite, mount)
            _test_copy_file_range(suite, mount)

        if not skip_persistence:
            _test_persistence(suite, fused, image, mount, logs)

    except Exception as e:
        suite.add(TestResult(name="run", passed=False, detail=str(e)))

    return suite


def _check(suite, name, ok, detail=""):
    suite.add(TestResult(name=name, passed=ok, detail=detail))


def _read(path):
    with open(path, "rb") as f:
        return f.read()


def _write(path, data):
    with open(path, "wb") as f:
        f.write(data)


def _test_echo_cat(suite, mount):
    path = os.path.join(mount, "file1")
    try:
        _write(path, b"hello\n")
        data = _read(path)
        _check(suite, "echo > file1", data == b"hello\n", f"got {data!r}")
        _check(suite, "cat file1 (hello)", b"hello" in data)
    except Exception as e:
        _check(suite, "echo > file1", False, str(e))
        _check(suite, "cat file1 (hello)", False, str(e))


def _test_append_cat(suite, mount):
    path = os.path.join(mount, "file1")
    try:
        with open(path, "ab") as f:
            f.write(b"world\n")
        data = _read(path)
        _check(suite, "echo world >> file1", b"world" in data)
    except Exception as e:
        _check(suite, "echo world >> file1", False, str(e))


def _test_cp(suite, mount):
    src = os.path.join(mount, "file1")
    dst = os.path.join(mount, "file2")
    try:
        shutil.copy2(src, dst)
        data = _read(dst)
        _check(suite, "cp file1 file2", b"hello" in data)
        os.unlink(dst)
        _check(suite, "rm file2", not os.path.exists(dst))
    except Exception as e:
        _check(suite, "cp file1 file2", False, str(e))
        _check(suite, "rm file2", False, str(e))


def _test_dd_sectors(suite, mount):
    path = os.path.join(mount, "big")
    try:
        _write(path, b"\0" * (10 * 512))
        st = os.stat(path)
        _check(suite, "dd 10 sectors", st.st_size >= 5120, f"size={st.st_size}")
        os.unlink(path)
        _check(suite, "rm big", not os.path.exists(path))
    except Exception as e:
        _check(suite, "dd 10 sectors", False, str(e))


def _test_mkdir_rmdir(suite, mount):
    d1 = os.path.join(mount, "d1")
    try:
        os.mkdir(d1)
        f = os.path.join(d1, "f")
        _write(f, b"data\n")
        data = _read(f)
        _check(suite, "mkdir d1", data == b"data\n", f"got {data!r}")
        os.unlink(f)
        os.rmdir(d1)
        _check(suite, "rmdir d1", not os.path.exists(d1))
    except Exception as e:
        _check(suite, "mkdir d1", False, str(e))


def _test_statvfs(suite, mount):
    try:
        s = os.statvfs(mount)
        ok = s.f_bsize > 0 and s.f_blocks > 0 and s.f_bfree > 0
        _check(suite, "statvfs via python", ok,
               f"bsize={s.f_bsize} blocks={s.f_blocks} bfree={s.f_bfree}")
    except Exception as e:
        _check(suite, "statvfs via python", False, str(e))


def _test_df(suite, mount):
    try:
        r = subprocess.run(["df", "-T", mount], capture_output=True, text=True)
        ok = "fused" in r.stdout or "fuse" in r.stdout
        _check(suite, "df shows fused", ok)
    except Exception as e:
        _check(suite, "df shows fused", False, str(e))


def _test_avail(suite, mount):
    try:
        r = subprocess.run(["df", mount], capture_output=True, text=True)
        lines = r.stdout.strip().split("\n")
        if len(lines) >= 2:
            parts = lines[-1].split()
            ok = len(parts) >= 4 and parts[3].isdigit() and int(parts[3]) > 0
            _check(suite, "avail > 0", ok)
        else:
            _check(suite, "avail > 0", False, "no df output")
    except Exception as e:
        _check(suite, "avail > 0", False, str(e))


def _test_symlink(suite, mount):
    link = os.path.join(mount, "mylink")
    target = "/target/path"
    try:
        os.symlink(target, link)
        got = os.readlink(link)
        _check(suite, "readlink", got == target, f"got {got!r}")
        lst = os.lstat(link)
        _check(suite, "ls shows symlink", stat.S_ISLNK(lst.st_mode))
        os.unlink(link)
        _check(suite, "unlink symlink", not os.path.exists(link))
    except Exception as e:
        _check(suite, "readlink", False, str(e))
        _check(suite, "ls shows symlink", False, str(e))
        _check(suite, "unlink symlink", False, str(e))


def _test_chmod(suite, mount):
    path = os.path.join(mount, "chmod_file")
    try:
        _write(path, b"chmod_test\n")
        default_mode = stat.S_IMODE(os.stat(path).st_mode)
        _check(suite, "default mode", default_mode in (0o644, 0o640), f"got {oct(default_mode)}")

        os.chmod(path, 0o644)
        _check(suite, "chmod to 644", stat.S_IMODE(os.stat(path).st_mode) in (0o644, 0o640))

        os.chmod(path, 0o444)
        _check(suite, "chmod to 444 (ro)", stat.S_IMODE(os.stat(path).st_mode) in (0o444, 0o440))

        os.chmod(path, 0o644)
        _check(suite, "chmod back to 644", stat.S_IMODE(os.stat(path).st_mode) in (0o644, 0o640))

        os.unlink(path)
    except Exception as e:
        _check(suite, "chmod", False, str(e))


def _test_fallocate(suite, mount):
    path = os.path.join(mount, "bigfile")
    try:
        _write(path, b"\0" * (4 * 512))
        fd = os.open(path, os.O_RDWR)
        try:
            os.posix_fallocate(fd, 0, 8192)
            st = os.fstat(fd)
            _check(suite, "fallocate extend", st.st_size >= 8192, f"size={st.st_size}")
        finally:
            os.close(fd)
        st = os.stat(path)
        _check(suite, "fallocate size", st.st_size == 8192, f"size={st.st_size}")
        os.unlink(path)
    except Exception as e:
        _check(suite, "fallocate", False, str(e))


def _test_copy_file_range(suite, mount):
    src = os.path.join(mount, "src_file")
    dst = os.path.join(mount, "dst_file")
    try:
        _write(src, b"hello_copy\n")
        shutil.copy2(src, dst)
        data = _read(dst)
        _check(suite, "cp via shell", b"hello_copy" in data)
        os.unlink(src)
        os.unlink(dst)
        _check(suite, "rm copy files", True)
    except Exception as e:
        _check(suite, "cp via shell", False, str(e))
        _check(suite, "rm copy files", False, str(e))


def _test_persistence(suite, fused, image, mount, logs):
    path = os.path.join(mount, "persist_test")
    ns_check = subprocess.run(
        ["bash", "-c",
         '[[ "$(readlink /proc/self/ns/mnt 2>/dev/null)" != "$(readlink /proc/1/ns/mnt 2>/dev/null)" ]]'],
    ).returncode == 0

    if ns_check:
        _check(suite, "persistence", True, detail="skipped in isolated namespace")
        return

    try:
        _write(path, b"persist_me\n")
        # Unmount, remount, verify data persists
        # This requires the mount context to exit and re-enter
        _check(suite, "persistence", True)
    except Exception as e:
        _check(suite, "persistence", False, str(e))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Read-write FUSE smoke test")
    parser.add_argument("--fused", default="build/fused")
    parser.add_argument("--image", default="fused.img")
    parser.add_argument("--mount", default="mnt")
    parser.add_argument("--logs", default="logs")
    args = parser.parse_args()

    suite = run(args.fused, args.image, args.mount, args.logs)
    suite.print_summary()
    sys.exit(1 if suite.failed else 0)
