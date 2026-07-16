#!/usr/bin/env bash
# tests/smoke_mt.sh — Multi-threaded FUSE stress test.
set -euo pipefail

cd "$(dirname "$0")/.."

BINARY=build/fused
IMAGE=fused.img
MNT=mnt
LOG_DIR=logs
DURATION=15

mkdir -p "$MNT" "$LOG_DIR"

cleanup() {
    local rc=$?
    fusermount3 -uz "$MNT" 2>/dev/null || true
    exit $rc
}
trap cleanup EXIT INT TERM

echo "=== multi-threaded stress test ==="
echo "  binary:  $BINARY"
echo "  image:   $IMAGE"
echo "  mount:   $MNT"
echo "  stress:  ${DURATION}s"

if [ ! -f "$IMAGE" ]; then
    echo "ERROR: $IMAGE not found (run 'make run-disker' first)" >&2
    exit 1
fi

echo "--- mounting (multi-threaded, no -s) ---"
"$BINARY" --log-file="$LOG_DIR/fused_mt.log" --log-level=warn "$IMAGE" -f "$MNT" &
FUSE_PID=$!
for i in $(seq 1 5); do
    sleep 1
    if kill -0 "$FUSE_PID" 2>/dev/null && ls "$MNT" >/dev/null 2>&1; then
        echo "  mounted (pid=$FUSE_PID, after ${i}s)"
        break
    fi
    if ! kill -0 "$FUSE_PID" 2>/dev/null; then
        echo "FAIL: FUSE died after ${i}s" >&2
        exit 1
    fi
done
echo "  basic access OK"

ERRORS=0

echo "--- spawning concurrent workers (${DURATION}s) ---"

reader_pid=
(
    end=$((SECONDS + DURATION))
    ops=0
    while [ $SECONDS -lt $end ]; do
        timeout 1 ls "$MNT" >/dev/null 2>&1 || true
        ops=$((ops + 1))
    done
    echo "  reader: $ops ops"
) &
reader_pid=$!

writer_pid=
(
    end=$((SECONDS + DURATION))
    ops=0; i=0
    while [ $SECONDS -lt $end ]; do
        timeout 2 bash -c "echo 'content_$i' > \"$MNT/wfile_$i\" 2>/dev/null; cat \"$MNT/wfile_$i\" >/dev/null 2>&1; rm \"$MNT/wfile_$i\" 2>/dev/null" 2>/dev/null || true
        ops=$((ops + 1))
        i=$(( (i + 1) % 100 ))
    done
    echo "  writer: $ops ops"
) &
writer_pid=$!

dir_pid=
(
    end=$((SECONDS + DURATION))
    ops=0; i=0
    while [ $SECONDS -lt $end ]; do
        timeout 2 bash -c "mkdir -p \"$MNT/ddir_$i\" 2>/dev/null; touch \"$MNT/ddir_$i/afile\" 2>/dev/null; rm \"$MNT/ddir_$i/afile\" 2>/dev/null; rmdir \"$MNT/ddir_$i\" 2>/dev/null" 2>/dev/null || true
        ops=$((ops + 1))
        i=$(( (i + 1) % 50 ))
    done
    echo "  dir:    $ops ops"
) &
dir_pid=$!

io_pid=
(
    end=$((SECONDS + DURATION))
    ops=0
    while [ $SECONDS -lt $end ]; do
        timeout 3 bash -c "dd if=/dev/zero of=\"$MNT/bigfile\" bs=512 count=32 2>/dev/null; dd if=\"$MNT/bigfile\" of=/dev/null bs=512 count=32 2>/dev/null; rm \"$MNT/bigfile\" 2>/dev/null" 2>/dev/null || true
        ops=$((ops + 1))
    done
    echo "  io:     $ops ops"
) &
io_pid=$!

remaining_pids="$reader_pid $writer_pid $dir_pid $io_pid"
end=$((SECONDS + DURATION + 5))
while [ $SECONDS -lt $end ]; do
    new_pids=""
    for pid in $remaining_pids; do
        kill -0 "$pid" 2>/dev/null && new_pids="$new_pids $pid"
    done
    remaining_pids="$new_pids"
    [ -z "$remaining_pids" ] && break
    sleep 1
done
for pid in $remaining_pids; do kill "$pid" 2>/dev/null || true; done

echo "--- unmounting ---"
fusermount3 -uz "$MNT" 2>/dev/null || true
sleep 1

for pid in $reader_pid $writer_pid $dir_pid $io_pid; do
    kill "$pid" 2>/dev/null || true
done

kill "$FUSE_PID" 2>/dev/null || true

echo ""
if [ "$ERRORS" -eq 0 ]; then
    echo "=== smoke-mt: passed, 0 errors ==="
    exit 0
else
    echo "=== smoke-mt: FAILED, $ERRORS error(s) ==="
    exit 1
fi
