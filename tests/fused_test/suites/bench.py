# tests/fused_test/suites/bench.py — FUSE throughput benchmark.
#
# Usage:
#   python3 -m fused_test.suites.bench --fused=build/fused --image=bench.img --mount=mnt \
#       --logs=logs --size=4 [--repeats=5] [--files=200] [--json-out=bench.json]
#
# Methodology (deliberately boring, so numbers compare across runs):
# - Every scenario splits untimed setup() from timed measure(). Setup cost
#   (file creation, cache priming) never leaks into the reported rate.
# - Each scenario runs once untimed as warmup (cold caches, first faults),
#   then --repeats timed repetitions. The reported rate is the median;
#   best/worst show the spread. The warmup sample is reported separately
#   as `cold` so cache effects read as data, not noise.
# - Scenarios run in fixed order (documented below); each is fault
#   isolated — one scenario failing records its error and the rest still
#   run, so a crash never eats the whole table.
# - --json-out persists machine-readable results plus provenance (git rev,
#   args, cpu count, load) for before/after diffing.

import argparse
import json
import os
import shutil
import statistics
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
            stdout=fout,
            stderr=subprocess.STDOUT,
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


def _summarize(name: str, unit: str, unit_per_op: float, pairs: list) -> dict:
    # pairs: (ops, wall) per repetition; first entry is the warmup run
    # (cold caches, first faults). Rates follow as
    # unit_per_op * ops / wall; the reported rate is the median.
    (cold_ops, cold_wall), *timed = pairs
    rates = [unit_per_op * ops / w if w > 0 else 0.0 for ops, w in timed]
    cold_rate = unit_per_op * cold_ops / cold_wall if cold_wall > 0 else 0.0
    return {
        "name": name,
        "unit": unit,
        "repeats": len(timed),
        "cold": round(cold_rate, 1),
        "median": round(statistics.median(rates), 1),
        "best": round(max(rates), 1),
        "worst": round(min(rates), 1),
        "wall_total": round(sum(w for _, w in timed), 3),
    }


def _run_scenario(
    name: str, unit: str, unit_per_op: float, setup, measure, repeats: int
) -> dict:
    # setup() runs untimed (may raise -> scenario errors, never timed).
    # measure() runs once warmup (reported as cold) then `repeats` timed.
    setup()
    pairs = []
    for _ in range(1 + repeats):
        t0 = time.perf_counter()
        ops = measure()
        pairs.append((ops, time.perf_counter() - t0))
        assert ops > 0, f"{name}: measure() returned no ops"
    return _summarize(name, unit, unit_per_op, pairs)


