# tests/fused_test/suites/stress.py — Multi-threaded FUSE stress test.
#
# Usage:
#   python3 -m fused_test.suites.stress --fused=<bin> --image=<path> --mount=<dir> --logs=<dir>

import argparse
import concurrent.futures
import os
import subprocess
import sys
import time
from dataclasses import dataclass, field


@dataclass
class WorkerResult:
    ops: int
    errors: int


@dataclass
class StressResult:
    """Tiny summary of stress-test phases."""

    results: list = field(default_factory=list)

    @property
    def passed(self) -> int:
        return sum(1 for _, ok, _ in self.results if ok)

    @property
    def failed(self) -> int:
        return len(self.results) - self.passed

    def add(self, name: str, ok: bool, detail: str = "") -> None:
        self.results.append((name, ok, detail))

    def print_summary(self) -> None:
        for name, ok, detail in self.results:
            status = "PASS" if ok else "FAIL"
            suffix = f": {detail}" if detail else ""
            print(f"{status}   {name}{suffix}")
        print(f"=== Multi-threaded stress test: {self.passed} passed, {self.failed} failed ===")


def run(fused: str, image: str, mount: str, logs: str,
        duration: int = 15) -> StressResult:
    mount_abs = os.path.abspath(mount)
    logs_abs = os.path.abspath(logs)
    suite = StressResult()

    if not os.path.isfile(fused):
        suite.add("binary", False, detail=f"not found: {fused}")
        return suite
    if not os.path.isfile(image):
        suite.add("image", False, detail=f"not found: {image}")
        return suite

    os.makedirs(mount_abs, exist_ok=True)
    os.makedirs(logs_abs, exist_ok=True)
    log_path = os.path.join(logs_abs, "fused_mt.log")
    daemon = subprocess.Popen(
        [fused, f"--log-file={log_path}", "--log-level=warn", image, "-f", mount_abs],
    )

    # Wait for mount
    mounted = False
    for i in range(5):
        time.sleep(1)
        if daemon.poll() is not None:
            suite.add("mount", False, detail=f"daemon died after {i+1}s")
            return suite
        try:
            if os.listdir(mount_abs):
                mounted = True
                break
        except OSError:
            pass

    if not mounted:
        suite.add("mount", False, detail="mount did not appear")
        daemon.kill()
        return suite

    suite.add("mount", True)

    # Run workers concurrently
    workers = [
        ("reader", _reader_worker, [mount_abs, duration]),
        ("writer", _writer_worker, [mount_abs, duration]),
    ]

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        futures = {executor.submit(fn, *args): name
                   for name, fn, args in workers}
        for future in concurrent.futures.as_completed(futures):
            name = futures[future]
            try:
                r = future.result()
                if r.ops == 0 and r.errors > 0:
                    suite.add(name, False,
                              detail=f"0 ops, {r.errors} errors (daemon unresponsive)")
                else:
                    detail = f"{r.ops} ops"
                    if r.errors:
                        detail += f", {r.errors} transient errors"
                    suite.add(name, True, detail=detail)
            except Exception as e:
                suite.add(name, False, detail=str(e))

    # Cleanup
    subprocess.run(["fusermount3", "-uz", mount_abs],
                   capture_output=True, timeout=5, check=False)
    daemon.terminate()
    try:
        daemon.wait(timeout=3)
    except subprocess.TimeoutExpired:
        daemon.kill()
        daemon.wait()

    return suite


def _reader_worker(mount: str, duration: int) -> WorkerResult:
    end = time.monotonic() + duration
    ops = 0
    errors = 0
    while time.monotonic() < end:
        for retry in range(3):
            try:
                os.listdir(mount)
                ops += 1
                break
            except Exception:
                if retry == 2:
                    errors += 1
                time.sleep(0.01)
        time.sleep(0.2)
    return WorkerResult(ops=ops, errors=errors)


def _writer_worker(mount: str, duration: int) -> WorkerResult:
    end = time.monotonic() + duration
    ops = 0
    errors = 0
    i = 0
    while time.monotonic() < end:
        try:
            fname = f"wfile_{i}"
            fpath = os.path.join(mount, fname)
            with open(fpath, "w") as f:
                f.write(f"content_{i}\n")
            with open(fpath) as f:
                _ = f.read()
            os.unlink(fpath)
            ops += 1
            i = (i + 1) % 100
        except Exception:
            errors += 1
        time.sleep(0.05)
    return WorkerResult(ops=ops, errors=errors)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Multi-threaded FUSE stress test")
    parser.add_argument("--fused", default="build/fused")
    parser.add_argument("--image", default="fused.img")
    parser.add_argument("--mount", default="mnt")
    parser.add_argument("--logs", default="logs")
    parser.add_argument("--duration", type=int, default=15)
    args = parser.parse_args()

    suite = run(args.fused, args.image, args.mount, args.logs, args.duration)
    suite.print_summary()
    sys.exit(1 if suite.failed else 0)
