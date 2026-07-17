# tests/fused_test/suites/audit_context.py — Audit "c" procs for context+logger restoration.
#
# Usage:
#   python3 -m fused_test.suites.audit_context [--src=<path>]

import argparse
import os
import re
import sys

if __name__ == "__main__":
    _d = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if _d not in sys.path:
        sys.path.insert(0, _d)

from fused_test.result import TestSuite, TestResult


def run(src: str | None = None) -> TestSuite:
    suite = TestSuite(name="Context audit")

    if src is None:
        src = os.path.join(os.path.dirname(__file__), "..", "..", "..",
                           "src", "mounter", "ops.odin")
    src = os.path.abspath(src)

    if not os.path.isfile(src):
        suite.add(TestResult(name="src-file", passed=False, detail=f"not found: {src}"))
        return suite

    with open(src) as f:
        text = f.read()
    lines = text.splitlines()

    proc_re = re.compile(r'(\w+)\s*::\s*proc\s+"c"\s*\(')
    ctx_re = re.compile(r'context\s*=\s*runtime\.default_context')
    log_re = re.compile(r'context\.logger\s*=\s*fsys\.logger')

    checked = 0
    procs_found = 0
    i = 0

    while i < len(lines):
        m = proc_re.search(lines[i])
        if not m:
            i += 1
            continue
        procs_found += 1
        name = m.group(1)

        # Find opening brace
        j = i
        brace_depth = 0
        while j < len(lines):
            for ch in lines[j]:
                if ch == '(':
                    brace_depth += 1
                elif ch == ')':
                    brace_depth -= 1
                elif ch == '{' and brace_depth == 0:
                    break
            else:
                j += 1
                continue
            break
        if j >= len(lines):
            suite.add(TestResult(name=name, passed=False, detail="no opening brace"))
            i = j
            continue

        # Collect first 3 non-blank body lines
        k = j + 1
        body = []
        while k < len(lines) and len(body) < 3:
            stripped = lines[k].strip()
            if stripped and not stripped.startswith('//'):
                body.append(stripped)
            k += 1

        body_text = '\n'.join(body)
        has_ctx = bool(ctx_re.search(body_text))
        has_log = bool(log_re.search(body_text))

        if has_ctx and has_log:
            suite.add(TestResult(name=name, passed=True))
            checked += 1
        elif has_ctx and not has_log:
            suite.add(TestResult(name=name, passed=False,
                                 detail="missing context.logger = fsys.logger"))
        elif not has_ctx and has_log:
            suite.add(TestResult(name=name, passed=False,
                                 detail="logger set without context restore"))
        else:
            suite.add(TestResult(name=name, passed=False, detail="both missing"))

        i = k

    # Sanity check
    min_expected = 30
    if procs_found < min_expected:
        suite.add(TestResult(name="sanity", passed=False,
                             detail=f"only {procs_found} procs found (expected >= {min_expected})"))

    return suite


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Audit context restoration in FUSE callbacks")
    parser.add_argument("--src", default=None, help="Path to ops.odin")
    args = parser.parse_args()

    suite = run(args.src)
    suite.print_summary()
    sys.exit(1 if suite.failed else 0)