def run(
    fused: str,
    image: str,
    mount: str,
    logs: str,
    size_mb: int = 8,
    repeats: int = 5,
    files: int = 200,
) -> list[dict]:
    size = size_mb * 1024 * 1024
    chunk = 64 * 1024
    path = os.path.join(mount, "bench.bin")
    results: list[dict] = []
    errors: list[str] = []

    # Fixed order, documented: each scenario's leftovers warm the next
    # one's caches (steady state), except where noted.
    scenarios = []

    def add(name, unit, unit_per_op, setup, measure):
        scenarios.append((name, unit, unit_per_op, setup, measure))

    def noop():
        return None

    # write-sequential: create + stream the whole file (cold image).
    def write_setup():
        if os.path.exists(path):
            os.unlink(path)

    def write_measure():
        n = 0
        with open(path, "wb") as fh:
            for off in range(0, size, chunk):
                fh.write(b"x" * chunk)
                n += 1
        return n

    mb_per_write = chunk / (1024 * 1024)
    add("write-sequential", "MB/s", mb_per_write, write_setup, write_measure)

    # read-sequential / read-4k: stream the file back (page cache warms
    # across repetitions by design; `cold` shows the first pass).
    def read_measure():
        n = 0
        with open(path, "rb") as fh:
            while True:
                b = fh.read(chunk)
                if not b:
                    break
                n += 1
        return n

    add("read-sequential", "MB/s", mb_per_write, noop, read_measure)

    def read_4k_measure():
        n = 0
        with open(path, "rb") as fh:
            while True:
                b = fh.read(4096)
                if not b:
                    break
                n += 1
        return n

    add("read-4k", "MB/s", 4096 / (1024 * 1024), noop, read_4k_measure)

    # statfs: pure syscall rate; thousands of iterations so the timer
    # resolution (~ns via perf_counter) isn't the signal.
    def statfs_measure():
        n = 0
        for _ in range(2000):
            os.statvfs(mount)
            n += 1
        return n

    add("statfs", "ops/s", 1.0, noop, statfs_measure)

    # readdir: setup (makedirs + file creation + content check) is untimed;
    # only listdir calls are measured.
    rdir = os.path.join(mount, "benchdir")
    expected = {f"f{i:03d}" for i in range(files)}

    def readdir_setup():
        os.makedirs(rdir, exist_ok=True)
        for i in range(files):
            with open(os.path.join(rdir, f"f{i:03d}"), "w") as fh:
                fh.write("x")
        got = set(os.listdir(rdir))
        missing = expected - got
        assert not missing, f"readdir setup: {len(missing)} files missing"

    def readdir_measure():
        n = 0
        for _ in range(20):
            os.listdir(rdir)
            n += 1
        return n

    add("readdir", "ops/s", 1.0, readdir_setup, readdir_measure)

    proc = _mount(fused, image, mount, logs)
    try:
        for name, unit, unit_per_op, setup, measure in scenarios:
            try:
                results.append(
                    _run_scenario(name, unit, unit_per_op, setup, measure, repeats)
                )
            except Exception as e:  # noqa: BLE001 — fault isolation is the point
                errors.append(f"{name}: {type(e).__name__}: {e}")
    finally:
        _unmount(proc, mount)

    if errors:
        results.append({"errors": errors})
    return results


def _provenance(args) -> dict:
    info = {
        "argv": vars(args),
        "cpu_count": os.cpu_count(),
    }
    try:
        info["loadavg"] = os.getloadavg()
    except OSError:
        pass
    try:
        rev = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
            check=False,
        )
        if rev.returncode == 0:
            info["git_rev"] = rev.stdout.strip()
        st = subprocess.run(
            ["git", "status", "--porcelain"],
            capture_output=True,
            text=True,
            check=False,
        )
        if st.returncode == 0:
            info["git_dirty"] = st.stdout.strip().splitlines()
    except OSError:
        pass
    return info


def main() -> None:
    parser = argparse.ArgumentParser(description="fused throughput benchmark")
    parser.add_argument("--fused", default="build/fused")
    parser.add_argument("--image", default="bench.img")
    parser.add_argument("--mount", default="mnt")
    parser.add_argument("--logs", default="logs")
    parser.add_argument("--size", type=int, default=8, help="file size in MiB")
    parser.add_argument(
        "--repeats",
        type=int,
        default=5,
        help="timed repetitions per scenario (plus 1 warmup)",
    )
    parser.add_argument(
        "--files", type=int, default=200, help="file count for the readdir scenario"
    )
    parser.add_argument(
        "--json-out", default=None, help="write machine-readable results to PATH"
    )
    args = parser.parse_args()
    args.repeats = max(1, args.repeats)

    results = run(
        args.fused,
        args.image,
        args.mount,
        args.logs,
        args.size,
        args.repeats,
        args.files,
    )
    errors = []
    if results and "errors" in results[-1]:
        errors = results.pop()["errors"]
    print(
        f"{'scenario':<18}{'unit':>8}{'cold':>10}{'median':>10}{'best':>10}{'worst':>10}"
    )
    for r in results:
        print(
            f"{r['name']:<18}{r['unit']:>8}{r['cold']:>10.1f}{r['median']:>10.1f}"
            f"{r['best']:>10.1f}{r['worst']:>10.1f}"
        )
    if args.json_out:
        with open(args.json_out, "w") as f:
            json.dump(
                {"results": results, "errors": errors, "provenance": _provenance(args)},
                f,
                indent=2,
            )
        print(f"wrote {args.json_out}")
    if errors:
        print("ERRORS:")
        for e in errors:
            print(f"  {e}")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
