# tests/fuzz/fuzz_image.py — structure-aware image fuzzer (T-07).
#
# Usage:
#   python3 tests/fuzz/fuzz_image.py [--seeds DIR...] [--iterations N]
#       [--timeout S] [--out DIR] [--live] [--no-offline] [--seed S]
#       [--check BIN] [--imgdump BIN] [--format BIN] [--fused BIN]
#
# Builds a corpus (committed goldens + fresh format variants), applies
# seeded structure-aware mutations (master/CE/journal/dir/xattr/LFN fields
# plus blind byte ops), and runs each mutant through:
#   offline: build/check --read-only, build/check (RW recovery), imgdump
#            --json. Crash = signal death or timeout. Nonzero exits with
#            findings are the checker's JOB (not bugs).
#   live (--live, needs a mount namespace): mount the mutant, run find +
#            cat + getfattr + rm -rf with timeouts. Daemon signal death,
#            mount hang, or mid-run staleness = bug. A clean mount refusal
#            (validate_master rejects garbage) is correct, not a bug.
# Findings land in --out (default /dev/shm/fused_fuzz) as
# <kind>-<iter>.img + .log. Deterministic per (--seed, iter): rerun one
# with --iterations 1 --first <i> (same seed) to reproduce exactly.
# Triage rule: every crash/hang becomes a regression test + a checker
# finding code (docs/FSCK_CODES.md when it exists).
import argparse
import os
import random
import shutil
import struct
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "conformance"))
import fuse_mount as FM  # type: ignore[import-untyped]

SECTOR = 512

# --- on-disk layout (mirrors src/fs/structure.odin; rev asserts pin it) ---
DIR_ENTRY_SIZE = 64
DIR_ENTRY_SIZE_V5 = 56  # rev 7 layout (no xattr_cluster)
OFF_NAME = 2
OFF_SECTOR_INDEX = 18
OFF_STORED_CLUSTER = 20
OFF_FILE_SIZE = 44  # rev 8 (42 for rev 7; see entry_size())
OFF_XATTR_CLUSTER = 56  # rev 8 only
CE_SIZE = 16
JOURNAL_MAGIC = 0xF11E0002
XATTR_MAGIC = 0x58415452


def parse_master(buf):
    assert buf[0:7] == b"FUSED\x00\x00", "not a fused image"
    rev_min, rev_max = buf[7], buf[8]
    (features,) = struct.unpack_from("<Q", buf, 9)
    (cm_off,) = struct.unpack_from("<Q", buf, 17)
    (cm_size,) = struct.unpack_from("<Q", buf, 25)
    (cluster_size,) = struct.unpack_from("<Q", buf, 33)
    (root_sec,) = struct.unpack_from("<H", buf, 41)
    (root_cluster,) = struct.unpack_from("<Q", buf, 43)
    return {
        "rev_min": rev_min, "rev_max": rev_max, "features": features,
        "cm_off": cm_off, "cm_size": cm_size, "cluster_size": cluster_size,
        "root_cluster": root_cluster, "root_sec": root_sec,
    }


