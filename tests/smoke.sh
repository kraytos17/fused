#!/usr/bin/env bash
# smoke.sh — End-to-end smoke test for the fused FUSE daemon.
#
# Mounts a fused.img, exercises ls/cat/stat, verifies read-only
# nature, and unmounts cleanly.
#
# Usage: tests/smoke.sh [image-path] [mountpoint]
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="${1:-fused.img}"
MOUNT="${2:-/tmp/mnt}"
LOG=/tmp/fused_smoke.log
BUILD_DIR="${BUILD_DIR:-build}"
BIN="${BIN:-$BUILD_DIR/fused}"

echo "==> Using binary: $BIN, image: $IMAGE, mount: $MOUNT"
[ -x "$BIN" ]   || { echo "FAIL: $BIN not executable; run 'make build' first"   >&2; exit 1; }
[ -f "$IMAGE" ] || { echo "FAIL: $IMAGE not found; run 'make run-disker' first" >&2; exit 1; }

echo "==> Cleaning up any stale mount"
fusermount3 -u $MOUNT 2>/dev/null || true
rm -rf $MOUNT
mkdir -p $MOUNT

echo "==> Starting $BIN $IMAGE -f -d $MOUNT"
$BIN $IMAGE -f -d $MOUNT > $LOG 2>&1 &
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
echo "$listing" | grep -q "Kernel" || { echo "FAIL: expected 'Kernel' in ls, got '$listing'" >&2; exit 1; }

echo "==> stat $MOUNT/Kernel"
mode=$(stat -c '%a' $MOUNT/Kernel)
size=$(stat -c '%s' $MOUNT/Kernel)
echo "  mode=$mode size=$size"
[ "$mode" = "444" ] || { echo "FAIL: expected mode 444, got $mode" >&2; exit 1; }
[ "$size" = "60"  ] || { echo "FAIL: expected size 60, got $size" >&2; exit 1; }

echo "==> cat $MOUNT/Kernel (first 4 bytes)"
head -c 4 $MOUNT/Kernel | od -tx1 -An | tr -d ' \n' > /tmp/fused_smoke_hex
expected_hex="82000d00"
got_hex=$(cat /tmp/fused_smoke_hex)
[ "$got_hex" = "$expected_hex" ] || { echo "FAIL: expected $expected_hex, got $got_hex" >&2; exit 1; }
echo "  $got_hex (matches expected)"

echo "==> write attempt (must fail with read-only filesystem)"
if touch $MOUNT/newfile 2>/dev/null; then
    echo "FAIL: touch succeeded on read-only mount" >&2
    exit 1
fi
echo "  (write correctly rejected)"

echo "==> mount info"
mount | grep -E "fused|myfs" || { echo "FAIL: fused not in mount table" >&2; exit 1; }

echo "==> libfuse debug log highlights"
grep -E 'LOOKUP|OPEN|READ|GETATTR' $LOG | head -8

echo
echo "==> All smoke tests passed."
