# tests/fused_test/suites/audit_sizes.py — Cross-check Odin struct sizes against C ground truth.
#
# Usage:
#   python3 -m fused_test.suites.audit_sizes [--c-bin=<path>]

import argparse
import os
import re
import subprocess
import sys
import tempfile

if __name__ == "__main__":
    _d = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if _d not in sys.path:
        sys.path.insert(0, _d)

from fused_test.result import TestSuite, TestResult


# Known struct mappings: C name → Odin name
C_TO_ODIN = {
    "stat": "Stat",
    "fuse_file_info": "File_Info",
    "fuse_operations": "Operations",
    "fuse_conn_info": "Conn_Info",
    "fuse_config": "Config",
    "fuse_loop_config_v1": "Loop_Config",
    "fuse_context": "Context",
    "libfuse_version": "Libfuse_Version",
    "fuse_args": "Args",
    "fuse_opt": "Opt",
    "fuse_buf": "Buf",
    "fuse_bufvec": "Bufvec",
}


def run(c_src: str | None = None, odin_src: str | None = None) -> TestSuite:
    suite = TestSuite(name="Struct size cross-check")
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
    c_src = c_src or os.path.join(root, "tests", "c_assert.c")
    odin_src = odin_src or os.path.join(root, "tests", "size_check.odin")
    collection = f"-collection:src={os.path.join(root, 'src')}"

    if not os.path.isfile(c_src):
        suite.add(TestResult(name="c-source", passed=False, detail=f"not found: {c_src}"))
        return suite
    if not os.path.isfile(odin_src):
        suite.add(TestResult(name="odin-source", passed=False, detail=f"not found: {odin_src}"))
        return suite

    # Compile and run C ground truth
    with tempfile.TemporaryDirectory() as tmp:
        c_bin = os.path.join(tmp, "c_assert")
        r = subprocess.run(
            ["cc", c_src, "-o", c_bin],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            suite.add(TestResult(name="c-compile", passed=False, detail=r.stderr))
            return suite

        r = subprocess.run([c_bin], capture_output=True, text=True)
        if r.returncode != 0:
            suite.add(TestResult(name="c-run", passed=False, detail=r.stderr))
            return suite
        c_output = r.stdout

    # Compile and run Odin size check
    with tempfile.TemporaryDirectory() as tmp:
        odin_bin = os.path.join(tmp, "size_check")
        r = subprocess.run(
            ["odin", "run", odin_src, "-file", collection,
             "-out:" + odin_bin],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            suite.add(TestResult(name="odin-run", passed=False, detail=r.stderr))
            return suite
        odin_output = r.stdout

    # Parse C output — extract sizeof(struct ...) lines, exclude timespec
    c_sizes = {}
    for line in c_output.split("\n"):
        m = re.match(r'\s+sizeof\(struct\s+([a-z_]+)\)\s*=\s*(\d+)', line)
        if m and m.group(1) != "timespec":
            c_sizes[m.group(1)] = int(m.group(2))

    # Parse Odin output — extract "Name = N" lines
    odin_sizes = {}
    for line in odin_output.split("\n"):
        m = re.match(r'\s+(\w+)\s+=\s+(\d+)', line)
        if m:
            odin_sizes[m.group(1)] = int(m.group(2))

    # Compare
    checked = 0
    missing_c = 0
    missing_odin = 0

    for c_name, c_val in sorted(c_sizes.items()):
        odin_name = C_TO_ODIN.get(c_name)
        if odin_name is None:
            suite.add(TestResult(name=c_name, passed=False,
                                 detail="no Odin mapping"))
            missing_c += 1
            continue

        o_val = odin_sizes.get(odin_name)
        if o_val is None:
            suite.add(TestResult(name=c_name, passed=False,
                                 detail=f"Odin struct '{odin_name}' not found"))
            missing_odin += 1
            continue

        if c_val == o_val:
            suite.add(TestResult(name=f"{c_name} <-> {odin_name}",
                                 passed=True, detail=str(c_val)))
            checked += 1
        else:
            suite.add(TestResult(name=f"{c_name} <-> {odin_name}",
                                 passed=False,
                                 detail=f"C={c_val} Odin={o_val}"))

    # Minimum coverage: at least 75% of known structs
    known = len(C_TO_ODIN)
    min_expected = known * 3 // 4
    if checked < min_expected:
        suite.add(TestResult(name="coverage", passed=False,
                             detail=f"only {checked}/{known} checked (min {min_expected})"))

    return suite


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Cross-check C vs Odin struct sizes")
    parser.add_argument("--c-src", default=None)
    parser.add_argument("--odin-src", default=None)
    args = parser.parse_args()

    suite = run(args.c_src, args.odin_src)
    suite.print_summary()
    sys.exit(1 if suite.failed else 0)
