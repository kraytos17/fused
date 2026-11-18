# tests/conformance/bench_gate.py — benchmark regression gate (T-10).
#
# Usage:
#   python3 tests/conformance/bench_gate.py bench/baseline.json bench.new.json
#       [--tolerance=0.15] [--min-median=1]
#
# Compares per-scenario median throughput (all metrics are higher-better:
# MB/s and ops/s) against the committed baseline. Fails when any scenario
# drops more than tolerance, when a baseline scenario is missing from the
# run, or when the run recorded errors. Prints a comparison table either way.
# NOTE (K-9): shared runners are noisy on µs-scale ops (read-4k swung
# -20/-15/-6% across three identical runs here). A gate failure requires
# one confirmatory re-run before it counts as a regression; only a
# repeatable breach past tolerance is real.
import argparse
import json
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description="fused bench regression gate")
    parser.add_argument("baseline", help="committed baseline JSON")
    parser.add_argument("candidate", help="fresh bench --json-out output")
    parser.add_argument("--tolerance", type=float, default=0.15,
                        help="allowed fractional drop vs baseline")
    args = parser.parse_args()

    with open(args.baseline) as f:
        base = json.load(f)
    with open(args.candidate) as f:
        cand = json.load(f)

    if cand.get("errors"):
        print("ERRORS in candidate run:")
        for e in cand["errors"]:
            print(f"  {e}")
        return 1

    base_med = {r["name"]: r["median"] for r in base["results"]}
    cand_med = {r["name"]: r["median"] for r in cand["results"]}

    print(f"{'scenario':<18}{'baseline':>10}{'candidate':>10}{'delta%':>9}  verdict")
    failed = False
    for name, b in sorted(base_med.items()):
        if name not in cand_med:
            print(f"{name:<18}{b:>10.1f}{'MISSING':>10}         FAIL (absent)")
            failed = True
            continue
        c = cand_med[name]
        delta = (c - b) / b if b != 0 else 0.0
        ok = delta >= -args.tolerance
        print(f"{name:<18}{b:>10.1f}{c:>10.1f}{delta * 100:>8.1f}%  {'ok' if ok else 'REGRESSION'}")
        if not ok:
            failed = True
    for name in sorted(set(cand_med) - set(base_med)):
        print(f"{name:<18}{'new':>10}{cand_med[name]:>10.1f}         (new scenario, no baseline)")

    base_rev = base.get("provenance", {}).get("git_rev", "?")
    cand_rev = cand.get("provenance", {}).get("git_rev", "?")
    print(f"baseline rev {base_rev} vs candidate rev {cand_rev}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
