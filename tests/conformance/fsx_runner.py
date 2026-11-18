#!/usr/bin/env python3
# tests/conformance/fsx_runner.py — file-op exerciser baseline (T-02).
#
# Python port of fsx.sh: same logs, same exit contract, structured results.
#
# Usage:
#   python3 tests/conformance/fsx_runner.py [fsx] [fsstress]   # default: both
#   FSX_TIMEOUT=600 FSX_JOBS=2 FSX_TARGETS="fsx" ...
#
# Exit contract (unchanged; Makefile/CI wiring depends on it):
#   0 — everything passed and every post-run image checked clean
#   1 — an exerciser failed (see log)
#   2 — harness error (missing tools, LTP pin mismatch, bad args,
#       mount/daemon failure, timeout, checker found a dirty image)
#
# Tools (build once; override via env):
#   LTP_PIN pinned commit (fatal mismatch: unreproducible runs).
#   LTP_SRC default /tmp/fused/ltp-full (needs configure + lib + the two
#   test dirs built):
#     git clone https://github.com/linux-test-project/ltp.git
#     cd ltp && git checkout <LTP_PIN> && autoreconf -fiv && ./configure --without-numa
#     make -C lib -j4
#     make -C testcases/kernel/fs/fsx-linux -j4
#     make -C testcases/kernel/fs/fsstress -j4
#   FSX_BIN / FSSTRESS_BIN default to $LTP_SRC/testcases/kernel/fs/...
#   NOTE: /tmp is wiped on reboot — re-provisioning the checkout is expected.
#
# Method: fresh 16M mktemp image per run, FusedMount (mountinfo polling,
# fusermount fallback, waitpid so the daemon's final checkpoint lands),
# tool under a hard timeout with TMPDIR scoped onto the mount (fsx-linux
# writes its exercise file under $TMPDIR), then the checker gate:
# read-only scan first (recovery must not hide a crash bug), then RW —
# both must be 0 errors / 0 warnings; orphans after an exerciser workload
# are leaks until proven otherwise. Dirty/harness-error images preserved
# under /dev/shm/fused_keep/. Daemon logs live in the work dir and are
# kept only when the run fails (alongside the preserved image).
#   fsx-linux: -N 20000 content-oracle runs x3 (NOTE: LTP's rewrite seeds
#     srandom(time(NULL)) — no seed flag; repeat runs cover the gap).
#   fsstress: -n 1000 -p 4 for seeds 1 2 3 (deterministic via -s).
# Human logs: same format as the bash harness (tool output, checker
# output) plus an additive "RUN_RESULT: <verdict> <tag>" trailer (the
# GROUP_RESULT equivalent). Side output: logs/results-fsx-<tag>.json.
"""T-02 runner: fsx-linux content oracle + fsstress metadata stress."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fuse_mount as FM  # type: ignore[import-untyped]

LTP_PIN = "3c212bef5d11277c5720f061eabe840f24893f40"
ROOT = os.path.abspath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", ".."))
LOGS = os.path.join(ROOT, "logs")
KEEP_DIR = "/dev/shm/fused_keep"
IMAGE_SIZE = "16M"

# LTP exit codes OR in warning bits (e.g. unadjustable oom score in
# containers), so the fsx verdict is parsed from output: any TFAIL/TBROK
# fails; a clean TPASS passes even with TWARN noise.
_TFAIL_RE = re.compile(r"TFAIL|TBROK")
_TPASS_RE = re.compile(r"TPASS")


def die(msg: str, code: int = 2) -> None:
    print(f"fsx_runner.py: {msg}", file=sys.stderr)
    raise SystemExit(code)


def resolve_bin(path: str) -> str:
    return path if os.path.isabs(path) else os.path.join(ROOT, path)


def preflight(timeout: int) -> dict:
    if os.geteuid() != 0:
        die("must run as root (mounts + mknod tests); use: make fsx / make fsstress")
    ltp_src = os.environ.get("LTP_SRC", "/tmp/fused/ltp-full")
    fsx = os.environ.get(
        "FSX_BIN", os.path.join(ltp_src, "testcases/kernel/fs/fsx-linux/fsx-linux"))
    fsstress = os.environ.get(
        "FSSTRESS_BIN",
        os.path.join(ltp_src, "testcases/kernel/fs/fsstress/fsstress"))
    for b in (fsx, fsstress):
        if not os.access(b, os.X_OK):
            die(f"missing tool: {b} (see module docstring build recipe)")
    r = subprocess.run(["git", "-C", ltp_src, "rev-parse", "HEAD"],
                       capture_output=True, text=True, timeout=30, check=False)
    actual = r.stdout.strip() if r.returncode == 0 else "unknown"
    if actual != LTP_PIN:
        die(f"LTP checkout {actual} != pinned {LTP_PIN} "
            "(reproducibility requires the pin)")
    cfg = {
        "ltp_src": ltp_src,
        "fsx": fsx,
        "fsstress": fsstress,
        "fused": resolve_bin(os.environ.get("FUSED_BIN", "build/fused")),
        "format": resolve_bin(os.environ.get("FORMAT_BIN", "build/format")),
        "check": resolve_bin(os.environ.get("CHECK_BIN", "build/check")),
        "timeout": timeout,
        "logs": LOGS,
        "keep_dir": KEEP_DIR,
    }
    for key in ("fused", "format", "check"):
        if not os.access(cfg[key], os.X_OK):
            die(f"missing tool: {cfg[key]} (run: make build format check-tool)")
    return cfg


def select_targets(argv: list[str]) -> list[str]:
    if argv:
        targets = argv
    else:
        env = os.environ.get("FSX_TARGETS", "")
        targets = env.split() if env.strip() else ["fsx", "fsstress"]
    for t in targets:
        if t == "fsxx":
            die(f"unknown target '{t}' (did you mean 'fsx'? want: fsx fsstress)")
        if t not in ("fsx", "fsstress"):
            die(f"unknown target '{t}' (want: fsx fsstress)")
    return targets


def jobs_for(target: str, cfg: dict) -> list[tuple[str, list[str], bool]]:
    """(tag, command template, want_tp) triples for one target.

    want_tp: verdict comes from TFAIL/TPASS parsing (fsx-linux) vs the
    tool's exit code (fsstress). "@@MNT@@" resolves per-run in run_one.
    """
    if target == "fsx":
        return [(f"fsxlinux-{i}", [cfg["fsx"], "-N", "20000"], True)
                for i in (1, 2, 3)]
    return [(f"fsstress-{s}",
             [cfg["fsstress"], "-d", "@@MNT@@", "-n", "1000", "-p", "4",
              "-s", str(s)], False)
            for s in (1, 2, 3)]


def _stream_text(e: subprocess.TimeoutExpired) -> str:
    parts = []
    for stream in (e.stdout, e.stderr):
        if isinstance(stream, bytes):
            parts.append(stream.decode(errors="replace"))
        elif isinstance(stream, str) and stream:
            parts.append(stream)
    return "".join(parts)


def _preserve(cfg: dict, tag: str, img: str, why: str) -> str:
    os.makedirs(cfg["keep_dir"], exist_ok=True)
    dst = os.path.join(cfg["keep_dir"], f"fsx-{tag}.img")
    try:
        shutil.copy2(img, dst)
        return f"    preserved image ({why}): {dst}"
    except OSError as e:
        return f"    image preservation failed ({why}): {e}"


def _write_result(path: str, rec: dict) -> None:
    with open(path, "w") as f:
        json.dump(rec, f, indent=2, sort_keys=True)


def run_one(tag: str, cmdtmpl: list[str], cfg: dict, *, want_tp: bool) -> dict:
    """One run end-to-end: fresh image, mount, tool, checker gate.
    Never raises; every failure becomes a record with detail."""
    log = os.path.join(cfg["logs"], f"fsx-{tag}.log")
    print(f"==> {tag} (log {log})", flush=True)
    rec: dict = {
        "tag": tag, "verdict": "HARNESS-ERROR", "hrc": 2, "tool_rc": None,
        "checker": None, "log": log,
    }
    tool_out = ""
    checker_out = ""
    error: str | None = None
    keep_note = ""
    work: str | None = None
    img: str | None = None
    try:
        work = tempfile.mkdtemp(prefix="fused_fsx_", dir="/dev/shm")
        img = os.path.join(work, "img")
        mnt = os.path.join(work, "mnt")
        FM.format_image(cfg["format"], img, size=IMAGE_SIZE)
        os.makedirs(mnt, exist_ok=True)
        daemon_log = os.path.join(work, "fused.log")

        fm = FM.FusedMount(
            cfg["fused"], img,
            mount_dir=mnt,
            args=["--log-level=warn", f"--log-file={daemon_log}"],
            timeout=FM.MOUNT_TIMEOUT,
        )
        with fm as mount:
            os.makedirs(os.path.join(mount, "ltp-tmp"), exist_ok=True)
            cmd = [a.replace("@@MNT@@", mount) for a in cmdtmpl]
            try:
                r = subprocess.run(
                    cmd, capture_output=True, text=True, check=False,
                    timeout=cfg["timeout"],
                    env={**os.environ,
                         "TMPDIR": os.path.join(mount, "ltp-tmp")},
                )
                tool_rc: int = r.returncode
                tool_out = (r.stdout or "") + (r.stderr or "")
            except subprocess.TimeoutExpired as e:
                tool_rc = 124
                tool_out = _stream_text(e)
                error = f"tool timed out after {cfg['timeout']}s"
            rec["tool_rc"] = tool_rc
            # bash order: nonzero rc gets an explicit "tool exit N" line
            # in the log before the checker output (124 handled above).
            if tool_rc not in (0, 124):
                tool_out += f"tool exit {tool_rc}\n"
            # Daemon liveness after the tool: its log tail is the only
            # diagnostic a mid-run death leaves (the checker alone cannot
            # distinguish "crashed" from "cleanly refused").
            if error is None and not fm.alive:
                error = (f"DAEMON DIED mid-run (rc={fm.returncode}); "
                         f"log tail:\n{fm.log_tail()}")

        # FusedMount.__exit__ unmounted AND waited on the daemon: the
        # image is quiescent for the checker.
        if error is None:
            ok, errs, warns, out = FM.check_image_clean(cfg["check"], img)
            rec["checker"] = {"errors": errs, "warnings": warns}
            checker_out = out
            if not ok:
                rec["verdict"] = "CHECKER-DIRTY"
                rec["hrc"] = 2
                keep_note = _preserve(cfg, tag, img, "checker dirty")
            elif want_tp:
                if _TFAIL_RE.search(tool_out):
                    rec["verdict"] = "FAIL"
                    rec["hrc"] = 1
                    error = "content mismatch (TFAIL/TBROK)"
                elif _TPASS_RE.search(tool_out):
                    rec["verdict"] = "PASS"
                    rec["hrc"] = 0
                else:
                    rec["verdict"] = "FAIL"
                    rec["hrc"] = 1
                    error = "no TPASS verdict"
            else:
                if tool_rc != 0:
                    rec["verdict"] = "FAIL"
                    rec["hrc"] = 1
                    error = f"tool exit {tool_rc}"
                else:
                    rec["verdict"] = "PASS"
                    rec["hrc"] = 0
        else:
            rec["verdict"] = "HARNESS-ERROR"
            rec["hrc"] = 2
            if img and os.path.exists(img):
                keep_note = _preserve(cfg, tag, img, "harness error")
    except Exception as e:  # noqa: BLE001 — a worker must never crash the pool
        rec["verdict"] = "HARNESS-ERROR"
        rec["hrc"] = 2
        error = f"{type(e).__name__}: {e}"
    finally:
        # The mktemp dir is disposable once the image was preserved out of
        # it (or the run needs no triage).
        if work is not None and rec["verdict"] in ("PASS", "FAIL"):
            shutil.rmtree(work, ignore_errors=True)

    with open(log, "w") as f:
        f.write(tool_out)
        f.write(checker_out)
        if keep_note:
            f.write(keep_note + "\n")
        if error:
            f.write(f"ERROR: {error}\n")
        f.write(f"RUN_RESULT: {rec['verdict']} {tag}\n")
    rec["error"] = error
    _write_result(os.path.join(cfg["logs"], f"results-fsx-{tag}.json"), rec)
    print(f"RUN_RESULT: {rec['verdict']} {tag}", flush=True)
    return rec


def run_target(target: str, cfg: dict) -> list[dict]:
    return [run_one(tag, cmd, cfg, want_tp=want_tp)
            for tag, cmd, want_tp in jobs_for(target, cfg)]


def main() -> int:
    parser = argparse.ArgumentParser(description="T-02 exerciser runner")
    parser.add_argument("targets", nargs="*")
    parser.add_argument("--jobs", type=int,
                        default=int(os.environ.get("FSX_JOBS", "1")))
    parser.add_argument("--timeout", type=int,
                        default=int(os.environ.get("FSX_TIMEOUT", "600")))
    args = parser.parse_args()
    if args.jobs < 1 or args.timeout < 1:
        die("--jobs and --timeout must be >= 1")

    cfg = preflight(args.timeout)
    targets = select_targets(args.targets)
    os.makedirs(LOGS, exist_ok=True)

    overall = 0
    all_recs: list[dict] = []
    if args.jobs > 1:
        futures = []
        with concurrent.futures.ProcessPoolExecutor(max_workers=args.jobs) as pool:
            for t in targets:
                for tag, cmd, want_tp in jobs_for(t, cfg):
                    futures.append(
                        (tag, pool.submit(run_one, tag, cmd, cfg,
                                          want_tp=want_tp)))
            for tag, fut in futures:
                try:
                    rec = fut.result()
                except Exception as e:  # noqa: BLE001 — worker crash
                    rec = {"tag": tag, "verdict": "HARNESS-ERROR", "hrc": 2,
                           "error": f"worker crash: {type(e).__name__}: {e}",
                           "tool_rc": None, "checker": None}
                all_recs.append(rec)
    else:
        for t in targets:
            all_recs.extend(run_target(t, cfg))

    print("== summary ==")
    for rec in all_recs:
        verdict = rec.get("verdict", "HARNESS-ERROR")
        print(f"  {rec['tag']}  {verdict}"
              + (f" ({rec['error']})" if rec.get("error") else ""))
        if verdict in ("HARNESS-ERROR", "CHECKER-DIRTY"):
            overall = 2
        elif verdict == "FAIL" and overall == 0:
            overall = 1
    print("fsx_note: fsx-linux srandom(time(NULL)) — no seed flag; "
          "fsstress -s seeds 1 2 3")
    return overall


if __name__ == "__main__":
    raise SystemExit(main())
