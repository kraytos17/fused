#!/usr/bin/env bash
# check_sizes.sh — Cross-check Odin binding struct sizes against C ground truth.
#
# Runs tests/c_assert.c (C side) and tests/size_check.odin (Odin side), then
# diffs the sizes struct-by-struct. Fails the build on any mismatch.
set -euo pipefail

cd "$(dirname "$0")/.."

C_BIN=/tmp/c_assert
C_SRC=tests/c_assert.c

cleanup() {
    rm -f /tmp/c_sizes.txt /tmp/odin_sizes.txt /tmp/c_pairs.txt /tmp/odin_pairs.txt /tmp/size_check_bin
}
trap cleanup EXIT

echo "==> Compiling C ground truth ($C_SRC)"
if [ ! -x "$C_BIN" ] || [ "$C_SRC" -nt "$C_BIN" ]; then
    cc "$C_SRC" $(pkg-config --cflags fuse3) -o "$C_BIN"
fi
"$C_BIN" > /tmp/c_sizes.txt
sed -n '1,15p' /tmp/c_sizes.txt

echo
echo "==> Running Odin size check (tests/size_check.odin)"
odin run tests/size_check.odin -file -collection:src=src -out:/tmp/size_check_bin > /tmp/odin_sizes.txt
cat /tmp/odin_sizes.txt

echo
echo "==> Cross-checking struct sizes"

declare -A C_TO_ODIN=(
    [stat]="Stat"
    [fuse_file_info]="File_Info"
    [fuse_operations]="Operations"
    [fuse_conn_info]="Conn_Info"
    [fuse_config]="Config"
    [fuse_loop_config_v1]="Loop_Config"
    [fuse_context]="Context"
    [libfuse_version]="Libfuse_Version"
    [fuse_args]="Args"
    [fuse_opt]="Opt"
    [fuse_buf]="Buf"
    [fuse_bufvec]="Bufvec"
)

grep -E '^  sizeof\(struct ' /tmp/c_sizes.txt | \
    sed -nE 's/^  sizeof\(struct ([a-z_]+)\).* ([0-9]+)$/\1 \2/p' \
    > /tmp/c_pairs.txt

grep -E '^  [A-Za-z_]+[[:space:]]+=' /tmp/odin_sizes.txt | \
    sed -nE 's/^  ([A-Za-z_]+).* ([0-9]+)$/\1 \2/p' \
    > /tmp/odin_pairs.txt

fail=0
checked=0
while read -r c_name c_val; do
    odin_name="${C_TO_ODIN[$c_name]:-}"
    if [ -z "$odin_name" ]; then
        printf "  SKIP %-22s  (no Odin mapping for struct %s)\n" "$c_name" "$c_name"
        continue
    fi
    o_val=$(awk -v n="$odin_name" '$1 == n {print $2; exit}' /tmp/odin_pairs.txt)
    if [ -z "$o_val" ]; then
        printf "  SKIP %-22s  (Odin struct %s not present in output)\n" "$c_name" "$odin_name"
        continue
    fi
    if [ "$c_val" = "$o_val" ]; then
        printf "  OK  %-12s <-> %-18s = %s\n" "$c_name" "$odin_name" "$c_val"
        checked=$((checked + 1))
    else
        printf "  FAIL %-12s <-> %-18s  C=%s  Odin=%s\n" "$c_name" "$odin_name" "$c_val" "$o_val"
        fail=1
    fi
done < /tmp/c_pairs.txt

echo
printf "==> %d struct(s) checked.\n" "$checked"
if [ "$fail" -eq 0 ]; then
    echo "==> All checked struct sizes match."
else
    echo "==> MISMATCH: struct sizes diverge between C and Odin." >&2
    exit 1
fi
