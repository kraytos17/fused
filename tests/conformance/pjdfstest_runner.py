#!/usr/bin/env python3
# tests/conformance/pjdfstest_runner.py — POSIX conformance runner (T-01).
#
# Python port of pjdfstest.sh: same logs, same exit contract, structured
# results. Orchestration only — pjdfstest itself still does the work.
#
# Usage:
#   python3 tests/conformance/pjdfstest_runner.py [group...]
#   PJD_GROUPS="chmod open" python3 tests/conformance/pjdfstest_runner.py
#   PJD_JOBS=4 python3 tests/conformance/pjdfstest_runner.py
#   GROUP_TIMEOUT=600 ...                       # per-prove timeout, seconds
#
# Exit contract (unchanged; Makefile/CI wiring depends on it):
#   0 — every group passed (rare; the baseline lists failures)
#   1 — at least one group had test failures (the NORMAL case)
#   2 — harness error (missing tools, pin mismatch, bad args, mount/daemon
#       failure, timeout, checker found a dirty image). Never 1 for these.
#
# Per group: a FRESH 64M image and its own mount (no leak/ENOSPC cascades
# across groups), `prove -v` under a hard timeout, then a checker gate
# (read-only first so recovery can't hide a crash bug, then RW; both must
# be 0 errors / 0 warnings). Dirty or harness-error images are preserved
# under /dev/shm/fused_keep/ for triage.
#
# Human log (logs/pjdfstest-<group>.log) is byte-compatible with the bash
# harness — header, TAP, "prove exit: N", checker output, GROUP_RESULT —
# except the per-run mktemp path inside checker output. The TAP parser
# consumes it unchanged. Side output: logs/results-<group>.json (verdict +
# per-file TAP sets) for the gate/baseline tooling.
#
# Requirements: run as root (tests setuid to other uids), inside the
# unshare -rUm namespace (`make conformance` provides it), pjdfstest
# checkout at $PJD_SRC pinned — mismatch is fatal (reproducibility).
"""T-01 runner: per-group isolation, prove -v, checker gates, JSON results."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fuse_mount as FM  # type: ignore[import-untyped]
import pjdfstest_parse as P  # type: ignore[import-untyped]

PJD_COMMIT = "85a8aea9e685999ef0540392fd80535f873d7ff7"
ROOT = os.path.abspath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", ".."))
LOGS = os.path.join(ROOT, "logs")
EXPECTED = os.path.join(ROOT, "tests", "conformance", "expected_failures.txt")
KEEP_DIR = "/dev/shm/fused_keep"
IMAGE_SIZE = "64M"
IMAGE_CLUSTER = "16"


def die(msg: str, code: int = 2) -> None:
    print(f"pjdfstest_runner.py: {msg}", file=sys.stderr)
    raise SystemExit(code)


def resolve_bin(path: str) -> str:
    return path if os.path.isabs(path) else os.path.join(ROOT, path)


def preflight(timeout: int) -> dict:
    """Root/pin/tool checks; returns the shared worker config."""
    if os.geteuid() != 0:
        die("must run as root (tests setuid to other uids); use: make conformance")
    pjd_src = os.environ.get("PJD_SRC", "/tmp/fused/pjdfstest")
    if not os.path.isfile(os.path.join(pjd_src, "pjdfstest")):
        die(f"missing pjdfstest binary at {pjd_src}/pjdfstest "
            f"(build: cd <checkout> && git checkout {PJD_COMMIT} && "
            "autoreconf -ifs && ./configure && make pjdfstest)")
    r = subprocess.run(["git", "-C", pjd_src, "rev-parse", "HEAD"],
                       capture_output=True, text=True, timeout=30, check=False)
    actual = r.stdout.strip() if r.returncode == 0 else "unknown"
    if actual != PJD_COMMIT:
        die(f"pjdfstest checkout {actual} != pinned {PJD_COMMIT} "
            "(reproducibility requires the pin)")
    cfg = {
        "pjd_src": pjd_src,
        "fused": resolve_bin(os.environ.get("FUSED_BIN", "build/fused")),
        "format": resolve_bin(os.environ.get("FORMAT_BIN", "build/format")),
        "check": resolve_bin(os.environ.get("CHECK_BIN", "build/check")),
        "pin": PJD_COMMIT,
        "prove_timeout": timeout,
        "keep_dir": KEEP_DIR,
        "logs": LOGS,
    }
    for key in ("fused", "format", "check"):
        if not os.access(cfg[key], os.X_OK):
            die(f"missing tool: {cfg[key]} (run: make build format check-tool)")
    return cfg


def default_groups(pjd_src: str) -> list[str]:
    """Groups the suite actually ships: directories under $PJD_SRC/tests
    containing .t files (the true single source of truth — the baseline
    records failures for whatever ran, it must not gate what can run).
    ci.py passes an explicit scoped subset via PJD_GROUPS."""
    out = []
    base = os.path.join(pjd_src, "tests")
    for name in sorted(os.listdir(base)):
        d = os.path.join(base, name)
        if os.path.isdir(d) and any(f.endswith(".t") for f in os.listdir(d)):
            out.append(name)
    return out


def select_groups(argv: list[str], pjd_src: str) -> list[str]:
    """CLI args > PJD_GROUPS env > suite discovery."""
    if argv:
        return argv
    env = os.environ.get("PJD_GROUPS", "")
    if env.strip():
        return env.split()
    return default_groups(pjd_src)


def _preserve(cfg: dict, group: str, img: str, why: str) -> str:
    os.makedirs(cfg["keep_dir"], exist_ok=True)
    dst = os.path.join(cfg["keep_dir"], f"{group}.img")
    try:
        shutil.copy2(img, dst)
        return f"    preserved image ({why}): {dst}"
    except OSError as e:
        return f"    image preservation failed ({why}): {e}"


def run_group(group: str, cfg: dict) -> dict:
    """One group end-to-end; never raises (failures become HARNESS-ERROR
    records with detail so a worker crash can't take down the pool)."""
    log = os.path.join(cfg["logs"], f"pjdfstest-{group}.log")
    daemon_log = os.path.join(cfg["logs"], f"pjdfstest-{group}-daemon.log")
    print(f"==> group {group} (log {log})", flush=True)
    rec: dict = {
        "group": group, "pin": cfg["pin"], "verdict": "HARNESS-ERROR",
        "hrc": 2, "prove_rc": None, "checker": None,
        "daemon_alive_at_end": False, "files": {}, "log": log,
        "daemon_log": daemon_log,
    }
    body_lines: list[str] = []
    checker_out = ""
    error: str | None = None
    work: str | None = None
    img: str | None = None
    keep_note = ""
    try:
        # Fresh daemon log per run: Odin's file logger appends, so a stale
        # file would mix runs (reviewer item 3.3).
        if os.path.exists(daemon_log):
            os.remove(daemon_log)
        work = tempfile.mkdtemp(prefix="fused_pjd_", dir="/dev/shm")
        img = os.path.join(work, "img")
        mnt = os.path.join(work, "mnt")
        FM.format_image(cfg["format"], img, size=IMAGE_SIZE,
                        cluster_size=IMAGE_CLUSTER)
        os.makedirs(mnt, exist_ok=True)

        lines = [f"== pjdfstest {group} pin={cfg['pin']} =="]
        fm = FM.FusedMount(
            cfg["fused"], img,
            mount_dir=mnt,
            args=["--log-level=warn", f"--log-file={daemon_log}"],
            timeout=FM.MOUNT_TIMEOUT,
        )
        with fm:
            try:
                r = subprocess.run(
                    ["prove", "-v", os.path.join(cfg["pjd_src"], "tests", group)],
                    capture_output=True, text=True, check=False,
                    timeout=cfg["prove_timeout"], cwd=fm.mount_dir,
                )
                prove_rc: int = r.returncode
                if r.stdout:
                    lines.append(r.stdout)
                if r.stderr:
                    lines.append(r.stderr)
            except subprocess.TimeoutExpired as e:
                prove_rc = 124
                for stream in (e.stdout, e.stderr):
                    if isinstance(stream, str) and stream:
                        lines.append(stream)
                lines.append(f"prove timed out after {cfg['prove_timeout']}s")
            lines.append(f"prove exit: {prove_rc}")
            rec["prove_rc"] = prove_rc

            # Verdict (no exceptions thrown for expected cases; a nonzero
            # prove rc of 1 is the NORMAL failure case).
            if prove_rc == 124:
                rec["hrc"] = 2
                error = f"prove timed out after {cfg['prove_timeout']}s"
            elif not fm.alive:
                rec["hrc"] = 2
                error = (f"daemon died mid-group (rc={fm.returncode}); "
                         f"log tail:\n{fm.log_tail()}")
                lines.append(error)
            elif prove_rc == 0:
                rec["hrc"] = 0
            elif prove_rc == 1:
                rec["hrc"] = 1
            else:
                rec["hrc"] = 2
                error = f"prove exited {prove_rc} (harness-level problem)"
                lines.append(error)
            rec["daemon_alive_at_end"] = fm.alive
        # FusedMount.__exit__ unmounted AND waited on the daemon: its final
        # checkpoint has landed, the image is quiescent for the checker.
        ok, errs, warns, out = FM.check_image_clean(cfg["check"], img)
        rec["checker"] = {"errors": errs, "warnings": warns}
        checker_out = out

        if not ok:
            rec["hrc"] = 2
            rec["verdict"] = "CHECKER-DIRTY"
            keep_note = _preserve(cfg, group, img, "checker dirty")
        elif rec["hrc"] == 2:
            rec["verdict"] = "HARNESS-ERROR"
            keep_note = _preserve(cfg, group, img, "harness error")
        elif rec["hrc"] == 1:
            rec["verdict"] = "FAIL"
        else:
            rec["verdict"] = "PASS"
        body_lines = lines
    except Exception as e:  # noqa: BLE001 — a worker must never crash the pool
        rec["hrc"] = 2
        rec["verdict"] = "HARNESS-ERROR"
        error = f"{type(e).__name__}: {e}"
    finally:
        # Work dir cleanup: keep the image when it was preserved (it was
        # already copied out; the mktemp dir itself is disposable).
        if work is not None:
            shutil.rmtree(work, ignore_errors=True)

    # Assemble the human log in bash byte-order (body + checker output),
    # then parse it — the TAP parser is the single source of truth for the
    # per-file sets, and it needs the log on disk. Verdict-affecting notes
    # (keep/error) and GROUP_RESULT append after, matching bash order.
    with open(log, "w") as f:
        f.writelines(line if line.endswith("\n") else line + "\n"
                     for line in body_lines)
        f.write(checker_out)

    files, _result, problems = P.parse_prove_log(log)
    if problems:
        error = (error or "") + f"; TAP/summary issues: {'; '.join(problems)}"
        if rec["verdict"] == "PASS":
            rec["verdict"] = "HARNESS-ERROR"
            rec["hrc"] = 2
    rec["files"] = {
        name: {
            "plan": fr.plan,
            "wstat": fr.wstat,
            "failed": sorted(fr.failed),
            "skipped": sorted(fr.skipped),
            "env": sorted(n for n in fr.failed
                          if P.is_env_failure(fr.tried.get(n, ""))),
            "crashed": fr.crashed,
        }
        for name, fr in sorted(files.items())
        if fr.failed or fr.skipped or fr.crashed
    }

    with open(log, "a") as f:
        if keep_note:
            f.write(keep_note + "\n")
        if error:
            f.write(f"ERROR: {error}\n")
        f.write(f"GROUP_RESULT: {rec['verdict']} {group}\n")
    rec["error"] = error
    _write_result(os.path.join(cfg["logs"], f"results-{group}.json"), rec)
    print(f"GROUP_RESULT: {rec['verdict']} {group}", flush=True)
    return rec


def _write_result(path: str, rec: dict) -> None:
    with open(path, "w") as f:
        json.dump(rec, f, indent=2, sort_keys=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="T-01 conformance runner")
    parser.add_argument("groups", nargs="*")
    parser.add_argument("--jobs", type=int,
                        default=int(os.environ.get("PJD_JOBS", "1")))
    parser.add_argument("--timeout", type=int,
                        default=int(os.environ.get("GROUP_TIMEOUT", "600")))
    args = parser.parse_args()
    if args.jobs < 1 or args.timeout < 1:
        die("--jobs and --timeout must be >= 1")

    cfg = preflight(args.timeout)
    groups = select_groups(args.groups, cfg["pjd_src"])
    if not groups:
        die("no groups selected and baseline has none")
    for g in groups:
        if not os.path.isdir(os.path.join(cfg["pjd_src"], "tests", g)):
            die(f"unknown group '{g}' (no {cfg['pjd_src']}/tests/{g})")
    os.makedirs(LOGS, exist_ok=True)

    overall = 0
    records: dict[str, dict] = {}
    if args.jobs > 1:
        with concurrent.futures.ProcessPoolExecutor(max_workers=args.jobs) as pool:
            futures = {pool.submit(run_group, g, cfg): g for g in groups}
            for fut in concurrent.futures.as_completed(futures):
                g = futures[fut]
                try:
                    records[g] = fut.result()
                except Exception as e:  # noqa: BLE001 — worker crash
                    records[g] = {
                        "group": g, "verdict": "HARNESS-ERROR", "hrc": 2,
                        "error": f"worker crash: {type(e).__name__}: {e}",
                        "pin": cfg["pin"], "files": {},
                        "checker": None, "prove_rc": None,
                        "daemon_alive_at_end": False,
                    }
    else:
        for g in groups:
            records[g] = run_group(g, cfg)

    print("== summary ==")
    for g in groups:
        rec = records.get(g, {"verdict": "HARNESS-ERROR"})
        verdict = rec.get("verdict", "HARNESS-ERROR")
        print(f"  {g}  {verdict}")
        if verdict in ("HARNESS-ERROR", "CHECKER-DIRTY"):
            overall = 2
        elif verdict == "FAIL" and overall == 0:
            overall = 1
    print(f"pjd_commit={cfg['pin']}")
    return overall


if __name__ == "__main__":
    raise SystemExit(main())
