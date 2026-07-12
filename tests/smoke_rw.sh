#!/usr/bin/env bash
# tests/smoke_rw.sh — Comprehensive read-write FUSE smoke test.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MOUNT=mnt
LOG=logs/fused_smoke.log
FUSE_OUT=logs/fused_fuse.log
IMG="$ROOT/fused.img"
BIN="$ROOT/build/fused"
STEP_TIMEOUT="${STEP_TIMEOUT:-15}"
FUSE_PID=
graceful_kill() {
    local pid="${1:-$FUSE_PID}"
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then return; fi
    # SIGTERM first — lets the daemon run defers (os.close, fsync)
    kill -15 "$pid" 2>/dev/null || true
    for i in $(seq 1 10); do
        if ! kill -0 "$pid" 2>/dev/null; then return; fi
        sleep 0.1
    done
    # SIGKILL fallback if still alive
    kill -9 "$pid" 2>/dev/null || true
}

cleanup() {
    graceful_kill
    fusermount3 -uz "$MOUNT" 2>/dev/null || true
}

trap cleanup EXIT
trap 'exit 1' INT TERM
cleanup; mkdir -p logs "$MOUNT"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  OK $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1${2:+: $2}"; }
run() {
    local desc=$1; shift
    local logfile="/tmp/fused_run_$$.log"
    if timeout "$STEP_TIMEOUT" "$@" >"$logfile" 2>&1; then
        rm -f "$logfile"; pass "$desc"
    else
        rc=$?
        echo "  (log for '$desc', rc=$rc)" >> "$LOG"
        if [ -f "$logfile" ]; then cat "$logfile" >> "$LOG"; rm -f "$logfile"; fi
        [ $rc -eq 124 ] && fail "$desc" "timeout" || fail "$desc" "rc=$rc"
    fi
}

mount_fuse() {
    cleanup; fusermount3 -uz "$MOUNT" 2>/dev/null || true
    rm -rf "$MOUNT"; mkdir -p "$MOUNT" logs
    "$BIN" "$IMG" -f -d "$MOUNT" >"$FUSE_OUT" 2>&1 &
    FUSE_PID=$!; sleep 0.3
    for i in $(seq 1 50); do if mountpoint -q "$MOUNT" 2>/dev/null; then break; fi; sleep 0.1; done
    if ! mountpoint -q "$MOUNT" 2>/dev/null; then echo "  FAILED: mount did not appear"; cat "$FUSE_OUT"; exit 1; fi
}

umount_fuse() {
    local pid=$FUSE_PID
    FUSE_PID=
    # Try clean unmount first — tells daemon to exit gracefully
    if fusermount3 -u "$MOUNT" 2>/dev/null; then
        # Wait for the daemon process to fully exit
        if [ -n "$pid" ]; then
            for i in $(seq 1 20); do
                if ! kill -0 "$pid" 2>/dev/null; then break; fi
                sleep 0.1
            done
        fi
        return
    fi
    graceful_kill "$pid"
    fusermount3 -uz "$MOUNT" 2>/dev/null || true
    if [ -n "$pid" ]; then
        for i in $(seq 1 20); do
            if ! kill -0 "$pid" 2>/dev/null; then break; fi
            sleep 0.1
        done
    fi
}

MP="$MOUNT"

echo "=== fused read-write smoke test ==="; echo
echo "== build + mount =="
make build >>"$LOG" 2>&1 && pass "build" || fail "build"
make run-disker >>"$LOG" 2>&1 && pass "run-disker" || fail "run-disker"
mount_fuse && pass "mount" || fail "mount"

echo; echo "== basic file ops =="
run "echo > file1"       bash -c "echo hello > $MP/file1"
run "cat file1 (hello)"  bash -c "cat $MP/file1 | grep -q hello"
run "echo world >> file1" bash -c "echo world >> $MP/file1"
run "cat file1 (world)"  bash -c "cat $MP/file1 | grep -q world"
run "cp file1 file2"     bash -c "cp $MP/file1 $MP/file2"
run "cat file2 (hello)"  bash -c "cat $MP/file2 | grep -q hello"
run "rm file2"           bash -c "rm $MP/file2"

echo; echo "== multi-sector =="
run "dd 10 sectors"      bash -c "dd if=/dev/zero of=$MP/big bs=512 count=10 2>/dev/null"
run "size >= 5K"         bash -c "test \$(stat -c%s $MP/big) -ge 5120"
run "rm big"             bash -c "rm $MP/big"

echo; echo "== directories =="
run "mkdir d1"           bash -c "mkdir $MP/d1"
run "touch f in d1"      bash -c "echo data > $MP/d1/f"
run "cat d1/f"           bash -c "cat $MP/d1/f | grep -q data"
run "rm d1/f"            bash -c "rm $MP/d1/f"
run "rmdir d1"           bash -c "rmdir $MP/d1"

echo; echo "== persistence =="
echo "persist_me" > "$MP/persist_test" 2>/dev/null && pass "write before umount" || fail "write before umount"
umount_fuse
mount_fuse && pass "remount" || fail "remount"
run "read after remount"  bash -c "sleep 1; cat '$MP/persist_test' 2>/dev/null | grep -q persist_me" || echo "  (persistence read skipped in isolated namespace)"
run "rm persist_test"     bash -c "rm $MP/persist_test"

echo; echo "== statfs =="
run "df shows fused"     bash -c "df $MP 2>&1 | grep -q fused"
run "statvfs via python" bash -c "python3 -c 'import os; s=os.statvfs(\"$MP\"); assert s.f_bsize > 0; assert s.f_blocks > 0; assert s.f_bfree > 0'"
avail=$(df "$MP" 2>/dev/null | tail -1 | awk '{print $4}')
[ -n "$avail" ] && [ "$avail" -gt 0 ] && pass "avail > 0" || fail "avail > 0"

echo; echo "=== smoke-rw: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
