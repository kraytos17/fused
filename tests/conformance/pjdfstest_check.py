#!/usr/bin/env python3
# tests/conformance/pjdfstest_check.py — T-01 conformance gate.
#
# Usage:
#   python3 tests/conformance/pjdfstest_check.py [--groups="..."]
#       [--baseline PATH] [--log-dir DIR]
#
# Diffs fresh `prove -v` logs against expected_failures.txt:
#   * any failure not in the baseline            -> FAIL (new regression)
#   * any baseline entry that now passes        -> FAIL (remove/update it)
#   * TAP-vs-summary count drift, Wstat != 0    -> FAIL (see message)
#   * missing Result: line, crash markers       -> FAIL (see message)
#   * per-group test-count drift vs baseline    -> FAIL (suite changed)
#   * skip-count changes                        -> reported, never fails
#   * env (ran-as-non-root) vs real split       -> reported per assertion
# Exit 0 iff everything matches; every group prints its own verdict.
"""T-01 gate: no new failures, no silent fixes."""

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pjdfstest_parse as P

FILE_LINE_RE = re.compile(r"^(\S+\.t) tests=(\d+) failed=(\d+)(?: skipped=(\d+))?\s*$")
GROUP_RE = re.compile(r"^## group (\S+)")
SKIP_LINE_RE = re.compile(r"^  skipped: (.*)$")
ENV_LINE_RE = re.compile(r"^  env: (.*)$")


def parse_baseline(path):
    """group -> file -> {tests, failed:set, skipped:int, env:set}."""
    groups = {}
    problems = []
    cur = None
    cur_file = None
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError as e:
        return groups, [f"cannot read baseline {path}: {e}"]
    for line in lines:
        m = GROUP_RE.match(line)
        if m:
            cur = m.group(1)
            groups.setdefault(cur, {})
            cur_file = None
            continue
        if not line.strip() or line.startswith("#"):
            continue
        if line.startswith("## "):
            cur_file = None
            continue
        m = FILE_LINE_RE.match(line)
        if m and cur is not None:
            name = os.path.basename(m.group(1))
            groups[cur][name] = {
                "tests": int(m.group(2)),
                "failed": set(),
                "skipped": int(m.group(4)) if m.group(4) else 0,
                "env": set(),
            }
            if int(m.group(3)) == 0 and groups[cur][name]["skipped"] == 0:
                problems.append(f"{cur}/{name}: file line with failed=0 and no skips is noise (drop it)")
            cur_file = name
            continue
        if line.startswith("  failed:") and cur is not None and cur_file is not None:
            groups[cur][cur_file]["failed"] = P.expand_ranges(line[len("  failed:"):])
            continue
        if line.startswith("  env:") and cur is not None and cur_file is not None:
            groups[cur][cur_file]["env"] = P.expand_ranges(line[len("  env:"):])
            continue
        if line.startswith("  skipped:") and cur is not None and cur_file is not None:
            continue  # informational; counts live on the file line
        if line.startswith("  crash:") and cur is not None and cur_file is not None:
            continue  # informational note attached to the failing file
        problems.append(f"unparsable baseline line: {line[:100]!r}")
    for group, files in groups.items():
        for name, rec in files.items():
            if not rec["env"] <= rec["failed"]:
                problems.append(f"{group}/{name}: env is not a subset of failed")
    return groups, problems


def check_group(group, log, expected):
    """Returns (ok, lines). Never throws for missing logs."""
    out = []
    files, result, problems = P.parse_prove_log(log)
    for p in problems:
        out.append(f"  harness: {p}")
    ok = not problems
    if result is None:
        out.append("  harness: missing Result: line")
        ok = False
    for name in sorted(files):
        if files[name].crashed:
            out.append(f"  FAIL {name}: crashed ({files[name].crashed})")
            ok = False
    exp = expected.get(group, {})
    # Count drift: fresh TAP plan vs baseline tests=.
    for name in sorted(set(files) | set(exp)):
        fr = files.get(name)
        er = exp.get(name)
        if er is not None and fr is not None and fr.plan is not None \
                and fr.plan != er["tests"]:
            out.append(f"  FAIL {name}: test-count drift {er['tests']} -> {fr.plan} "
                       "(suite changed, re-baseline)")
            ok = False
        if er is not None and fr is not None and er["skipped"] != len(fr.skipped):
            out.append(f"  note {name}: skipped {er['skipped']} -> {len(fr.skipped)} "
                       "(informational only)")
    # New failures (with env/real classification from the tried text).
    for name in sorted(files):
        fresh = files[name].failed
        want = exp.get(name, {}).get("failed", set()) if name in exp else set()
        new = fresh - want
        if new:
            kinds = sorted(("env" if P.is_env_failure(files[name].tried.get(n, "")) else "real")
                           for n in new)
            out.append(f"  FAIL {name}: new failures {P.format_ranges(new)} "
                       f"[{','.join(kinds)}]")
            ok = False
    # Fixed (silently passing) entries.
    for name in sorted(exp):
        want = exp[name]["failed"]
        fresh = files.get(name).failed if name in files else set()
        fixed = want - fresh
        if fixed:
            out.append(f"  FAIL {name}: now passing {P.format_ranges(fixed)} "
                       "(remove/update the baseline entry)")
            ok = False
    # Burn-down context.
    n_env = n_real = 0
    for name in sorted(files):
        for num in sorted(files[name].failed):
            if P.is_env_failure(files[name].tried.get(num, "")):
                n_env += 1
            else:
                n_real += 1
    out.append(f"  files failing: {sum(1 for f in files.values() if f.failed)} "
               f"(env={n_env} real={n_real} failed assertions)")
    if ok:
        out.append("  ok: matches baseline (no new failures, no silent fixes)")
    return ok, out


def main():
    parser = argparse.ArgumentParser(description="T-01 conformance gate")
    parser.add_argument("--groups", default=None,
                        help="space-separated list (default: every group in the baseline)")
    parser.add_argument("--baseline",
                        default=os.path.join("tests", "conformance", "expected_failures.txt"))
    parser.add_argument("--log-dir", default="logs")
    args = parser.parse_args()

    expected, bproblems = parse_baseline(args.baseline)
    if args.groups is not None and args.groups.strip():
        groups = args.groups.split()
    else:
        # Prefer groups that actually ran (the gate follows the runner);
        # daemon logs share the prefix, so exclude them. Fall back to the
        # baseline, then to nothing with a clear error.
        groups = sorted({
            f[len("pjdfstest-"):-len(".log")]
            for f in os.listdir(args.log_dir)
            if f.startswith("pjdfstest-") and f.endswith(".log")
            and not f.endswith("-daemon.log")
        }) or sorted(expected)
    if not groups:
        print("no groups selected and baseline is empty")
        return 2

    overall = True
    for p in bproblems:
        print(f"baseline: {p}")
        overall = False
    for group in groups:
        print(f"== group {group} ==")
        log = os.path.join(args.log_dir, f"pjdfstest-{group}.log")
        if not os.path.isfile(log):
            print(f"  harness: no log {log} (harness did not run?)")
            overall = False
            continue
        ok, lines = check_group(group, log, expected)
        for line in lines:
            print(line)
        if not ok:
            overall = False
    if overall:
        print("conformance gate: PASS (no new failures, no silent fixes)")
        return 0
    print("conformance gate: FAIL (see above; update expected_failures.txt only by fixing tests)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
