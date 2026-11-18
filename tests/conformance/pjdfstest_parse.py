# tests/conformance/pjdfstest_parse.py — shared prove-log + .t parsing.
#
# Both the gate (pjdfstest_check.py) and the baseline generator
# (pjdfstest_baseline.py) import from here so the two can never disagree
# about what a failure is.
#
# Log format required: `prove -v` output. Primary source is TAP:
#   <path>.t ..            file-section header (path as invoked)
#   1..N                   plan (total assertions)
#   ok N [# skip ...]      pass (skip iff a skip marker is present)
#   not ok N ...           failure (trailing text is diagnostic only)
# Backstop from the summary section:
#   <path>.t (Wstat: W Tests: T Failed: F)
#   Failed tests: ...      (plus space-indented continuation lines)
#   Dubious / No plan found / Parse errors / Bad plan / Non-zero exit status
#   Result: PASS|FAIL      (must be present)
"""Shared parsing for pjdfstest logs and test files."""

import os
import re

FILE_HEADER_RE = re.compile(r"^(\S+\.t) \.\. ?$")
TAP_PLAN_RE = re.compile(r"^1\.\.(\d+)\s*$")
TAP_OK_RE = re.compile(r"^ok (\d+)\b(.*)$", re.IGNORECASE)
TAP_NOT_OK_RE = re.compile(r"^not ok (\d+)\b(.*)$")
SKIP_RE = re.compile(r"#\s*skip\b", re.IGNORECASE)
TODO_RE = re.compile(r"#\s*todo\b", re.IGNORECASE)
ENV_FLAG_RE = re.compile(r"(?:^|\s)-[ug]\s+(\d+)")
WSTAT_RE = re.compile(r"^(\S+\.t) \(Wstat: (\d+) Tests: (\d+) Failed: (\d+)\)$")
FAILED_TESTS_RE = re.compile(r"^  Failed tests:\s*(.*)$")
CONTINUATION_RE = re.compile(r"^[ \t]+[\d,\- ]+$")
RESULT_RE = re.compile(r"^Result: (PASS|FAIL)\s*$")
CRASH_MARKERS = (
    "Dubious,",
    "No plan found",
    "Parse errors",
    "Bad plan",
    "Non-zero exit status",
    "Test returned status",
)


def is_env_failure(tried):
    """True if the assertion ran as a non-root user (VFS-denied without
    allow_other, so the daemon never sees it). Ground truth comes from the
    tried command itself: -u/-g with a nonzero id. Static .t analysis
    cannot do this reliably (loops expand assertions at runtime).
    """
    for m in ENV_FLAG_RE.finditer(tried or ""):
        if m.group(1) != "0":
            return True
    return False


def expand_ranges(text):
    """'1-3, 5' -> {1,2,3,5}. Garbage tokens are ignored."""
    out = set()
    for tok in re.split(r"[,\s]+", text):
        if not tok or tok == "-":
            continue
        if "-" in tok:
            try:
                a, b = tok.split("-", 1)
                out.update(range(int(a), int(b) + 1))
            except ValueError:
                continue
        else:
            try:
                out.add(int(tok))
            except ValueError:
                continue
    return out


def format_ranges(nums):
    """{1,2,3,5} -> '1-3, 5' (stable, ascending)."""
    out = []
    for n in sorted(nums):
        if out and n == out[-1][1] + 1:
            out[-1][1] = n
        else:
            out.append([n, n])
    return ", ".join(str(a) if a == b else f"{a}-{b}" for a, b in out)


class FileResult:
    def __init__(self, name):
        self.name = name  # basename, e.g. 00.t
        self.failed = set()  # from TAP not-ok lines (no directive)
        self.todos = set()  # not-ok with # TODO: expected failure
        self.passed = set()  # from TAP ok lines (skip or not)
        self.tried = {}  # test num -> tried-command text (for env split)
        self.skipped = set()  # from TAP ok-with-skip lines
        self.plan = None  # from 1..N header
        self.wstat = None  # from summary Wstat line
        self.summary_tests = None
        self.summary_failed = None
        self.summary_ranges = set()  # from summary Failed-tests lines
        self.crashed = None  # reason string, if any

    @property
    def seen(self) -> set:
        """Assertion numbers with any TAP verdict (completeness check)."""
        return self.failed | self.todos | self.skipped | self.passed


