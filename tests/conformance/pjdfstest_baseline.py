#!/usr/bin/env python3
# tests/conformance/pjdfstest_baseline.py — (re)generate expected_failures.txt.
#
# Usage:
#   python3 tests/conformance/pjdfstest_baseline.py [--log-dir logs]
#       [--out tests/conformance/expected_failures.txt] [group...]
#   (no groups: every group with a prove log in --log-dir)
#
# Reads fresh `prove -v` logs, classifies each failure, and writes the
# baseline file the gate compares against. Deliberate act only: never run
# this to silence a gate failure — a diff here means the code or the suite
# changed, and the diff must be understood first.
#
# Classification per failed test (from its TAP tried text):
#   env  — ran as a non-root user (-u/-g nonzero): without allow_other the
#          VFS denies these before fused ever sees them (verified by tracing
#          that zero such ops arrive at the daemon). Blocked on allow_other
#          + default_permissions, not on filesystem bugs.
#   real — everything else: the burn-down list.
"""Regenerate the pjdfstest baseline from prove -v logs."""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pjdfstest_parse as P

PIN = "85a8aea9e685999ef0540392fd80535f873d7ff7"


def main():
    parser = argparse.ArgumentParser(description="regenerate pjdfstest baseline")
    parser.add_argument("--log-dir", default="logs")
    parser.add_argument("--out", default=os.path.join("tests", "conformance", "expected_failures.txt"))
    parser.add_argument("groups", nargs="*")
    args = parser.parse_args()

    if args.groups:
        groups = args.groups
    else:
        groups = sorted({
            f[len("pjdfstest-"):-len(".log")]
            for f in os.listdir(args.log_dir)
            if f.startswith("pjdfstest-") and f.endswith(".log")
            and not f.endswith("-daemon.log")
        })
    if not groups:
        print("no groups given and no pjdfstest-*.log found", file=sys.stderr)
        return 2

    out = [
        "# expected_failures.txt — pjdfstest baseline (T-01).",
        f"# Pinned: pjdfstest {PIN}.",
        "# Per failing file: TAP-derived failed set (ground truth) plus an",
        "# env subset (ran as non-root uid/gid: VFS-denied without allow_other,",
        "# never reached the daemon — blocked on allow_other, not a bug).",
        "# Everything else is the real burn-down list.",
        "# CI rule: no NEW failures; a fixed entry must be removed from this",
        "# file in the same PR. Regenerate with pjdfstest_baseline.py only",
        "# after understanding the diff — never to silence the gate.",
    ]
    total = {"tests": 0, "failed": 0, "env": 0, "real": 0, "skipped": 0}
    for group in groups:
        log = os.path.join(args.log_dir, f"pjdfstest-{group}.log")
        out.append(f"## group {group} ({log})")
        files, result, problems = P.parse_prove_log(log)
        for p in problems:
            out.append(f"# PARSE ISSUE: {p}")
            print(f"{group}: PARSE ISSUE: {p}", file=sys.stderr)
        if result != "FAIL" and any(fr.failed or fr.crashed for fr in files.values()):
            print(f"{group}: WARNING: no Result: FAIL line despite failures", file=sys.stderr)
        g = {"tests": 0, "failed": 0, "env": 0, "real": 0, "skipped": 0}
        crashed = [n for n, fr in sorted(files.items()) if fr.crashed]
        for name in crashed:
            out.append(f"# CRASH {name}: {files[name].crashed} (triage: regression test + checker finding)")
        for name in sorted(files):
            fr = files[name]
            if not fr.failed and not fr.skipped and not fr.crashed:
                continue
            if fr.crashed:
                continue  # recorded above; not a countable failure set
            tests_n = fr.plan if fr.plan is not None else (fr.summary_tests or 0)
            skipped = sorted(fr.skipped)
            failed = sorted(fr.failed)
            env = sorted(n for n in failed if P.is_env_failure(fr.tried.get(n, "")))
            real = sorted(n for n in failed if n not in set(env))
            line = f"{name} tests={tests_n} failed={len(failed)}"
            if skipped:
                line += f" skipped={len(skipped)}"
            out.append(line)
            out.append(f"  failed: {P.format_ranges(set(failed)) if failed else 'none'}")
            if skipped:
                out.append(f"  skipped: {P.format_ranges(set(skipped))}")
            if env:
                out.append(f"  env: {P.format_ranges(set(env))}")
            g["failed"] += len(failed)
            g["env"] += len(env)
            g["real"] += len(real)
            g["skipped"] += len(skipped)
        # Per-group test total: plans if available, else summary counts.
        plans = [files[n].plan for n in sorted(files) if files[n].plan is not None]
        g["tests"] = sum(plans) if plans and len(plans) == len(files) else sum(
            (files[n].summary_tests or 0) for n in sorted(files))
        out.append(f"## totals {group}: tests={g['tests']} failed={g['failed']} "
                   f"env={g['env']} real={g['real']} skipped={g['skipped']}")
        out.append("")
        for k in total:
            total[k] += g[k]
    out.append(f"# GRAND TOTAL tests={total['tests']} failed={total['failed']} "
               f"env={total['env']} real={total['real']} skipped={total['skipped']}")
    with open(args.out, "w") as f:
        f.write("\n".join(out) + "\n")
    print(f"wrote {args.out}: tests={total['tests']} failed={total['failed']} "
          f"env={total['env']} real={total['real']} skipped={total['skipped']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
