# tests/conformance/pjdfstest_check.py — T-01 conformance gate.
#
# Usage:
#   python3 tests/conformance/pjdfstest_check.py --groups="chmod mkdir rename"
#
# Parses fresh prove logs (logs/pjdfstest-<group>.log, produced by `make
# conformance`) and diffs the failing-test sets against
# tests/conformance/expected_failures.txt:
#   * a failure NOT in the baseline  -> FAIL (new regression)
#   * a baseline entry that now passes -> FAIL (remove/update the line)
#   * per-group test-count drift      -> FAIL (suite changed, re-baseline)
# Exact match -> PASS. This is the "no NEW failures" CI rule: the baseline
# file is the burn-down list, and fixing a test means deleting its line in
# the same PR.
import argparse
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
EXPECTED = os.path.join(ROOT, "tests", "conformance", "expected_failures.txt")
LOG_PAT = os.path.join(ROOT, "logs", "pjdfstest-{}.log")

FILE_RE = re.compile(
    r"/tmp/opencode/pjdfstest/tests/(\S+?\.t) \(Wstat: \d+ Tests: (\d+) Failed: (\d+)\)\n((?:  Failed[^\n]*\n?)*)"
)
TOTAL_RE = re.compile(r"Files=(\d+), Tests=(\d+)")


def expand_ranges(text: str) -> set[int]:
    out: set[int] = set()
    for tok in re.split(r"[,\s]+", text):
        if not tok or tok == "Failed" or tok == "tests:":
            continue
        if tok == "-":
            continue
        if "-" in tok:
            try:
                a, b = tok.split("-", 1)
                out.update(range(int(a), int(b) + 1))
            except ValueError:
                continue
        else:
            try:
                out.add(int(tok))
            except ValueError:
                continue
    return out


def parse_log(path: str) -> tuple[dict[str, set[int]], dict[str, int], bool]:
    """Returns (failures keyed 'group/file.t', totals, ran_ok)."""
    failures: dict[str, set[int]] = {}
    totals: dict[str, int] = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            txt = f.read()
    except OSError:
        return {}, {}, False
    for m in FILE_RE.finditer(txt):
        if int(m.group(3)) == 0:
            continue
        fname = m.group(1).split("/")[-1]
        ranges = " ".join(l.strip() for l in m.group(4).strip().splitlines())
        failures[fname] = expand_ranges(ranges)
    totals["files_tests"] = 0
    for m in TOTAL_RE.finditer(txt):
        totals["files"] = int(m.group(1))
        totals["tests"] = int(m.group(2))
    return failures, totals, True


def parse_expected(groups: list[str]) -> tuple[dict[str, dict[str, set[int]]], dict[str, dict[str, int]]]:
    """Returns (per-group {file: set}, per-group totals)."""
    exp: dict[str, dict[str, set[int]]] = {}
    totals: dict[str, dict[str, int]] = {}
    try:
        with open(EXPECTED, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return exp, totals
    cur: str | None = None
    for line in text.splitlines():
        if line.startswith("## group "):
            cur = line.split("## group ")[1].split(" ")[0]
            exp.setdefault(cur, {})
            continue
        if cur is None:
            continue
        m = re.match(r"(\S+)/(\S+\.t) tests=(\d+) failed=(\d+)\s*(.*)", line)
        if m and m.group(1) == cur:
            exp[cur][m.group(2)] = expand_ranges(m.group(5))
            continue
        m = re.match(rf"{re.escape(cur)} TOTAL files=(\d+) tests=(\d+)", line)
        if m:
            totals[cur] = {"files": int(m.group(1)), "tests": int(m.group(2))}
    return exp, totals


def main() -> int:
    parser = argparse.ArgumentParser(description="pjdfstest baseline gate")
    parser.add_argument("--groups", default="chmod mkdir rename",
                        help="space-separated group list (must match the run)")
    args = parser.parse_args()
    groups = args.groups.split()

    exp, exp_totals = parse_expected(groups)
    failed = False
    for group in groups:
        fresh, fresh_totals, ran = parse_log(LOG_PAT.format(group))
        want = exp.get(group, {})
        print(f"== group {group} ==")
        if not ran:
            print(f"  FAIL: no log logs/pjdfstest-{group}.log (harness did not run?)")
            failed = True
            continue
        # Suite drift: different test counts mean the suite changed.
        if group in exp_totals and "tests" in fresh_totals and fresh_totals["tests"] != exp_totals[group]["tests"]:
                print(f"  FAIL: test-count drift {exp_totals[group]['tests']} -> "
                      f"{fresh_totals['tests']} (suite changed, re-baseline)")
                failed = True
        # New failures.
        for fname, fset in sorted(fresh.items()):
            eset = want.get(fname, set())
            new = fset - eset
            if new:
                print(f"  FAIL new: {group}/{fname} tests {sorted(new)} not in baseline")
                failed = True
        # Fixed tests (baseline entries that now pass).
        for fname, eset in sorted(want.items()):
            fset = fresh.get(fname, set())
            fixed = eset - fset
            if fixed:
                if not fset:
                    print(f"  FAIL fixed: {group}/{fname} fully passes now — remove its line")
                else:
                    print(f"  FAIL fixed: {group}/{fname} tests {sorted(fixed)} pass now — update ranges")
                failed = True
        if not failed:
            print(f"  ok: matches baseline ({len(fresh)} failing files)")
    if failed:
        print("conformance gate: FAIL (see above; update expected_failures.txt only by fixing tests)")
        return 1
    print("conformance gate: PASS (no new failures, no silent fixes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
