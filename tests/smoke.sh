#!/usr/bin/env bash
# smoke.sh — End-to-end smoke test for the fused FUSE daemon.
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="${1:-fused.img}"
MOUNT=mnt
LOG=logs/fused_smoke.log
FUSE_OUT=logs/fused_fuse.log
BUILD_DIR="${BUILD_DIR:-build}"
BIN="${BIN:-$BUILD_DIR/fused}"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1${2:+: $2}"; }

FUSE_PID=
cleanup() {
    if [ -n "$FUSE_PID" ] && kill -0 "$FUSE_PID" 2>/dev/null; then
        kill -9 "$FUSE_PID" 2>/dev/null || true
    fi
    fusermount3 -uz "$MOUNT" 2>/dev/null || true
}
trap cleanup EXIT; trap 'exit 1' INT TERM

cleanup; rm -rf "$MOUNT" "$LOG" "$FUSE_OUT"; mkdir -p "$MOUNT" logs

[ -x "$BIN" ] || { fail "binary" "$BIN not executable"; exit 1; }
[ -f "$IMAGE" ] || { fail "image" "$IMAGE not found"; exit 1; }

echo "==> Starting $BIN $IMAGE -f -d $MOUNT"
"$BIN" "$IMAGE" -f -d "$MOUNT" >"$FUSE_OUT" 2>&1 &
FUSE_PID=$!; sleep 0.3
for i in $(seq 1 50); do if mountpoint -q "$MOUNT" 2>/dev/null; then break; fi; sleep 0.1; done
mountpoint -q "$MOUNT" || { fail "mount" "did not appear"; cat "$FUSE_OUT"; exit 1; }

MP="$MOUNT"

echo; echo "== basic read =="
ls "$MP" | grep -q "Kernel" && pass "ls" || fail "ls"
[ "$(stat -c '%a' "$MP/Kernel")" = "644" ] && pass "mode 644" || fail "mode 644"
[ "$(stat -c '%s' "$MP/Kernel")" = "60"  ] && pass "size 60"  || fail "size 60"
head -c4 "$MP/Kernel" | od -tx1 -An | tr -d ' \n' | grep -q "82000d00" && pass "header" || fail "header"

echo; echo "== basic write =="
echo "hello_fuse" > "$MP/write_test"
[ "$(cat "$MP/write_test")" = "hello_fuse" ] && pass "write+read" || fail "write+read"
rm "$MP/write_test" && pass "unlink" || fail "unlink"

echo; echo "== multi-sector =="
dd if=/dev/urandom bs=512 count=3 of="$MP/multi" 2>/dev/null
[ "$(stat -c%s "$MP/multi")" -ge 1500 ] && pass "size" || fail "size"
rm "$MP/multi" && pass "unlink" || fail "unlink"

echo; echo "== subdir =="
mkdir -p "$MP/subdir/a/b"
echo "deep" > "$MP/subdir/a/b/f"
[ "$(cat "$MP/subdir/a/b/f")" = "deep" ] && pass "nested" || fail "nested"
rm "$MP/subdir/a/b/f" && rmdir "$MP/subdir/a/b" "$MP/subdir/a" "$MP/subdir" && pass "rmdirs" || fail "rmdirs"

echo; echo "== statfs =="
df "$MP" 2>&1 | grep -q "fused" && pass "df" || fail "df"
python3 -c "import os; s=os.statvfs('$MP'); assert s.f_bsize > 0;" && pass "statvfs" || fail "statvfs"

echo; echo "== mount info =="
mount | grep -E "fused" && pass "mount table" || fail "mount table"
grep -E 'LOOKUP|OPEN|READ|GETATTR' "$FUSE_OUT" 2>/dev/null | head -6 >/dev/null && pass "FUSE ops" || fail "FUSE ops"

echo; echo "=== smoke: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
