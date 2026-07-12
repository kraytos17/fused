#!/usr/bin/env bash
# tests/fuse_harness.sh — Run a FUSE test script inside an isolated mount namespace.
#
# Usage:  tests/fuse_harness.sh [--timeout=N] [--log-dir=<dir>] <test-script> [test-args...]
#
# Wraps the test script in `unshare -rUm` so that any FUSE mount created
# inside is automatically torn down when the process exits — even if killed.
# Captures test output and FUSE logs to --log-dir (default: logs/).
set -euo pipefail

HARNESS_TIMEOUT=60
LOG_DIR=logs

while [ $# -gt 0 ]; do
    case "$1" in
        --timeout=*) HARNESS_TIMEOUT="${1#*=}"; shift ;;
        --timeout)   HARNESS_TIMEOUT="$2"; shift 2 ;;
        --log-dir=*) LOG_DIR="${1#*=}"; shift ;;
        --log-dir)   LOG_DIR="$2"; shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done

if [ $# -lt 1 ]; then
    echo "usage: $0 [--timeout=N] [--log-dir=<dir>] <test-script> [test-args...]" >&2
    exit 1
fi

TEST_SCRIPT="$1"; shift
mkdir -p "$LOG_DIR"
HARNESS_LOG="$LOG_DIR/harness_$(basename "$TEST_SCRIPT" .sh).log"

echo "==> fuse_harness: $TEST_SCRIPT $* (timeout=${HARNESS_TIMEOUT}s, log=$HARNESS_LOG)"
command -v fusermount3 &>/dev/null || { echo "FAIL: fusermount3 not found" >&2; exit 1; }
[ -e /dev/fuse ] || { echo "WARN: /dev/fuse missing; 'sudo modprobe fuse' first" >&2; }

for mp in mnt /tmp/rw /tmp/mnt; do
    fusermount3 -uz "$mp" 2>/dev/null || true
done

exit_code=0
if command -v unshare &>/dev/null; then
    echo "  using unshare -rUm (isolated mount namespace)"
    if timeout -k 5 "$HARNESS_TIMEOUT" unshare -rUm bash "$TEST_SCRIPT" "$@" >"$HARNESS_LOG" 2>&1; then
        exit_code=0
    else
        exit_code=$?
    fi
else
    echo "  unshare not available — using direct execution"
    if timeout -k 5 "$HARNESS_TIMEOUT" bash "$TEST_SCRIPT" "$@" >"$HARNESS_LOG" 2>&1; then
        exit_code=0
    else
        exit_code=$?
    fi
fi

if [ "$exit_code" -ne 0 ]; then
    echo "  FAIL (exit=$exit_code): test log tail:" >&2
    tail -20 "$HARNESS_LOG" | sed 's/^/    /' >&2
fi

exit "$exit_code"
