#!/usr/bin/env bash
# smoke.sh — End-to-end smoke test for the FUSE3 binding.
#
# Mounts, exercises ls/cat/stat, verifies the read-only nature (writes
# must fail with EROFS), and unmounts cleanly.
#
# Uses the Makefile's build output by default (BUILD_DIR=/bld/fused).
# Override with BIN=/path/to/binary.
set -euo pipefail

cd "$(dirname "$0")/.."

MOUNT=/tmp/mnt
LOG=/tmp/fused_smoke.log
BUILD_DIR="${BUILD_DIR:-build}"
BIN="${BIN:-$BUILD_DIR/fused}"

echo "==> Using binary: $BIN"
[ -x "$BIN" ] || { echo "FAIL: $BIN not executable; run 'make build' first" >&2; exit 1; }

echo "==> Cleaning up any stale mount"
fusermount3 -u $MOUNT 2>/dev/null || true
rm -rf $MOUNT
mkdir -p $MOUNT

echo "==> Starting $BIN -f -d $MOUNT"
$BIN -f -d $MOUNT > $LOG 2>&1 &
PID=$!

cleanup() {
    kill $PID 2>/dev/null || true
    wait $PID 2>/dev/null || true
    fusermount3 -u $MOUNT 2>/dev/null || true
}
trap cleanup EXIT

for i in 1 2 3 4 5 6 7 8 9 10; do
    if mountpoint -q $MOUNT 2>/dev/null; then break; fi
    sleep 0.1
done

if ! mountpoint -q $MOUNT 2>/dev/null; then
    echo "FAIL: mount did not appear in time" >&2
    cat $LOG >&2
    exit 1
fi

echo "==> ls $MOUNT"
listing=$(ls $MOUNT)
echo "$listing"
[ "$listing" = "hello.txt" ] || { echo "FAIL: expected 'hello.txt' in ls, got '$listing'" >&2; exit 1; }

echo "==> cat $MOUNT/hello.txt"
content=$(cat $MOUNT/hello.txt)
expected='Hello from fused!'
[ "$content" = "$expected" ] || { echo "FAIL: expected '$expected', got '$content'" >&2; exit 1; }
size=$(stat -c '%s' $MOUNT/hello.txt)
[ "$size" = "18" ] || { echo "FAIL: expected size 18 (including \\n), got $size" >&2; exit 1; }

echo "==> stat $MOUNT/hello.txt (size & mode checks)"
mode=$(stat -c '%a' $MOUNT/hello.txt)
size=$(stat -c '%s' $MOUNT/hello.txt)
[ "$mode" = "444" ] || { echo "FAIL: expected mode 444, got $mode" >&2; exit 1; }
[ "$size" = "18" ] || { echo "FAIL: expected size 18, got $size" >&2; exit 1; }

echo "==> write attempt (must fail with read-only filesystem)"
if touch $MOUNT/newfile 2>/dev/null; then
    echo "FAIL: touch succeeded on read-only mount" >&2
    exit 1
fi
echo "  (write correctly rejected)"

echo "==> mount info"
mount | grep -E "fused|myfs" || { echo "FAIL: fused/myfs not in mount table" >&2; exit 1; }

echo "==> libfuse debug log highlights"
grep -E 'LOOKUP|OPEN|READ|getattr|readdir' $LOG | head -10

echo
echo "==> All smoke tests passed."
