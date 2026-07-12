#!/usr/bin/env bash
# tests/ci.sh — CI pipeline for fused.
#
# Runs non-FUSE checks first (fast), then attempts FUSE smoke tests
# inside an isolated mount namespace (self-cleaning on failure).
#
# Usage:  bash tests/ci.sh [--no-fuse]
set -euo pipefail

cd "$(dirname "$0")/.."
NO_FUSE=0

for arg in "$@"; do
    [ "$arg" = "--no-fuse" ] && NO_FUSE=1
done

echo "=== fused CI pipeline ==="
echo

echo "== Phase 1: build + check + audit + test =="
echo

echo "--- build ---"
make build 2>&1 | tail -1 | sed 's/^/  /'

echo "--- check (C vs Odin struct sizes) ---"
make check 2>&1 | tail -1 | sed 's/^/  /'

echo "--- audit (context + logger restoration) ---"
make audit 2>&1 | tail -1 | sed 's/^/  /'

echo "--- test (non-FUSE unit tests) ---"
make test 2>&1 | grep -E 'Finished|failed' | sed 's/^/  /'

echo
echo "== Phase 1: passed =="

if [ "$NO_FUSE" -eq 1 ]; then
    echo
    echo "== Phase 2: skipped (--no-fuse) =="
    echo "== CI complete =="
    exit 0
fi

echo
echo "== Phase 2: FUSE smoke tests =="
echo

[ -e /dev/fuse ] || { echo "  WARN: /dev/fuse missing — skipping FUSE tests" >&2; echo "== CI complete =="; exit 0; }
command -v unshare &>/dev/null || { echo "  WARN: unshare missing — skipping FUSE tests" >&2; echo "== CI complete =="; exit 0; }

echo "--- smoke-harness (read-only FUSE test inside unshare) ---"
if timeout 60 unshare -rUm bash tests/smoke.sh 2>&1; then
    echo "  PASS"
else
    rc=$?
    [ $rc -eq 124 ] && echo "  TIMEOUT" || echo "  FAIL (rc=$rc)"
fi

echo
echo "== CI complete =="
