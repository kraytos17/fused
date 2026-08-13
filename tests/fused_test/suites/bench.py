# tests/fused_test/suites/bench.py — FUSE throughput benchmark.
#
# Usage:
#   python3 -m fused_test.suites.bench --fused=build/fused --image=bench.img --mount=mnt \
#       --logs=logs --size=8M
#
# Prints a table of MB/s and wall time for representative workloads.
# Reference baseline (after perf work, 4 MiB file): write-seq 35 MB/s,
# read-seq 1899 MB/s, read-4k 3416 MB/s, statfs 240k ops/s, readdir 80 ops/s.

import argparse
import os
import shutil
import subprocess
import time


def _mount(fused: str, image: str, mount: str, logs: str):
    # Recreate the mount dir fresh so a stale local copy can't fake readiness.
    shutil.rmtree(mount, ignore_errors=True)
    os.makedirs(mount, exist_ok=True)
    os.makedirs(logs, exist_ok=True)
    log_path = os.path.join(logs, "fused_bench.log")
    with open(log_path, "w") as fout:
        proc = subprocess.Popen(
            [fused, "--log-level=warn", image, "-f", mount],
            stdout=fout, stderr=subprocess.STDOUT,
        )
    # Wait for the mount to actually appear (FUSE is live only when ismount is true).
    for _ in range(100):
        time.sleep(0.1)
        if proc.poll() is not None:
            raise RuntimeError(f"daemon exited early (see {log_path})")
        if os.path.ismount(mount):
            return proc
    proc.kill()
    raise RuntimeError(f"mount did not appear (see {log_path})")


def _unmount(proc: subprocess.Popen, mount: str):
    # Lazy unmount first so the daemon's event loop can exit cleanly.
    subprocess.run(["fusermount3", "-uz", mount], capture_output=True, check=False)
    proc.terminate()
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


def _bench(name: str, fn, mb: int) -> dict:
    start = time.monotonic()
    ops = fn()
    wall = time.monotonic() - start
    return {"name": name, "mb_s": mb / wall if wall > 0 else 0.0,
            "ops_s": ops / wall if wall > 0 else 0.0, "wall": wall}


def run(fused: str, image: str, mount: str, logs: str, size_mb: int = 8) -> list[dict]:
    size = size_mb * 1024 * 1024
    chunk = 64 * 1024
    path = os.path.join(mount, "bench.bin")
    results = []

    proc = _mount(fused, image, mount, logs)
    try:
        def write_seq():
            n = 0
            with open(path, "wb") as fh:
                for off in range(0, size, chunk):
                    fh.write(b"x" * chunk)
                    n += 1
            return n

        def read_seq():
            n = 0
            with open(path, "rb") as fh:
                while True:
                    b = fh.read(chunk)
                    if not b:
                        break
                    n += 1
            return n

        def read_4k():
            n = 0
            with open(path, "rb") as fh:
                while True:
                    b = fh.read(4096)
                    if not b:
                        break
                    n += 1
            return n

        def statfs():
            n = 0
            for _ in range(100):
                os.statvfs(mount)
                n += 1
            return n

        def readdir():
            d = os.path.join(mount, "benchdir")
            os.makedirs(d, exist_ok=True)
            for i in range(200):
                with open(os.path.join(d, f"f{i:03d}"), "w") as fh:
                    fh.write("x")
            n = 0
            for _ in range(50):
                os.listdir(d)
                n += 1
            return n

        results.append(_bench("write-sequential", write_seq, size_mb))
        results.append(_bench("read-sequential", read_seq, size_mb))
        results.append(_bench("read-4k", read_4k, size_mb))
        results.append(_bench("statfs", statfs, 0))
        results.append(_bench("readdir", readdir, 0))
    finally:
        _unmount(proc, mount)

    return results


def main() -> None:
    parser = argparse.ArgumentParser(description="fused throughput benchmark")
    parser.add_argument("--fused", default="build/fused")
    parser.add_argument("--image", default="bench.img")
    parser.add_argument("--mount", default="mnt")
    parser.add_argument("--logs", default="logs")
    parser.add_argument("--size", type=int, default=8, help="file size in MiB")
    args = parser.parse_args()

    results = run(args.fused, args.image, args.mount, args.logs, args.size)
    print(f"{'scenario':<18}{'MB/s':>10}{'ops/s':>10}{'wall':>10}")
    for r in results:
        print(f"{r['name']:<18}{r['mb_s']:>10.1f}{r['ops_s']:>10.1f}{r['wall']:>10.3f}s")


if __name__ == "__main__":
    main()
