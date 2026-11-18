#!/usr/bin/env bash
# tests/conformance/fsx.sh — file-op exerciser baseline (T-02).
#
# Usage:
#   tests/conformance/fsx.sh [what...]   # default: fsx fsstress
#
# Tools (build once; override via env):
#   LTP_SRC default /tmp/opencode/ltp-full (needs configure + lib + the
#   two test dirs built; see header of this file). FSX_BIN / FSSTRESS_BIN
#   default to $LTP_SRC/testcases/kernel/fs/{fsx-linux,fsstress}/...
#   Build recipe:
#     git clone https://github.com/linux-test-project/ltp.git
#     cd ltp && autoreconf -fiv && ./configure --without-numa
#     make -C lib -j4
#     make -C testcases/kernel/fs/fsx-linux -j4
#     make -C testcases/kernel/fs/fsstress -j4
#
# Method: fresh 16M image per tool, mount, run, unmount, then
# `build/check` the image (any exerciser bug must show up there).
#   fsx-linux: -N 20000 content-oracle runs x3 (NOTE: LTP's rewrite seeds
#     srandom(time(NULL)) — no seed flag. Repeat runs cover the gap until
#     we vendor a seedable fsx; see expected file).
#   fsstress: -n 1000 -p 4 for seeds 1 2 3 (deterministic via -s).
# Logs land in logs/fsx-<tool>[-<seed>].log; exit 1 if any tool fails
# (failures are baseline data — see fsx_baseline.txt).
set -euo pipefail

LTP_SRC="${LTP_SRC:-/tmp/opencode/ltp-full}"
FSX_BIN="${FSX_BIN:-$LTP_SRC/testcases/kernel/fs/fsx-linux/fsx-linux}"
FSSTRESS_BIN="${FSSTRESS_BIN:-$LTP_SRC/testcases/kernel/fs/fsstress/fsstress}"
FUSED_BIN="${FUSED_BIN:-build/fused}"
FORMAT_BIN="${FORMAT_BIN:-build/format}"
CHECK_BIN="${CHECK_BIN:-build/check}"
ROOT="$(git rev-parse --show-toplevel)"
IMG="${FSX_IMAGE:-/dev/shm/fused_fsx.img}"
MNT="${FSX_MOUNT:-/dev/shm/fused_fsx_mnt}"
LOGS="$ROOT/logs"
WHAT=("${@:-fsx fsstress}")

for b in "$FSX_BIN" "$FSSTRESS_BIN"; do
  [ -x "$b" ] || { echo "missing tool: $b (see header build recipe)" >&2; exit 2; }
done

mount_fused() {
  "$ROOT/$FORMAT_BIN" --force --size=16M --output="$IMG" >/dev/null
  mkdir -p "$MNT" "$LOGS"
  if mountpoint -q "$MNT"; then fusermount3 -uz "$MNT" 2>/dev/null || true; fi
  "$ROOT/$FUSED_BIN" --log-level=warn "$IMG" -f "$MNT" >"$LOGS/fsx_fused.log" 2>&1 &
  DAEMON=$!
  for i in $(seq 1 50); do
    if mountpoint -q "$MNT"; then break; fi
    sleep 0.1
  done
  mountpoint -q "$MNT" || { echo "mount failed; see $LOGS/fsx_fused.log" >&2; return 1; }
}

unmount_fused() {
  kill "${DAEMON:-}" 2>/dev/null || true
  fusermount3 -uz "$MNT" 2>/dev/null || true
}

check_image() {
  # $1 = log path to append the check summary to
  "$ROOT/$CHECK_BIN" --log-level=warn "$IMG" >>"$1" 2>&1 && echo "check: clean" >>"$1" || echo "check: DIRTY (see above)" >>"$1"
}

overall=0
trap 'unmount_fused' EXIT

if [[ " ${WHAT[*]} " == *" fsx "* ]]; then
  mount_fused
  # LTP makes its tmpdir under $TMPDIR: point it at the mount so the
  # exercised file lives on fused, not /tmp.
  mkdir -p "$MNT/ltp-tmp"
  for i in 1 2 3; do
    log="$LOGS/fsx-fsxlinux-$i.log"
    echo "==> fsx-linux run $i (log $log)"
    # NOTE: LTP exit codes OR in warning bits (e.g. unadjustable oom score
    # in containers), so the verdict is parsed from output: any TFAIL/TBROK
    # fails; a clean TPASS passes even with TWARN noise.
    set +e
    TMPDIR="$MNT/ltp-tmp" "$FSX_BIN" -N 20000 >"$log" 2>&1
    set -e
    if grep -qE "TFAIL|TBROK" "$log"; then
      echo "    FAIL fsx-linux run $i (see $log)"
      overall=1
    elif grep -q "TPASS" "$log"; then
      echo "    PASS fsx-linux run $i"
    else
      echo "    FAIL fsx-linux run $i (no TPASS in $log)"
      overall=1
    fi
  done
  unmount_fused
  trap - EXIT
  check_image "$LOGS/fsx-fsxlinux-check.log"
  trap 'unmount_fused' EXIT
fi

if [[ " ${WHAT[*]} " == *" fsstress "* ]]; then
  for seed in 1 2 3; do
    log="$LOGS/fsx-fsstress-$seed.log"
    echo "==> fsstress seed $seed (log $log)"
    mount_fused
    if "$FSSTRESS_BIN" -d "$MNT" -n 1000 -p 4 -s "$seed" >"$log" 2>&1; then
      echo "    PASS fsstress seed $seed"
    else
      echo "    FAIL fsstress seed $seed (see $log)"
      overall=1
    fi
    unmount_fused
    trap - EXIT
    check_image "$log"
    trap 'unmount_fused' EXIT
  done
fi

trap - EXIT
echo "fsx_seed_note=LTP fsx-linux srandom(time(NULL)); fsstress -s seeds 1 2 3"
exit "$overall"
