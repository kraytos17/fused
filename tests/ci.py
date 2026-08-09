# tests/ci.py — fused CI pipeline.
#
# Usage:
#   python3 tests/ci.py [--skip-fuse] [--skip-tool-tests]
#
# Orchestrates all phases: static analysis, unit tests, tool tests, FUSE smoke.

import argparse
import os
import subprocess
import sys

_tests_dir = os.path.dirname(os.path.abspath(__file__))
if _tests_dir not in sys.path:
    sys.path.insert(0, _tests_dir)

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BUILD = os.path.join(ROOT, "build")
LOGS = os.path.join(ROOT, "logs")
MOUNT = os.path.join(ROOT, "mnt")


class Suite:
    """Tiny aggregation of named phase results (pass/fail + optional detail)."""

    def __init__(self, name: str) -> None:
        self.name = name
        self.results: list[tuple[str, bool, str]] = []

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
        print(f"=== {self.name}: {self.passed} passed, {self.failed} failed ===")


def make_suite(name: str, cmd: list[str], cwd: str | None = None) -> Suite:
    s = Suite(name=name)
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd or ROOT, check=False)
    sys.stdout.write(r.stdout)
    s.add(name, r.returncode == 0,
          detail=r.stdout.strip() if r.returncode != 0 else "")
    return s


def phase_static() -> tuple[int, int]:
    suites = [
        make_suite("struct sizes", ["make", "check"]),
        make_suite("context audit", ["make", "audit"]),
        make_suite("vet", ["make", "vet"]),
    ]
    print("== Phase 1: Build + static analysis ==")
    total_p = total_f = 0
    for s in suites:
        s.print_summary()
        total_p += s.passed
        total_f += s.failed
    return total_p, total_f


def phase_unit() -> tuple[int, int]:
    print("== Phase 2: Unit tests ==")
    s = make_suite("odin test", ["make", "test"])
    s.print_summary()
    return s.passed, s.failed


def phase_tools(skip: bool = False) -> tuple[int, int]:
    if skip:
        print("== Phase 3: Tool integration tests ==")
        print("  (skipped)")
        return 0, 0
    print("== Phase 3: Tool integration tests ==")
    s = make_suite("tool tests",
                   ["make", "pytest", "ARGS=-v -m tool --tb=short"],
                   cwd=ROOT)
    s.print_summary()
    return s.passed, s.failed


def phase_fuse(skip: bool = False) -> tuple[int, int]:
    if skip:
        print("== Phase 4: FUSE smoke tests ==")
        print("  (skipped)")
        return 0, 0

    if not os.path.exists("/dev/fuse") or subprocess.run(["which", "unshare"],
                                                           capture_output=True, check=False).returncode != 0:
        print("  WARN: /dev/fuse or unshare missing — skipping FUSE tests")
        return 0, 0

    # Build + create image
    subprocess.run(["make", "build", "create-image"], cwd=ROOT, check=True)

    harness = os.path.join(ROOT, "tests", "run_in_namespace.sh")
    env = os.environ.copy()
    env["PYTHONPATH"] = _tests_dir + ":" + env.get("PYTHONPATH", "")

    print("== Phase 4: FUSE smoke tests ==")

    r = subprocess.run(
        [harness, "120", "uv", "run", "pytest", "tests/", "-m", "fuse", "-v", "--tb=short",
         "--fused", os.path.join(BUILD, "fused"),
         "--image", os.path.join(ROOT, "fused.img"),
         "--mount", MOUNT,
         "--logs", LOGS],
        capture_output=True, text=True, env=env, cwd=ROOT, check=False,
    )
    sys.stdout.write(r.stdout)
    if r.stderr:
        sys.stderr.write(r.stderr)
    s = Suite(name="FUSE smoke")
    s.add("fuse-smoke", r.returncode == 0,
          detail=r.stdout.strip() if r.returncode != 0 else "")
    s.print_summary()
    return s.passed, s.failed


def main() -> None:
    parser = argparse.ArgumentParser(description="fused CI")
    parser.add_argument("--skip-fuse", action="store_true")
    parser.add_argument("--skip-tool-tests", action="store_true")
    args = parser.parse_args()

    total_p = total_f = 0

    print("=== fused CI pipeline ===")
    print()

    p, f = phase_static()
    total_p += p
    total_f += f

    print()
    p, f = phase_unit()
    total_p += p
    total_f += f

    print()
    p, f = phase_tools(skip=args.skip_tool_tests)
    total_p += p
    total_f += f

    print()
    p, f = phase_fuse(skip=args.skip_fuse)
    total_p += p
    total_f += f

    print()
    print(f"=== CI: {total_p} passed, {total_f} failed ===")
    print()
    print("  Output logs:")
    print(f"    {BUILD}/       - binaries")
    print(f"    {LOGS}/        - per-run logs")
    print("    /dev/shm/    - cached test images")
    sys.exit(1 if total_f else 0)


if __name__ == "__main__":
    main()
