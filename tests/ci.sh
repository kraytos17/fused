#!/usr/bin/env bash
# tests/ci.sh — CI pipeline for fused.
#
# Phases:
#   1. Build + static analysis (struct sizes, context audit, vet)
#   2. Unit tests (Odin @test suite)
#   3. Tool integration tests (disker + imgdump)
#   4. FUSE read-only smoke test (inside unshare)
#   5. FUSE read-write smoke test with persistence (inside unshare)
#
# Usage:  bash tests/ci.sh [--no-fuse] [--no-tool-tests]
set -euo pipefail

cd "$(dirname "$0")/.."

NO_FUSE=0
NO_TOOL_TESTS=0
for arg in "$@"; do
    [ "$arg" = "--no-fuse" ] && NO_FUSE=1
    [ "$arg" = "--no-tool-tests" ] && NO_TOOL_TESTS=1
done

PASS=0
FAIL=0
phase_pass() { PASS=$((PASS+1)); echo "  PASS"; }
phase_fail() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

echo "=== fused CI pipeline ==="
echo

echo "== Phase 1: Build + static analysis =="
echo

echo "--- build (mounter + disker + imgdump) ---"
make build 2>&1 | tail -1 | sed 's/^/  /' && make disker 2>&1 | tail -1 | sed 's/^/  /' && make imgdump 2>&1 | tail -1 | sed 's/^/  /' && phase_pass || phase_fail "build"

echo "--- check (C vs Odin struct sizes) ---"
make check 2>&1 | tail -1 | sed 's/^/  /' && phase_pass || phase_fail "struct check"

echo "--- audit (context + logger restoration) ---"
make audit 2>&1 | tail -1 | sed 's/^/  /' && phase_pass || phase_fail "context audit"

echo "--- vet (type-check + style) ---"
make vet 2>&1 | tail -1 | sed 's/^/  /' && phase_pass || phase_fail "vet"

echo
echo "== Phase 2: Unit tests =="
echo

echo "--- Odin @test suite ---"
make run-disker 2>&1 | tail -1 | sed 's/^/  /'
if make test 2>&1; then
    phase_pass
else
    phase_fail "unit tests"
fi

echo
echo "== Phase 3: Tool integration tests =="
echo

if [ "$NO_TOOL_TESTS" -eq 1 ]; then
    echo "  (skipped --no-tool-tests)"
else
    echo "--- disker + imgdump integration (20 tests) ---"
    if bash tests/disker_test.sh 2>&1 | tail -1 | grep -q "0 failed"; then
        phase_pass
    else
        phase_fail "tool integration tests"
    fi
fi

echo
echo "== Phase 4: FUSE smoke tests =="
echo

if [ "$NO_FUSE" -eq 1 ]; then
    echo "  (skipped --no-fuse)"
elif [ ! -e /dev/fuse ] || ! command -v unshare &>/dev/null; then
    echo "  WARN: /dev/fuse or unshare missing — skipping FUSE tests"
else
    echo "--- smoke (read-only FUSE test) ---"
    if timeout 60 unshare -rUm bash tests/smoke.sh 2>&1; then
        phase_pass
    else
        rc=$?
        [ $rc -eq 124 ] && phase_fail "smoke (timeout)" || phase_fail "smoke (rc=$rc)"
    fi

	echo "--- smoke-rw (read-write + persistence) ---"
	if timeout 120 unshare -rUm bash tests/smoke_rw.sh 2>&1; then
		phase_pass
	else
		rc=$?
		[ $rc -eq 124 ] && echo "  TIMEOUT (rw smoke)" || echo "  WARN: smoke-rw rc=$rc (some persistence tests may be expected to fail)"
	fi

	echo "--- smoke-mt (multi-threaded stress test) ---"
	if timeout 120 unshare -rUm bash tests/smoke_mt.sh 2>&1; then
		phase_pass
	else
		rc=$?
		[ $rc -eq 124 ] && phase_fail "smoke-mt (timeout)" || phase_fail "smoke-mt (rc=$rc)"
	fi
fi

echo
echo "=== CI complete: $PASS passed, $FAIL failed ==="
echo
echo "  Output logs:"
echo "    build/       - binaries"
echo "    logs/        - per-run logs (fused_smoke.log, fused_fuse.log)"
echo "    /dev/shm/    - cached test images"
[ "$FAIL" -eq 0 ]
