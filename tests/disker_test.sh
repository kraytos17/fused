#!/usr/bin/env bash
# disker_test.sh — Integration tests for the disker and imgdump tools.
set -uo pipefail

cd "$(dirname "$0")/.."

ROOT=$(pwd)
BUILD_DIR=$ROOT/build
TEST_DIR=/dev/shm/fused_disktest
mkdir -p "$TEST_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT

DISKER=$BUILD_DIR/disker
IMGDUMP=$BUILD_DIR/imgdump

pass() { PASS=$((PASS + 1)); echo "  PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1${2:+: $2}"; }

echo "==> Building tools"
rm -f "$DISKER" "$IMGDUMP"
odin build src/disker -collection:src=src -out:$DISKER -o:none -warnings-as-errors -use-separate-modules 2>&1 || exit 1
odin build tools/imgdump -collection:src=src -out:$IMGDUMP -o:none -warnings-as-errors -use-separate-modules 2>&1 || exit 1
test -x "$DISKER" || { echo "  FAIL: disker binary missing"; exit 1; }
test -x "$IMGDUMP" || { echo "  FAIL: imgdump binary missing"; exit 1; }

PASS=0; FAIL=0

echo
echo "=== Disker Tests ==="

# 1
I=$TEST_DIR/01.img; "$DISKER" --force --output="$I" >/dev/null 2>&1
S=$(stat -c%s "$I" 2>/dev/null)
[ "$S" = "1048576" ] && pass "default-format" || fail "default-format" "size=$S"

# 2
I=$TEST_DIR/02.img; "$DISKER" --force --output="$I" --size=4M >/dev/null 2>&1
S=$(stat -c%s "$I"); [ "$S" = "$((4*1024*1024))" ] && pass "custom-size-4M" || fail "custom-size-4M" "size=$S"

# 3
I=$TEST_DIR/03.img; "$DISKER" --force --output="$I" --size=8M --cluster-size=64 >/dev/null 2>&1
S=$(stat -c%s "$I"); [ "$S" = "$((8*1024*1024))" ] && pass "custom-cluster-64" || fail "custom-cluster-64" "size=$S"

# 4
I=$TEST_DIR/04.img; "$DISKER" --force "$I" >/dev/null 2>&1
test -f "$I" && pass "positional-output" || fail "positional-output"

# 5
"$DISKER" --help 2>&1 | grep -aq "Usage: disker" && pass "help" || fail "help"

# 6 — force-guard: expect exit 1
I=$TEST_DIR/06.img; "$DISKER" --force --output="$I" >/dev/null 2>&1
set +e; "$DISKER" --output="$I" >/dev/null 2>&1; rc=$?; set -e
[ $rc -eq 1 ] && pass "force-guard" || fail "force-guard" "exit $rc"

# 7 — size validation: expect non-zero exit
set +e; "$DISKER" --force --output="$TEST_DIR/07.img" --size=1K >/dev/null 2>&1; rc=$?; set -e
[ $rc -eq 1 ] && pass "size-validation" || fail "size-validation" "exit $rc"

# 8
I=$TEST_DIR/08.img; "$DISKER" --force --output="$I" >/dev/null 2>&1
set +e; "$IMGDUMP" "$I" >/dev/null 2>&1; rc=$?; set -e
[ $rc -eq 0 ] && pass "imgdump-readable" || fail "imgdump-readable" "exit $rc"

echo
echo "=== Imgdump Tests ==="

I=$TEST_DIR/09.img; "$DISKER" --force --output="$I" >/dev/null 2>&1

# 9
if ! test -f "$I"; then fail "shows-master" "no file $I"; else
  SIZE=$(wc -c < "$I")
  if ! "$IMGDUMP" "$I" > /tmp/fused_dump.txt 2>/dev/null; then fail "shows-master" "imgdump failed"; else
    grep -aq "MasterRecord" /tmp/fused_dump.txt && pass "shows-master" || fail "shows-master" "MasterRecord not found in dump ($SIZE byte image)"
  fi
fi

# 10
grep -aq "ALLOCATED" /tmp/fused_dump.txt && pass "shows-clusters" || fail "shows-clusters"

# 11
"$IMGDUMP" "$I" 2>/dev/null | grep -aq "Kernel" && pass "shows-kernel" || fail "shows-kernel"

# 12
JSON=$("$IMGDUMP" --json "$I" 2>/dev/null)
echo "$JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['master']['rev'] == 4
assert d['master']['cluster_size'] == 16
assert 'Kernel' in d['root']
assert d['root']['Kernel']['kind'] == 'FILE'
assert d['root']['Kernel']['size'] == 60
" && pass "json-validates" || fail "json-validates"

# 13
"$IMGDUMP" --hex=/Kernel "$I" 2>/dev/null | grep -q "Kernel" && pass "hex-shows-name" || fail "hex-shows-name"

# 14
set +e; "$IMGDUMP" --hex=/ "$I" > /tmp/fused_hex.txt 2>&1; rc=$?; set -e
[ $rc -eq 1 ] && pass "hex-dir-error" || fail "hex-dir-error" "exit $rc"
grep -aq "is a directory" /tmp/fused_hex.txt && pass "hex-dir-error-msg" || fail "hex-dir-error-msg"

# 15
"$IMGDUMP" --help 2>&1 | grep -q "Usage: imgdump" && pass "help-text" || fail "help-text"

# 16 — missing path: expect exit 1
set +e; "$IMGDUMP" >/dev/null 2>&1; rc=$?; set -e
[ $rc -eq 1 ] && pass "missing-path-exit" || fail "missing-path-exit" "exit $rc"

# 17 — invalid path: expect exit 1
set +e; "$IMGDUMP" /nonexistent >/dev/null 2>&1; rc=$?; set -e
[ $rc -eq 1 ] && pass "invalid-path-exit" || fail "invalid-path-exit" "exit $rc"

echo
echo "=== Cross-Tool Validation ==="

I=$TEST_DIR/18.img; "$DISKER" --force --output="$I" --size=2M --cluster-size=32 >/dev/null 2>&1

# 18
JSON=$("$IMGDUMP" --json "$I" 2>/dev/null)
echo "$JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['master']['cluster_size'] == 32
assert d['master']['cluster_map_size'] == 128
assert d['allocated'] == 1
" && pass "cross-validate" || fail "cross-validate"

# 19
JSON=$("$IMGDUMP" --json "$I" 2>/dev/null)
SZ=$(echo "$JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['root']['Kernel']['size'])")
LINES=$("$IMGDUMP" --hex=/Kernel "$I" 2>/dev/null | wc -l)
[ "$LINES" = "$(( (SZ + 15) / 16 ))" ] && pass "hex-size" || fail "hex-size" "got $LINES want $(( (SZ + 15) / 16 ))"

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
