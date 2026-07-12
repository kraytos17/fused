#!/usr/bin/env bash
# smoke.sh — End-to-end smoke test for the fused FUSE daemon.
#
# Mounts a fused.img, exercises ls/cat/stat, verifies read+write,
# and unmounts cleanly.  Uses lazy unmount (-uz) to clear stale state.
#
# Usage: tests/smoke.sh [image-path] [mountpoint]
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="${1:-fused.img}"
MOUNT="${2:-mnt}"
LOG=logs/fused_smoke.log
FUSE_OUT=logs/fused_fuse.log
BUILD_DIR="${BUILD_DIR:-build}"
BIN="${BIN:-$BUILD_DIR/fused}"

FUSE_PID=
fusermount3 -uz "$MOUNT" 2>/dev/null || true
trap cleanup EXIT
trap 'exit 1' INT TERM

cleanup() {
    rm -f logs/fused_smoke_hex
    if [ -n "$FUSE_PID" ] && kill -0 "$FUSE_PID" 2>/dev/null; then
        kill -9 "$FUSE_PID" 2>/dev/null || true
    fi
    fusermount3 -uz "$MOUNT" 2>/dev/null || true
}

echo "==> Using binary: $BIN, image: $IMAGE, mount: $MOUNT"
[ -x "$BIN" ]   || { echo "FAIL: $BIN not executable; run 'make build' first"   >&2; exit 1; }
[ -f "$IMAGE" ] || { echo "FAIL: $IMAGE not found; run 'make run-disker' first" >&2; exit 1; }

echo "==> Cleaning up any stale mount"
fusermount3 -uz "$MOUNT" 2>/dev/null || true
rm -rf "$MOUNT"
mkdir -p "$MOUNT" logs

echo "==> Starting $BIN $IMAGE -f -d $MOUNT"
"$BIN" "$IMAGE" -f -d "$MOUNT" >"$FUSE_OUT" 2>&1 &
# stdout=Odin logs, stderr=FUSE -d debug — both go to same file via 2>&1
FUSE_PID=$!
sleep 0.3

REAL_PID=$(pgrep -f "fused.*-d $MOUNT" 2>/dev/null | head -1) || true
if [ -n "$REAL_PID" ]; then FUSE_PID="$REAL_PID"; fi

for i in $(seq 1 50); do
    if mountpoint -q "$MOUNT" 2>/dev/null; then break; fi
    sleep 0.1
done

if ! mountpoint -q "$MOUNT" 2>/dev/null; then
    echo "FAIL: mount did not appear in time" >&2
    cat "$FUSE_OUT" >&2
    exit 1
fi

echo "==> ls $MOUNT"
listing=$(ls "$MOUNT")
echo "$listing"
echo "$listing" | grep -q "Kernel" || { echo "FAIL: expected 'Kernel' in ls, got '$listing'" >&2; exit 1; }

echo "==> stat $MOUNT/Kernel"
mode=$(stat -c '%a' "$MOUNT/Kernel")
size=$(stat -c '%s' "$MOUNT/Kernel")
echo "  mode=$mode size=$size"
[ "$mode" = "444" ] || { echo "FAIL: expected mode 444, got $mode" >&2; exit 1; }
[ "$size" = "60"  ] || { echo "FAIL: expected size 60, got $size" >&2; exit 1; }

echo "==> cat $MOUNT/Kernel (first 4 bytes)"
head -c 4 "$MOUNT/Kernel" | od -tx1 -An | tr -d ' \n' > logs/fused_smoke_hex
expected_hex="82000d00"
got_hex=$(cat logs/fused_smoke_hex)
[ "$got_hex" = "$expected_hex" ] || { echo "FAIL: expected $expected_hex, got $got_hex" >&2; exit 1; }
echo "  $got_hex (matches expected)"

echo "==> write test (should succeed — filesystem is read-write)"
echo "smoke_write_test" > "$MOUNT/smoke_test_file"
content=$(cat "$MOUNT/smoke_test_file")
[ "$content" = "smoke_write_test" ] || { echo "FAIL: write+read mismatch" >&2; exit 1; }
rm "$MOUNT/smoke_test_file"
echo "  (write+read OK)"

echo "==> mount info"
mount | grep -E "fused" || { echo "FAIL: fused not in mount table" >&2; exit 1; }

echo "==> libfuse debug log highlights"
grep -E 'LOOKUP|OPEN|READ|GETATTR' "$FUSE_OUT" | head -8

echo
echo "==> All smoke tests passed."