def parse_prove_log(path):
    """Parse a `prove -v` log.

    Returns (files, result, problems):
      files: basename -> FileResult (TAP-derived sets).
      result: 'PASS'/'FAIL'/None (missing Result line).
      problems: harness-level strings (no TAP at all, crashes, count
      drift between TAP and summary).
    """
    files = {}
    order = []
    problems = []
    result = None
    cur = None
    summary_file = None
    in_failed_list = False
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError as e:
        return {}, None, [f"cannot read log: {e}"]
    if not lines:
        return {}, None, ["empty log"]

    def section(name):
        fr = files.get(name)
        if fr is None:
            fr = FileResult(name)
            files[name] = fr
            order.append(name)
        return fr

    for line in lines:
        m = FILE_HEADER_RE.match(line)
        if m:
            cur = section(os.path.basename(m.group(1)))
            in_failed_list = False
            continue
        m = RESULT_RE.match(line)
        if m:
            result = m.group(1)
            in_failed_list = False
            continue
        m = TAP_PLAN_RE.match(line)
        if m and cur is not None and cur.plan is None:
            in_failed_list = False
            try:
                cur.plan = int(m.group(1))
            except ValueError:
                pass
            continue
        m = TAP_NOT_OK_RE.match(line)
        if m and cur is not None:
            in_failed_list = False
            num = int(m.group(1))
            rest = m.group(2)
            # TAP directives: `# SKIP` is a skip, `# TODO` an EXPECTED
            # failure — prove excludes both from its Failed: count, so
            # gating on them would fight the suite's own intent (chown
            # marks Linux SGID/SUID semantics as TODO).
            if SKIP_RE.search(rest):
                cur.skipped.add(num)
            elif TODO_RE.search(rest):
                cur.todos.add(num)
            else:
                cur.failed.add(num)
                cur.tried[num] = rest.strip()
            continue
        m = TAP_OK_RE.match(line)
        if m and cur is not None:
            in_failed_list = False
            cur.passed.add(int(m.group(1)))
            if SKIP_RE.search(m.group(2)):
                cur.skipped.add(int(m.group(1)))
            continue
        m = WSTAT_RE.match(line)
        if m:
            in_failed_list = False
            summary_file = section(os.path.basename(m.group(1)))
            try:
                summary_file.wstat = int(m.group(2))
                summary_file.summary_tests = int(m.group(3))
                summary_file.summary_failed = int(m.group(4))
            except ValueError:
                problems.append(f"{summary_file.name}: unparsable Wstat line")
            continue
        m = FAILED_TESTS_RE.match(line)
        if m and summary_file is not None:
            summary_file.summary_ranges |= expand_ranges(m.group(1))
            in_failed_list = True
            continue
        if in_failed_list and CONTINUATION_RE.match(line) and summary_file is not None:
            summary_file.summary_ranges |= expand_ranges(line)
            continue
        in_failed_list = False
        for marker in CRASH_MARKERS:
            if marker in line:
                if cur is not None:
                    note = line.strip()[:160]
                    cur.crashed = (cur.crashed + "; " if cur.crashed else "") + note
                else:
                    problems.append(f"global crash marker: {line.strip()[:160]}")

    # Reconcile TAP against summary (count backstop + crash detection).
    # NOTE: prove prints a summary Wstat section only when something failed;
    # fully-passing files have TAP data but no summary entry — that is
    # normal, not a crash. A file died mid-run iff its TAP is INCOMPLETE:
    # fewer assertions seen than the plan (or no plan despite assertions).
    for name in order:
        fr = files[name]
        if fr.wstat is None:
            incomplete = (fr.plan is not None and len(fr.seen) < fr.plan) or \
                (fr.plan is None and bool(fr.seen))
            if incomplete:
                fr.crashed = ((fr.crashed + "; ") if fr.crashed else "") + \
                    "no summary Wstat line and TAP incomplete " \
                    f"(plan={fr.plan}, seen={len(fr.seen)}) — prove died or log truncated"
            continue
        if fr.wstat != 0:
            note = f"Wstat={fr.wstat}"
            fr.crashed = ((fr.crashed + "; ") if fr.crashed else "") + note
        if fr.summary_failed is not None and len(fr.failed) != fr.summary_failed:
            problems.append(
                f"{name}: TAP failed={len(fr.failed)} != summary Failed={fr.summary_failed}")
        if fr.summary_tests is not None and fr.plan is not None \
                and fr.summary_tests != fr.plan:
            problems.append(
                f"{name}: TAP plan={fr.plan} != summary Tests={fr.summary_tests}")
        if fr.summary_ranges and fr.summary_ranges != fr.failed:
            problems.append(
                f"{name}: TAP set != summary Failed-tests set "
                f"({format_ranges(fr.failed)} vs {format_ranges(fr.summary_ranges)})")

    if not files:
        problems.append("no TAP file sections found (was this run with prove -v?)")
    if result is None:
        problems.append("missing Result: line (log truncated?)")
    return files, result, problems
