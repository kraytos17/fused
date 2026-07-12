#!/usr/bin/env bash
# tests/smoke_rw.sh — Phase 5 R/W mount smoke test
#
# Steps:
#   1. Build fresh disker image
#   2. Mount via FUSE in background
#   3. create+write+read file1
#   4. append to file1 (offset write)
#   5. cp file1 -> file2 (cross-file read+write)
#   6. multi-sector write (dd 100 sectors)
#   7. truncate shrink
#   8. unlink big
#   9. nested mkdir
#  10. create in subdir, read back
#  11. recursive cleanup
#  12. unmount, remount, verify persistence
#
# Each step has a hard timeout. On failure: log + exit 1.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LOG=/tmp/fused_smoke.log
FUSE_OUT=/tmp/fused_fuse.log
MOUNT=/tmp/rw
IMG="$ROOT/fused.img"
BIN="$ROOT/build/fused"

FUSE_PID=
FUSE_PGID=

kill_fuse() {
    if [ -n "$FUSE_PGID" ] && [ "$FUSE_PGID" -gt 1 ]; then
        kill -9 -- -"$FUSE_PGID" 2>/dev/null || true
    elif [ -n "$FUSE_PID" ] && kill -0 "$FUSE_PID" 2>/dev/null; then
        kill -9 "$FUSE_PID" 2>/dev/null || true
    fi
    FUSE_PID=
    FUSE_PGID=
}

cleanup() {
    kill_fuse
    fuser -k "$MOUNT" 2>/dev/null || true
    fusermount3 -u "$MOUNT" 2>/dev/null || true
}

trap cleanup EXIT
trap 'exit 1' INT TERM

cleanup

echo "=== Phase 5 smoke test ===" >"$LOG"
date >>"$LOG"

echo
echo "== build =="
make build >>"$LOG" 2>&1 && echo "  build OK" || { echo "  build FAILED"; exit 1; }
make run-disker >>"$LOG" 2>&1 && echo "  disker OK" || { echo "  disker FAILED"; exit 1; }

mount_fuse() {
    kill_fuse
    fuser -k "$MOUNT" 2>/dev/null || true
    fusermount3 -u "$MOUNT" 2>/dev/null || true
    mkdir -p "$MOUNT"
    if command -v setsid &>/dev/null; then
        setsid "$BIN" "$IMG" -f -d "$MOUNT" >"$FUSE_OUT" 2>&1 &
    else
        "$BIN" "$IMG" -f -d "$MOUNT" >"$FUSE_OUT" 2>&1 &
    fi
    FUSE_PID=$!
    FUSE_PGID=$(ps -o pgid= -p "$FUSE_PID" 2>/dev/null | tr -d ' ')
    for i in $(seq 1 50); do
        if mountpoint -q "$MOUNT" 2>/dev/null; then break; fi
        sleep 0.1
    done
    if ! mountpoint -q "$MOUNT" 2>/dev/null; then
        echo "  FAILED: mount did not appear in time"
        cat "$FUSE_OUT"
        exit 1
    fi
    echo "  mounted (pid=$FUSE_PID pgid=$FUSE_PGID)"
}

echo
echo "== mount =="
mount_fuse

umount_fuse() {
    kill_fuse
    fuser -k "$MOUNT" 2>/dev/null || true
    fusermount3 -u "$MOUNT" 2>/dev/null || true
    sleep 0.3
}

have_timeout=0
command -v timeout &>/dev/null && have_timeout=1

PASS=0
FAIL=0
FAILED_STEPS=()

run_step() {
    local desc=$1; shift
    printf "  %-50s " "$desc"
    local ok=0 rc
    if [ "$have_timeout" = 1 ]; then
        timeout 5 "$@" >>"$LOG" 2>&1 && ok=1 || rc=$?
    else
        "$@" >>"$LOG" 2>&1 && ok=1 || rc=$?
    fi
    if [ "$ok" = 1 ]; then
        echo "OK"
        PASS=$((PASS+1))
    else
        echo "FAIL (rc=${rc:-$?})"
        FAIL=$((FAIL+1))
        FAILED_STEPS+=("$desc")
    fi
}

echo
echo "== basic file ops =="
run_step "echo hello > file1"    bash -c 'echo hello > /tmp/rw/file1'
run_step "cat file1"              bash -c 'cat /tmp/rw/file1 | grep -q hello'
run_step "echo world >> file1"    bash -c 'echo world >> /tmp/rw/file1'
run_step "cat file1 (world)"      bash -c 'cat /tmp/rw/file1 | grep -q world'
run_step "cp file1 file2"         bash -c 'cp /tmp/rw/file1 /tmp/rw/file2'
run_step "cat file2 (hello)"      bash -c 'cat /tmp/rw/file2 | grep -q hello'

echo
echo "== multi-sector =="
run_step "dd 100 sectors to big"  bash -c 'dd if=/dev/zero of=/tmp/rw/big bs=512 count=100 2>/dev/null'
run_step "big size >= 50K"        bash -c 'test $(stat -c%s /tmp/rw/big) -ge 51200'

echo
echo "== truncate shrink =="
run_step "truncate -s 0 big"      bash -c 'truncate -s 0 /tmp/rw/big'
run_step "big size == 0"          bash -c 'test $(stat -c%s /tmp/rw/big) -eq 0'
run_step "unlink big"             bash -c 'rm /tmp/rw/big'

echo
echo "== directories =="
run_step "mkdir -p d1/d2"         bash -c 'mkdir -p /tmp/rw/d1/d2'
run_step "echo x > d1/d2/f"       bash -c 'echo x > /tmp/rw/d1/d2/f'
run_step "cat d1/d2/f"            bash -c 'cat /tmp/rw/d1/d2/f | grep -q x'
run_step "rm d1/d2/f"             bash -c 'rm /tmp/rw/d1/d2/f'
run_step "rmdir d1/d2"            bash -c 'rmdir /tmp/rw/d1/d2'
run_step "rmdir d1"               bash -c 'rmdir /tmp/rw/d1'

echo
echo "== unlink file1 + file2 =="
run_step "rm file1"               bash -c 'rm /tmp/rw/file1'
run_step "rm file2"               bash -c 'rm /tmp/rw/file2'
run_step "ls shows empty"         bash -c 'test $(ls /tmp/rw | wc -l) -eq 0'

echo
echo "== persistence: unmount + remount =="
umount_fuse
mount_fuse
run_step "ls shows empty after remount"  bash -c 'test $(ls /tmp/rw | wc -l) -eq 0'

echo
echo "== persistence: create + remount =="
run_step "echo data > persisted"  bash -c 'echo persistent_data > /tmp/rw/persisted'
umount_fuse
mount_fuse
run_step "cat persisted"          bash -c 'cat /tmp/rw/persisted | grep -q persistent_data'

echo
echo "== summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
if [ $FAIL -gt 0 ]; then
    echo "  failed steps:"
    for s in "${FAILED_STEPS[@]}"; do
        echo "    - $s"
    done
    echo
    echo "FUSE log tail:"
    tail -50 "$FUSE_OUT" | sed 's/^/    /'
    exit 1
fi
echo "  ALL PASS"
