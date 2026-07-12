#!/usr/bin/env bash
# check_context.sh — Verify that every "c" proc in ops.odin sets
# both `context = runtime.default_context()` and `context.logger = g_logger`
# in its first non-blank body lines.
set -euo pipefail

cd "$(dirname "$0")/.."

src=src/mounter/ops.odin
echo "==> Auditing \"c\" proc callbacks in $src for context + logger restoration"

python3 - "$src" <<'PY'
import re, sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
lines = text.splitlines()

proc_re = re.compile(r'proc "c"\s*\(')
ctx_re = re.compile(r'context\s*=\s*runtime\.default_context')
log_re = re.compile(r'context\.logger\s*=\s*g_logger')
fail = 0
checked = 0
i = 0
while i < len(lines):
    m = proc_re.search(lines[i])
    if not m:
        i += 1
        continue
    name_match = re.search(r'(\w+)\s*::', lines[i])
    if not name_match:
        i += 1
        continue
    name = name_match.group(1)
    j = i
    while j < len(lines) and '{' not in lines[j]:
        j += 1
    if j >= len(lines):
        print(f"  SKIP {name} (no opening brace found)")
        i = j
        continue
    body = []
    k = j + 1
    line_with_brace = lines[j]
    brace_idx = line_with_brace.index('{')
    if brace_idx + 1 < len(line_with_brace):
        rest = line_with_brace[brace_idx + 1:].strip()
        if rest and not rest.startswith('//'):
            body.append(rest)
    while k < len(lines) and len(body) < 3:
        stripped = lines[k].strip()
        if stripped and not stripped.startswith('//'):
            body.append(stripped)
        k += 1
    body_text = '\n'.join(body)
    has_ctx = bool(ctx_re.search(body_text))
    has_log = bool(log_re.search(body_text))
    if has_ctx and has_log:
        print(f"  OK   {name:22s} ctx=yes log=yes")
        checked += 1
    elif has_ctx and not has_log:
        print(f"  FAIL {name:22s} ctx=yes log=no  (missing context.logger = g_logger)")
        fail += 1
    elif not has_ctx and has_log:
        print(f"  FAIL {name:22s} ctx=no  log=yes  (logger set without context restore)")
        fail += 1
    else:
        print(f"  FAIL {name:22s} ctx=no  log=no  (both missing)")
        fail += 1
    i = k

print()
print(f"==> {checked} callback(s) OK, {fail} callback(s) missing context/logger restoration")
if fail:
    sys.exit(1)
PY
