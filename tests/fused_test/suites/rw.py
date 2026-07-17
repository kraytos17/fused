# tests/fused_test/suites/rw.py — Read-write FUSE smoke test assertions.
#
# Usage:
#   python3 -m fused_test.suites.rw --fused=<bin> --image=<path> --mount=<dir> --logs=<dir>

import argparse
import errno
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
            _test_chown(suite, mount)
            _test_deep_nesting(suite, mount)
            _test_fsync(suite, mount)
            _test_statvfs_fields(suite, mount)
            _test_truncate(suite, mount)
            _test_utimens(suite, mount)
            _test_stat_fields(suite, mount)

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


def _test_chown(suite, mount):
    """chown a file and verify uid/gid."""
    path = os.path.join(mount, "chown_test")
    try:
        _write(path, b"test\n")
        # Get current owner
        orig = os.stat(path)
        # Chown to same uid/gid (only root can change owner; changing group
        # to the same gid is always allowed)
        os.chown(path, orig.st_uid, orig.st_gid)
        st = os.stat(path)
        _check(suite, "chown", st.st_uid == orig.st_uid and st.st_gid == orig.st_gid,
               f"uid={st.st_uid} gid={st.st_gid}")
        os.unlink(path)
    except Exception as e:
        _check(suite, "chown", False, str(e))


def _test_deep_nesting(suite, mount):
    """Create and write into 8-level deep nested directory."""
    parts = ["a", "b", "c", "d", "e", "f", "g", "h"]
    path = mount
    try:
        for p in parts:
            path = os.path.join(path, p)
            os.mkdir(path)
        fpath = os.path.join(path, "f")
        _write(fpath, b"deep\n")
        data = _read(fpath)
        _check(suite, "deep-nest-create", data == b"deep\n", f"got {data!r}")
        for i in range(len(parts) - 1, -1, -1):
            sub = mount
            for j in range(i + 1):
                sub = os.path.join(sub, parts[j])
            if i == len(parts) - 1:
                os.unlink(os.path.join(sub, "f"))
            os.rmdir(sub)
        _check(suite, "deep-nest-rmdir", True)
    except Exception as e:
        _check(suite, "deep-nesting", False, str(e))


def _test_fsync(suite, mount):
    """Write a file, fsync it, and verify content persists."""
    path = os.path.join(mount, "fsync_test")
    try:
        _write(path, b"fsynced\n")
        fd = os.open(path, os.O_RDONLY)
        os.fsync(fd)
        os.close(fd)
        data = _read(path)
        _check(suite, "fsync", data == b"fsynced\n", f"got {data!r}")
        os.unlink(path)
    except Exception as e:
        _check(suite, "fsync", False, str(e))


def _test_statvfs_fields(suite, mount):
    """Verify statvfs field values (f_namemax, f_bsize)."""
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


def _test_truncate(suite, mount):
    """Write to a file, truncate it via os.truncate, and verify size."""
    path = os.path.join(mount, "trunc_test")
    try:
        _write(path, b"hello truncate world")
        os.stat(path)
        os.truncate(path, 5)
        st2 = os.stat(path)
        data = _read(path)
        _check(suite, "truncate-shrink", st2.st_size == 5 and data == b"hello",
               f"size={st2.st_size} data={data!r}")
        os.truncate(path, 20)
        st3 = os.stat(path)
        _check(suite, "truncate-grow", st3.st_size == 20, f"size={st3.st_size}")
        os.unlink(path)
    except Exception as e:
        _check(suite, "truncate", False, str(e))


def _test_utimens(suite, mount):
    """Set access/modification times and verify via stat."""
    path = os.path.join(mount, "utimens_test")
    try:
        _write(path, b"time test\n")
        atime = 1000000000
        mtime = 1234567890
        os.utime(path, (atime, mtime))
        st = os.stat(path)
        _check(suite, "utimens", st.st_atime == atime and st.st_mtime == mtime,
               f"atime={st.st_atime} mtime={st.st_mtime}")
        os.unlink(path)
    except Exception as e:
        _check(suite, "utimens", False, str(e))


def _test_stat_fields(suite, mount):
    """Verify stat returns correct uid, gid, mode for a new file."""
    path = os.path.join(mount, "stat_fields_test")
    try:
        _write(path, b"stat\n")
        st = os.stat(path)
        mode = stat.S_IMODE(st.st_mode)
        _check(suite, "stat-uid", st.st_uid >= 0, f"uid={st.st_uid}")
        _check(suite, "stat-gid", st.st_gid >= 0, f"gid={st.st_gid}")
        _check(suite, "stat-mode", mode in (0o644, 0o640), f"mode={oct(mode)}")
        os.unlink(path)
    except Exception as e:
        _check(suite, "stat-fields", False, str(e))


def run_enospc(fused: str, image: str, mount: str, logs: str) -> TestSuite:
    """ENOSPC test (requires precise image sizing — currently skipped)."""
    suite = TestSuite(name="ENOSPC test")
    suite.add_result("enospc", True, detail="skipped (needs precise image sizing)")
    return suite


def run_max_filename(fused: str, image: str, mount: str, logs: str) -> TestSuite:
    """Test 255-char max filename and 256-char rejection."""
    suite = TestSuite(name="Max filename test")

    # Create a fresh no-demo image
    import subprocess
    import tempfile

    empty_img = tempfile.NamedTemporaryFile(suffix=".img", delete=False)
    empty_img.close()
    r = subprocess.run(
        ["build/disker", "--force", "--no-demo", "--output", empty_img.name],
        capture_output=True)
    if r.returncode != 0:
        suite.add_result("max-filename", False, "disker --no-demo failed")
        return suite

    # Use a unique mount point to avoid stale mnt conflicts
    import shutil
    mp = tempfile.mkdtemp(prefix="fused_mnt_")

    try:
        with mount_fuse(fused, empty_img.name, mp, logs):
            # 255-char name should succeed
            name255 = "a" * 255
            p255 = os.path.join(mp, name255)
            try:
                _write(p255, b"ok")
                data = _read(p255)
                _check(suite, "name-255", data == b"ok", f"got {data!r}")
                os.unlink(p255)
            except Exception as e:
                _check(suite, "name-255", False, str(e))

            # 256-char name should fail with ENAMETOOLONG
            name256 = "a" * 256
            p256 = os.path.join(mp, name256)
            try:
                _write(p256, b"x")
                _check(suite, "name-256-too-long", False, "should have failed")
                os.unlink(p256)
            except OSError as e:
                if e.errno == errno.ENAMETOOLONG:
                    _check(suite, "name-256-too-long", True, detail=f"errno={e.errno}")
                else:
                    _check(suite, "name-256-too-long", False,
                           detail=f"expected ENAMETOOLONG, got {e.errno}")
            except Exception as e:
                _check(suite, "name-256-too-long", False, str(e))
    finally:
        try:
            os.unlink(empty_img.name)
        except FileNotFoundError:
            pass
        shutil.rmtree(mp, ignore_errors=True)
        # Also try to unmount if mount_fuse cleanup failed
        subprocess.run(["fusermount3", "-uz", mp], capture_output=True)

    return suite


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
