#!/usr/bin/env bash
# tests/conformance/pjdfstest.sh — POSIX conformance baseline (T-01).
#
# Usage:
#   tests/conformance/pjdfstest.sh [group...]   # default: chmod mkdir rename
#   PJD_GROUPS="chmod open" tests/conformance/pjdfstest.sh
#
# Pins pjdfstest at $PJD_COMMIT (override PJD_SRC to reuse an existing
# checkout). Formats a fresh 16M image, mounts fused inside the current
# (already unshared) mount namespace, runs `prove -r` per group with cwd
# on the mount, then unmounts. Per-group logs land in logs/pjdfstest-<group>.log.
# Exit 0 always on harness success (test failures are data, not harness
# errors); the caller diffs against expected_failures.txt.
set -euo pipefail

PJD_COMMIT="${PJD_COMMIT:-85a8aea9e685999ef0540392fd80535f873d7ff7}"
PJD_SRC="${PJD_SRC:-/tmp/opencode/pjdfstest}"
FUSED_BIN="${FUSED_BIN:-build/fused}"
FORMAT_BIN="${FORMAT_BIN:-build/format}"
ROOT="$(git rev-parse --show-toplevel)"
IMG="${PJD_IMAGE:-/dev/shm/fused_pjd.img}"
MNT="${PJD_MOUNT:-/dev/shm/fused_pjd_mnt}"
LOGS="$ROOT/logs"
PJD_GROUPS="${PJD_GROUPS:-chmod mkdir rename}"
read -r -a PJD_GROUP_LIST <<< "${@:-$PJD_GROUPS}"

if [ ! -x "$PJD_SRC/pjdfstest" ]; then
  echo "pjdfstest binary missing at $PJD_SRC/pjdfstest" >&2
  echo "clone + build first:" >&2
  echo "  git clone https://github.com/pjd/pjdfstest.git <dir>" >&2
  echo "  cd <dir> && git checkout $PJD_COMMIT && autoreconf -ifs && ./configure && make pjdfstest" >&2
  exit 2
fi
actual="$(git -C "$PJD_SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
if [ "$actual" != "$PJD_COMMIT" ]; then
  echo "WARN: pjdfstest checkout $actual != pinned $PJD_COMMIT" >&2
fi

"$ROOT/$FORMAT_BIN" --force --size=16M --output="$IMG" >/dev/null
mkdir -p "$MNT" "$LOGS"
if mountpoint -q "$MNT"; then fusermount3 -uz "$MNT" 2>/dev/null || true; fi

"$ROOT/$FUSED_BIN" --log-level=warn "$IMG" -f "$MNT" >"$LOGS/pjdfstest_fused.log" 2>&1 &
DAEMON=$!
cleanup() { kill "$DAEMON" 2>/dev/null || true; fusermount3 -uz "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

for i in $(seq 1 50); do
  if mountpoint -q "$MNT"; then break; fi
  sleep 0.1
done
mountpoint -q "$MNT" || { echo "mount failed; see $LOGS/pjdfstest_fused.log" >&2; exit 1; }

export PATH="$PJD_SRC:$PATH"
overall=0
for g in "${PJD_GROUP_LIST[@]}"; do
  log="$LOGS/pjdfstest-$g.log"
  echo "==> group $g (log $log)"
  if ( cd "$MNT" && prove -r "$PJD_SRC/tests/$g" >"$log" 2>&1 ); then
    echo "    PASS $g"
  else
    echo "    FAIL $g (see $log)"
    overall=1
  fi
done
echo "pjd_commit=$PJD_COMMIT"
exit "$overall"