def cm_entry(buf, ci):
    sec = buf[(ci // 64) * SECTOR:]
    off = (ci % 64) * 8
    return struct.unpack_from("<HH", sec, off)  # sector_index, flags


def ce_table_sector(buf, m, ci):
    """Sector holding cluster ci's CE table (None if cluster unallocated)."""
    sec_idx, flags = cm_entry(buf[(m["cm_off"]) * SECTOR:], ci)
    if not flags & 0x1:  # Allocated bit
        return None
    if sec_idx >= m["cluster_size"]:
        return None
    return ci * m["cluster_size"] + sec_idx


def entry_size(features):
    return DIR_ENTRY_SIZE if features & 0x4 else DIR_ENTRY_SIZE_V5


# --- mutators: each takes (buf, rng, geom) and returns a description ---
def m_rand_bytes(buf, rng, g):
    off = rng.randrange(0, len(buf))
    ln = rng.randint(1, 64)
    buf[off:off + ln] = rng.randbytes(min(ln, len(buf) - off))
    return f"rand_bytes@{off}+{ln}"


def m_flip_bits(buf, rng, g):
    n = rng.randint(1, 4)
    for _ in range(n):
        o = rng.randrange(0, len(buf))
        buf[o] ^= 1 << rng.randrange(0, 8)
    return f"flip_bitsx{n}"


def m_truncate(buf, rng, g):
    cut = rng.randrange(0, len(buf))
    del buf[cut:]
    return f"truncate@{cut}"


def m_swap_sectors(buf, rng, g):
    nsec = len(buf) // SECTOR
    if nsec < 2:
        return "swap_sectors:skipped"
    a, b = rng.sample(range(nsec), 2)
    ab, bb = buf[a * SECTOR:(a + 1) * SECTOR], buf[b * SECTOR:(b + 1) * SECTOR]
    buf[a * SECTOR:(a + 1) * SECTOR], buf[b * SECTOR:(b + 1) * SECTOR] = bb, ab
    return f"swap_sectors {a}<->{b}"


def m_zero_sector(buf, rng, g):
    s = rng.randrange(0, len(buf) // SECTOR)
    buf[s * SECTOR:(s + 1) * SECTOR] = b"\x00" * SECTOR
    return f"zero_sector {s}"


def m_master(buf, rng, g):
    field = rng.choice(["rev", "features", "cm", "geom", "root", "endsig"])
    if field == "rev":
        buf[7] = rng.choice([6, 7, 8, 9, 255])
        buf[8] = rng.choice([6, 7, 8, 9, 255])
    elif field == "features":
        struct.pack_into("<Q", buf, 9, rng.choice([0, 1, 2, 3, 4, 7, 0xFFFFFFFFFFFFFFFF]))
    elif field == "cm":
        struct.pack_into("<Q", buf, 17, rng.choice([0, 1, 2, 999999]))
        struct.pack_into("<Q", buf, 25, rng.choice([0, 1, 128, 999999]))
    elif field == "geom":
        struct.pack_into("<Q", buf, 33, rng.choice([0, 1, 2, 7, 15, 16, 17, 65535]))
    elif field == "root":
        struct.pack_into("<H", buf, 41, rng.choice([0, 1, 9999]))
        struct.pack_into("<Q", buf, 43, rng.choice([0, 1, 5, 999999]))
    else:
        buf[510:512] = rng.randbytes(2)
    return f"master:{field}"


def m_journal_header(buf, rng, g):
    nsec = len(buf) // SECTOR
    cm_secs = (g["cm_size"] + 63) // 64
    base = g["cm_off"] + cm_secs
    region = max(64, (len(buf) // SECTOR // max(1, g["cluster_size"])) // 10)
    s = base + rng.randrange(0, max(1, min(region, max(0, nsec - base))))
    if s >= nsec:
        return "journal_header:skipped"
    o = s * SECTOR
    field = rng.choice(["magic", "seq", "counts", "crc", "tail"])
    if field == "magic":
        struct.pack_into("<I", buf, o, rng.choice([0, JOURNAL_MAGIC ^ 0xFF, 0xDEADBEEF]))
    elif field == "seq":
        struct.pack_into("<Q", buf, o + 4, rng.choice([0, 1, 2**64 - 1]))
    elif field == "counts":
        struct.pack_into("<H", buf, o + 12, rng.choice([0, 1, 21, 34, 35, 100]))
        struct.pack_into("<H", buf, o + 14, rng.choice([0, 1, 2, 10]))
    elif field == "crc":
        struct.pack_into("<I", buf, o + 20, rng.getrandbits(32))
    else:
        struct.pack_into("<I", buf, o + 24, rng.choice([0, 0xDEADBEEF]))
    return f"journal_header:{field}@{s}"


def m_ce_entry(buf, rng, g):
    for _ in range(8):  # find an allocated cluster to target
        ci = rng.randrange(0, min(g["cm_size"], len(buf) // SECTOR))
        ts = ce_table_sector(buf, g, ci)
        if ts is not None and ts < len(buf) // SECTOR:
            break
    else:
        return "ce_entry:skipped"
    idx = rng.randrange(0, 32)
    o = ts * SECTOR + idx * CE_SIZE
    field = rng.choice(["state", "alloc", "start", "next"])
    if field == "state":
        buf[o] = rng.choice([0, 1, 3, 7, 0xFF])
        buf[o + 1] = rng.choice([0, 1, 0xFF])
    elif field == "alloc":
        struct.pack_into("<H", buf, o + 12, rng.choice([0, 1, 16, 17, 100, 65535]))
    elif field == "start":
        struct.pack_into("<H", buf, o + 14, rng.choice([0, 1, 16, 100, 65535]))
    else:
        struct.pack_into("<Q", buf, o + 4, rng.choice([0, 1, 99999999, 2**64 - 1]))
        struct.pack_into("<H", buf, o + 12 + 2, rng.choice([0, 1, 9999]))
    return f"ce_entry:{field} cluster={ci} idx={idx}"


def m_dir_entry(buf, rng, g):
    nsec = len(buf) // SECTOR
    s = rng.randrange(1, nsec)  # skip sector 0 (master has own mutator)
    des = entry_size(g["features"])
    per = SECTOR // des
    i = rng.randrange(0, per)
    o = s * SECTOR + i * des
    if o + 64 > len(buf):
        return "dir_entry:skipped"
    field = rng.choice(["flags", "name", "size", "cluster", "xattr", "lfn"])
    if field == "flags":
        struct.pack_into("<H", buf, o, rng.choice([0, 1, 0x21, 0x25, 0xFF, 0xFFFF]))
    elif field == "name":
        poison = rng.choice([b"/", b"\x00", b".." , b"."])
        pos = rng.randrange(0, 16)
        buf[o + 2 + pos:o + 2 + pos + len(poison)] = poison
    elif field == "size":
        struct.pack_into("<Q", buf, o + (44 if des == 64 else 40),
                         rng.choice([0, 1, 512, 2**32, 2**63 - 1, 2**64 - 1]))
    elif field == "cluster":
        struct.pack_into("<Q", buf, o + 20, rng.choice([0, 1, 99999999, 2**64 - 1]))
        struct.pack_into("<H", buf, o + 18, rng.choice([0, 1, 9999]))
    elif field == "xattr":
        if des == 64:
            struct.pack_into("<Q", buf, o + 56, rng.choice([0, 1, 99999999, 2**64 - 1]))
            return f"dir_entry:xattr @{s}:{i}"
        return "dir_entry:xattr:skipped-rev7"
    else:  # LFN pointer garbage in a flagged entry
        buf[o] = buf[o] | 0x02  # set .LFN bit (bit 1)
        for k in range(16):
            buf[o + 2 + k] = rng.randrange(0, 256)
    return f"dir_entry:{field} @{s}:{i}"


def m_xattr_blob(buf, rng, g):
    # Corrupt any sector that looks like an xattr blob (magic match).
    cands = [s for s in range(len(buf) // SECTOR)
             if buf[s * SECTOR:s * SECTOR + 4] == struct.pack("<I", XATTR_MAGIC)]
    if not cands:
        return "xattr_blob:skipped"
    s = rng.choice(cands)
    o = s * SECTOR
    field = rng.choice(["magic", "count", "total", "record"])
    if field == "magic":
        struct.pack_into("<I", buf, o, rng.choice([0, 0xDEADBEEF]))
    elif field == "count":
        struct.pack_into("<H", buf, o + 4, rng.choice([0, 1, 100, 1000, 65535]))
    elif field == "total":
        struct.pack_into("<I", buf, o + 8, rng.choice([0, 12, 100, 65536, 2**32 - 1]))
    else:
        pos = o + 12 + rng.randrange(0, 64)
        ln = min(8, len(buf) - pos)
        buf[pos:pos + ln] = rng.randbytes(ln)
    return f"xattr_blob:{field} @{s}"


MUTATORS = [m_rand_bytes, m_flip_bits, m_truncate, m_swap_sectors,
            m_zero_sector, m_master, m_journal_header, m_ce_entry,
            m_dir_entry, m_xattr_blob]


def run(cmd, timeout, cwd=None):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout, cwd=cwd, check=False)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        err = (e.stderr or b"").decode(errors="replace") if isinstance(e.stderr, bytes) else (e.stderr or "")
        return "timeout", out, err


def classify(kind, rc, out, err):
    """Crash/hang verdict. Nonzero exits WITH findings are the tools' job."""
    if rc == "timeout":
        return f"HANG {kind}"
    if isinstance(rc, int) and rc < 0:
        import signal as _sig
        try:
            sig = _sig.Signals(-rc).name
        except ValueError:
            sig = f"sig{-rc}"
        return f"CRASH {kind} ({sig})"
    text = (out or "") + (err or "")
    for marker in ("index out of range", "slice bounds", "integer overflow",
                   "panicked", "RUNTIME ERROR", "AddressSanitizer", "runtime error"):
        if marker.lower() in text.lower() and not (isinstance(rc, int) and rc in (0, 1)):
            return f"CRASH {kind} (panic marker: {marker})"
    return None


def build_corpus(args, tmp):
    """Committed goldens + fresh format variants (geometry sweep)."""
    seeds = []
    for name in ("rev7.img", "rev8.img"):
        p = os.path.join("tests", "golden", name)
        if os.path.isfile(p):
            seeds.append(p)
    os.makedirs(tmp, exist_ok=True)
    for ci, (cs, demo) in enumerate([(16, True), (16, False), (64, True), (64, False)]):
        out = os.path.join(tmp, f"variant-{ci}.img")
        cmd = [args.format, "--force", f"--output={out}", "--size=1M",
               f"--cluster-size={cs}"]
        if not demo:
            cmd.append("--no-demo")
        rc, _, _ = run(cmd, 120)
        if rc == 0:
            seeds.append(out)
    return seeds


def _sig_name(rc: int) -> str:
    import signal as _sig
    try:
        return _sig.Signals(-rc).name
    except (ValueError, OverflowError):
        return f"sig{-rc}"


def live_trial(fused_bin, img, mount, logs, timeout, check_bin="build/check"):
    """Mount + exercise a mutant via FusedMount. Returns finding or None.

    Verdict logic (a fail-closed mount is CORRECT for a corrupt image):
      daemon signal death / mount-wait timeout / probe timeout -> bug.
      daemon clean refusal (validate_master said no)           -> ok.
      mount present but probe op fails + check reports errors  -> ok
        (correctly rejected patient; the checker owns the diagnosis).
      mount present but probe op fails + check is clean        -> BUG
        (false rejection of a healthy image).
    """
    shutil.rmtree(mount, ignore_errors=True)
    os.makedirs(mount, exist_ok=True)
    os.makedirs(logs, exist_ok=True)
    log_path = os.path.join(logs, "fused_fuzz.log")
    fm = FM.FusedMount(fused_bin, img, mount_dir=mount,
                       args=["--log-level=warn", f"--log-file={log_path}"],
                       timeout=10.0)
    try:
        try:
            fm.mount()
        except FM.MountError:
            if fm.proc is not None and fm.proc.poll() is not None \
               and fm.proc.returncode is not None and fm.proc.returncode < 0:
                return f"CRASH daemon died on mount ({_sig_name(fm.proc.returncode)})"
            # Daemon exited cleanly = validate_master refused the garbage.
            return None
        # Probe: stat the root. Timeout here is a genuine hang.
        rc, _, _ = run(["timeout", "5", "stat", mount], 10)
        if rc == "timeout":
            return "HANG root stat timed out"
        if rc != 0:
            # Mount is present but useless. Ask the checker who is right.
            _, cout, _ = run([check_bin, "--read-only", img, "--log-level=warn"], 30)
            import re as _re
            if _re.search(r"(?<!\d)0 errors", cout or ""):
                return f"FALSE REJECTION: mount unusable but check is clean (stat rc={rc})"
            return None
        cmds = [
            ["timeout", "10", "find", mount],
            ["bash", "-c", f"timeout 10 cat $(timeout 10 find {mount} -type f | head -20) > /dev/null 2>&1; true"],
            ["bash", "-c", f"timeout 10 getfattr -d -m . {mount}/* 2>/dev/null; true"],
        ]
        for c in cmds:
            rc, _, _ = run(c, timeout)
            if rc == "timeout":
                return f"HANG {' '.join(c[1:3])}"
            if fm.proc.poll() is not None:
                drc = fm.proc.returncode
                if drc is not None and drc < 0:
                    return f"CRASH daemon died mid-run ({_sig_name(drc)})"
                return None
        if fm.proc.poll() is not None:
            drc = fm.proc.returncode
            if drc is not None and drc < 0:
                return f"CRASH daemon died ({_sig_name(drc)})"
        return None
    finally:
        try:
            fm.unmount()
        except Exception as e:  # noqa: BLE001 — cleanup must not mask findings
            print(f"fuzz: unmount cleanup failed: {e}", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description="fused image fuzzer (T-07)")
    ap.add_argument("--iterations", type=int, default=500)
    ap.add_argument("--first", type=int, default=0, help="start index (repro one: --iterations 1 --first I)")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--timeout", type=float, default=30, help="per-target seconds")
    ap.add_argument("--out", default="/dev/shm/fused_fuzz")
    ap.add_argument("--live", action="store_true", help="also mount+exercise each mutant (needs mount ns)")
    ap.add_argument("--no-offline", action="store_true")
    ap.add_argument("--check", default="build/check")
    ap.add_argument("--imgdump", default="build/imgdump")
    ap.add_argument("--format", default="build/format")
    ap.add_argument("--fused", default="build/fused")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    tmp = os.path.join(args.out, "corpus")
    seeds = build_corpus(args, tmp)
    if not seeds:
        print("no seed images", file=sys.stderr)
        return 2
    print(f"corpus: {len(seeds)} images")
    findings = 0
    for i in range(args.first, args.first + args.iterations):
        rng = random.Random(args.seed * 1000003 + i)
        with open(rng.choice(seeds), "rb") as f:
            buf = bytearray(f.read())
        nmuts = rng.randint(1, 3)
        descs = []
        geom = None
        try:
            geom = parse_master(bytes(buf[:SECTOR]))
            geom["image_sectors"] = len(buf) // SECTOR
        except Exception as e:  # noqa: BLE001 — corrupt master = no geom
            descs.append(f"geom-parse-skipped:{e}")
        for _ in range(nmuts):
            mut = rng.choice(MUTATORS)
            try:
                if mut in (m_journal_header, m_ce_entry, m_dir_entry) and geom is None:
                    descs.append("skipped:no-geom")
                    continue
                descs.append(mut(buf, rng, geom or {}))
            except Exception as e:  # noqa: BLE001 — mutator bug, not a finding
                descs.append(f"mutator-error:{e}")
        img = os.path.join(args.out, f"fuzz-{i}.img")
        with open(img, "wb") as f:
            f.write(buf)
        log = [f"iter {i} seed mutations: {'; '.join(descs)}"]
        hit = None
        if not args.no_offline:
            for kind, cmd in (
                ("check-ro", [args.check, "--read-only", img, "--log-level=warn"]),
                ("check-rw", [args.check, img, "--log-level=warn"]),
                ("imgdump", [args.imgdump, "--json", img, "--log-level=warn"]),
            ):
                rc, out, err = run(cmd, args.timeout)
                log.append(f"{kind}: rc={rc}")
                hit = classify(kind, rc, out, err)
                if hit:
                    log.append((out or "")[-2000:])
                    log.append((err or "")[-2000:])
                    break
        if hit is None and args.live and os.path.isfile(img):
            hit = live_trial(args.fused, img, os.path.join(args.out, "mnt"),
                             os.path.join(args.out, "logs"), min(10.0, args.timeout))
            log.append(f"live: {hit}")
        if hit:
            findings += 1
            with open(os.path.join(args.out, f"fuzz-{i}.log"), "w") as f:
                f.write("\n".join(log))
            print(f"ITER {i}: {hit} ({'; '.join(descs)})", flush=True)
        else:
            if os.path.isfile(img):
                os.remove(img)
    print(f"done: {args.iterations} iters, {findings} findings in {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
