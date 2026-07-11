#!/usr/bin/env bash
# check_context.sh — Verify that every "c" proc in main.odin sets
# `context = runtime.default_context()` as its first non-blank line.
#
# This is a silent-bug class: the absence of context restoration crashes
# any Odin proc call (fmt.println, new, map access) from inside the
# callback, since "c" procs receive no implicit Odin context from libfuse.
set -euo pipefail

cd "$(dirname "$0")/.."

src=src/mounter/main.odin
echo "==> Auditing \"c\" proc callbacks in $src for context restoration"

# For every `proc "c"` header, print the next 5 lines (the body start)
# and the proc name, then check whether `context = runtime.default_context()`
# appears among those lines.
fail=0
checked=0
python3 - "$src" <<'PY'
import re, sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
lines = text.splitlines()

# Find every "proc \"c\"" declaration, extract the proc name, then scan
# forward up to the next blank-line-free opening '{' and the first 3
# non-blank body lines.
proc_re = re.compile(r'proc "c"\s*\(')
ctx_re = re.compile(r'context\s*=\s*runtime\.default_context')
fail = 0
checked = 0
i = 0
while i < len(lines):
    m = proc_re.search(lines[i])
    if not m:
        i += 1
        continue
    # Extract name: everything on this line before "::"
    name_match = re.search(r'(\w+)\s*::', lines[i])
    if not name_match:
        i += 1
        continue
    name = name_match.group(1)
    # Find the opening '{' for the body (could be on the same line as
    # the proc declaration if the proc is on one line, e.g.
    # `name :: proc "c"(...) -> T {`).
    j = i
    while j < len(lines) and '{' not in lines[j]:
        j += 1
    if j >= len(lines):
        print(f"  SKIP {name} (no opening brace found)")
        i = j
        continue
    # Collect first 3 non-blank, non-comment lines after '{'
    body = []
    k = j + 1
    # Also include the rest of the line with '{' in case context is there
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
    if ctx_re.search(body_text):
        print(f"  OK   {name}")
        checked += 1
    else:
        print(f"  FAIL {name}  (no `context = runtime.default_context()` in first 3 non-blank body lines)")
        print(f"       body was: {body_text!r}")
        fail += 1
    i = k

print()
print(f"==> {checked} callback(s) OK, {fail} callback(s) missing context restoration")
if fail:
    sys.exit(1)
PY
