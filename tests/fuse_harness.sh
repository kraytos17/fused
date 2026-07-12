#!/usr/bin/env bash
# tests/fuse_harness.sh — Run a FUSE test script inside an isolated mount namespace.
#
# Usage:  tests/fuse_harness.sh [--timeout=N] <test-script> [test-args...]
#
# Wraps the test script in `unshare -rUm` so that any FUSE mount created
# inside is automatically torn down when the process exits — even if killed.
# Falls back to direct execution if unshare is unavailable.
#
# The test script is responsible for its own build + disker dependencies.
set -euo pipefail

HARNESS_TIMEOUT=30

while [ $# -gt 0 ]; do
    case "$1" in
        --timeout=*) HARNESS_TIMEOUT="${1#*=}"; shift ;;
        --timeout)   HARNESS_TIMEOUT="$2"; shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done

if [ $# -lt 1 ]; then
    echo "usage: $0 [--timeout=N] <test-script> [test-args...]" >&2
    exit 1
fi

TEST_SCRIPT="$1"; shift

echo "==> fuse_harness: $TEST_SCRIPT $*"

command -v fusermount3 &>/dev/null || { echo "FAIL: fusermount3 not found" >&2; exit 1; }
[ -e /dev/fuse ] || { echo "WARN: /dev/fuse missing; 'sudo modprobe fuse' first" >&2; }
lsmod 2>/dev/null | grep -q '^fuse ' || { echo "WARN: fuse module not loaded; 'sudo modprobe fuse' first" >&2; }

# Lazy-unmount any stale mounts before proceeding
for mp in mnt /tmp/rw /tmp/mnt; do
    fusermount3 -uz "$mp" 2>/dev/null || true
done

exit_code=0
if command -v unshare &>/dev/null; then
    echo "  using unshare -rUm (isolated mount namespace)"
    if timeout -k 5 "$HARNESS_TIMEOUT" unshare -rUm bash "$TEST_SCRIPT" "$@"; then
        exit_code=0
    else
        exit_code=$?
    fi
else
    echo "  unshare not available — using direct execution"
    if timeout -k 5 "$HARNESS_TIMEOUT" bash "$TEST_SCRIPT" "$@"; then
        exit_code=0
    else
        exit_code=$?
    fi
fi

if [ "$exit_code" -eq 124 ]; then
    echo "FAIL: harness timed out after ${HARNESS_TIMEOUT}s" >&2
    exit 124
fi

exit "$exit_code"
