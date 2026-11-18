# tests/fuse/test_model.py — differential model testing (T-04).
#
# Generates seeded random op sequences (create/mkdir/write/truncate/rename/
# unlink/rmdir/symlink/setxattr/removexattr) and applies each op to BOTH the
# fused mount and a tmpfs/host reference dir, comparing the full tree after
# every op: entry sets, kinds, sizes, file bytes, symlink targets, xattrs.
# Deliberately NOT compared (known lossy, see KNOWN_LIMITATIONS): mode bits,
# nlink, timestamps, and errno spellings (both sides must only agree on
# success-vs-any-error for the op shapes generated here).
#
# Determinism: random.Random(seed) only; model collections sampled in sorted
# order (never set iteration). A mismatch shrinks via ddmin and is saved to
# tests/regress/model_<seed>.json; the test then FAILS (fix the code, keep
# the seed as a permanent replay regression via test_regress_seeds).
import hashlib
import json
import os
import random
import shutil
import stat as _stat
from errno import errorcode as _errno_names

import pytest

# Fixed seeds run in CI. Bigger sweeps pass MODEL_SEEDS explicitly
# (e.g. MODEL_SEEDS=4,5,6,7,8), including in ci-nightly. Seed 4 covers the
# xattr cross-entry aliasing found by T-04 (file blob read back via its
# parent dir); it passes only with the one-chain-per-cluster fix.
SEEDS = tuple(int(s) for s in os.environ.get("MODEL_SEEDS", "1,2,3,4").split(",") if s.strip())
OPS_PER_SEED = int(os.environ.get("MODEL_OPS", "250"))

# Live-byte budget: generated growth stays under this so a 1M test image
# never fills by construction. Without it, ENOSPC-vs-success divergences
# are capacity noise (1M image vs unbounded tmpfs), not findings.
LIVE_BUDGET = 512 * 1024


class HarnessError(Exception):
    """The test rig itself is broken (dead mount, full disk): not a finding."""


def _mount_alive(root):
    try:
        os.listdir(root)
        return True
    except OSError:
        return False

NAMES_SHORT = [f"f{i:04d}" for i in range(30)]
NAMES_EDGE = [
    "a" * 15,  # inline max
    "b" * 16,  # inline full
    "c" * 17,  # LFN threshold
    "d" * 40,  # LFN
    "n" * 255,  # NAME_MAX
    ".hidden",
    "a b",
    "-dash",
    "caf\u00e9",
    "\u65e5\u672c\u8a9e",
]
XATTR_NAMES = [f"user.test{i}" for i in range(4)]


def _pick(rng, seq):
    seq = sorted(seq)
    return rng.choice(seq)


def gen_ops(seed: int, n: int):
    """Deterministic op list. Each op is a JSON-able tuple starting with a tag."""
    rng = random.Random(seed)
    ops = []
    dirs = {"/"}
    files = {}  # path -> size (model estimate, guides validity only)
    links = set()
    xattrs = {}  # path -> dict
    counter = [0]

    def live_bytes():
        return sum(files.values())

    def fresh_name():
        counter[0] += 1
        suffix = f"_{counter[0]}"
        base = rng.choice(NAMES_SHORT + NAMES_EDGE)
        # Keep the full name within NAME_MAX so over-long names only occur
        # when the pool entry itself demands it (exact-255 stays exact).
        return (base[: 255 - len(suffix)] + suffix) if len(base) + len(suffix) > 255 else base + suffix

    def existing_dir():
        return _pick(rng, dirs)

    for _ in range(n):
        r = rng.random()
        if r < 0.14 and len(dirs) < 12:
            p = existing_dir()
            name = fresh_name()
            path = (p + "/" + name).replace("//", "/")
            ops.append(("mkdir", path))
            dirs.add(path)
        elif r < 0.30:
            p = existing_dir()
            name = fresh_name()
            path = (p + "/" + name).replace("//", "/")
            ops.append(("create", path))
            files[path] = 0
            xattrs[path] = {}
        elif r < 0.48 and files:
            path = _pick(rng, files)
            off = rng.randint(0, files[path] + 4096)
            size = rng.randint(1, 4096)
            new_end = max(files[path], off + size)
            if live_bytes() - files[path] + new_end > LIVE_BUDGET:
                # Over budget: delete something instead of growing.
                victim = _pick(rng, files)
                ops.append(("unlink", victim))
                del files[victim]
                xattrs.pop(victim, None)
                continue
            data = rng.randbytes(size).hex()
            ops.append(("write", path, off, data))
            files[path] = new_end
        elif r < 0.58 and files:
            path = _pick(rng, files)
            size = rng.randint(0, 131072)
            if size > files[path] and live_bytes() - files[path] + size > LIVE_BUDGET:
                # Over budget: shrink to a smaller size instead.
                size = rng.randint(0, files[path])
            ops.append(("truncate", path, size))
            files[path] = size
        elif r < 0.68 and (files or dirs - {"/"} or links):
            src_pool = list(files) + sorted(links) + sorted(dirs - {"/"})
            src = rng.choice(sorted(src_pool))
            dst_parent = existing_dir()
            # No moving a dir under itself: dst parent must not be src-or-below.
            if src in dirs and (dst_parent == src or dst_parent.startswith(src + "/")):
                continue
            dst = (dst_parent + "/" + fresh_name()).replace("//", "/")
            # Overwrite only file->file (rename matrix beyond that is E-04).
            if dst in files or dst in links or dst in dirs and not (src in files and dst in files):
                    continue
            ops.append(("rename", src, dst))
            if src in files:
                files[dst] = files.pop(src)
                xattrs[dst] = xattrs.pop(src, {})
            elif src in links:
                links.discard(src)
                links.add(dst)
            else:
                dirs.discard(src)
                # Move children of all kinds along in the model (xattrs
                # keyed by old paths move too).
                for p in sorted(c for c in dirs if c.startswith(src + "/")):
                    dirs.discard(p)
                    dirs.add(dst + p[len(src):])
                for p in sorted(f for f in files if f.startswith(src + "/")):
                    files[dst + p[len(src):]] = files.pop(p)
                for p in sorted(link for link in links if link.startswith(src + "/")):
                    links.discard(p)
                    links.add(dst + p[len(src):])
                for p in sorted(k for k in xattrs if k.startswith(src + "/")):
                    xattrs[dst + p[len(src):]] = xattrs.pop(p)
        elif r < 0.76 and files:
            path = _pick(rng, files)
            ops.append(("unlink", path))
            del files[path]
            xattrs.pop(path, None)
        elif r < 0.80 and links:
            path = _pick(rng, links)
            ops.append(("unlink", path))
            links.discard(path)
            xattrs.pop(path, None)
        elif r < 0.84:
            # rmdir only model-empty dirs (no files/links/subdirs beneath).
            cand = [
                d for d in dirs if d != "/"
                and not any(x.startswith(d + "/") for x in list(files) + list(links))
                and not any(x.startswith(d + "/") for x in dirs if x != d)
            ]
            if cand:
                path = rng.choice(sorted(cand))
                ops.append(("rmdir", path))
                dirs.discard(path)
        elif r < 0.90:
            p = existing_dir()
            link = (p + "/" + fresh_name()).replace("//", "/")
            if link in files or link in dirs:
                continue
            if files and rng.random() < 0.7:
                # Relative target (same dir): exercises path resolution.
                target = os.path.basename(_pick(rng, files))
            else:
                target = f"dangling-{rng.randint(0, 999)}"
            ops.append(("symlink", target, link))
            links.add(link)
            xattrs[link] = {}
        elif r < 0.95:
            pool = list(files) + sorted(links) + sorted(dirs - {"/"})
            if not pool:
                continue
            path = rng.choice(sorted(pool))
            name = rng.choice(XATTR_NAMES)
            value = rng.randbytes(rng.randint(1, 256)).hex()
            ops.append(("setxattr", path, name, value))
            xattrs.setdefault(path, {})[name] = value
        else:
            pool = [p for p, d in xattrs.items() if d]
            if not pool:
                continue
            path = rng.choice(sorted(pool))
            name = rng.choice(sorted(xattrs[path]))
            ops.append(("removexattr", path, name))
            del xattrs[path][name]
    return ops


def _apply(op, root):
    """Apply one op under root. Returns (ok, errname|None)."""
    try:
        tag = op[0]
        if tag == "mkdir":
            os.mkdir(root + op[1])
        elif tag == "create":
            fd = os.open(root + op[1], os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            os.close(fd)
        elif tag == "write":
            _, path, off, data_hex = op
            data = bytes.fromhex(data_hex)
            fd = os.open(root + path, os.O_WRONLY)
            try:
                os.lseek(fd, off, os.SEEK_SET)
                view = memoryview(data)
                while view:
                    n = os.write(fd, view)
                    view = view[n:]
            finally:
                os.close(fd)
        elif tag == "truncate":
            with open(root + op[1], "r+b") as fh:
                fh.truncate(op[2])
        elif tag == "rename":
            os.rename(root + op[1], root + op[2])
        elif tag == "unlink":
            os.unlink(root + op[1])
        elif tag == "rmdir":
            os.rmdir(root + op[1])
        elif tag == "symlink":
            os.symlink(op[1], root + op[2])
        elif tag == "setxattr":
            os.setxattr(root + op[1], op[2], bytes.fromhex(op[3]))
        elif tag == "removexattr":
            os.removexattr(root + op[1], op[2])
        else:  # pragma: no cover
            raise AssertionError(f"unknown op {tag}")
        return True, None
    except OSError as e:
        return False, _errno_names.get(e.errno, str(e.errno))


def _snapshot(root):
    """relpath -> (kind, size, sha256|None, target|None, xattrs dict)."""
    out = {}
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            try:
                st = os.lstat(full)
            except FileNotFoundError:
                continue
            if _stat.S_ISLNK(st.st_mode):
                try:
                    target = os.readlink(full)
                except OSError:
                    continue
                out[rel] = ("link", 0, None, target, {})
            elif _stat.S_ISREG(st.st_mode):
                h = hashlib.sha256()
                try:
                    with open(full, "rb") as fh:
                        while True:
                            b = fh.read(65536)
                            if not b:
                                break
                            h.update(b)
                except OSError:
                    continue
                xa = {}
                try:
                    for xn in os.listxattr(full):
                        try:
                            xa[xn] = os.getxattr(full, xn)
                        except OSError:
                            pass
                except OSError:
                    pass
                out[rel] = ("file", st.st_size, h.hexdigest(), None, xa)
        # record dirs themselves (empty ones matter for rmdir agreement)
        for name in dirnames:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            if rel == ".":
                continue
            try:
                st = os.lstat(full)
            except FileNotFoundError:
                continue
            if _stat.S_ISDIR(st.st_mode):
                xa = {}
                try:
                    for xn in os.listxattr(full):
                        try:
                            xa[xn] = os.getxattr(full, xn)
                        except OSError:
                            pass
                except OSError:
                    pass
                out[rel + "/"] = ("dir", 0, None, None, xa)
    return out


def _compare(a, b):
    """Mismatch strings between fused snapshot a and reference b."""
    problems = []
    if set(a) != set(b):
        problems.append(f"entry set differs: only-fused={sorted(set(a) - set(b))} "
                        f"only-ref={sorted(set(b) - set(a))}")
    for rel in sorted(set(a) & set(b)):
        ka, sa, ha, ta, xa = a[rel]
        kb, sb, hb, tb, xb = b[rel]
        if ka != kb:
            problems.append(f"{rel}: kind {ka} vs {kb}")
            continue
        if ka == "file" and (sa != sb or ha != hb):
            problems.append(f"{rel}: content size {sa}/{sb} sha {ha}/{hb}")
        if ka == "link" and ta != tb:
            problems.append(f"{rel}: target {ta!r} vs {tb!r}")
        if xa != xb:
            problems.append(f"{rel}: xattrs differ")
    return problems


def _clear_tree(root):
    """Empty a tree's contents (never the root itself: it may be a mount)."""
    for child in os.listdir(root):
        full = os.path.join(root, child)
        if os.path.isdir(full) and not os.path.islink(full):
            shutil.rmtree(full)
        else:
            os.unlink(full)


def reset_pair(fused_root, ref_root):
    """Restore both trees to the same empty initial state.

    The fixture image ships a /Kernel demo file; it is incidental to the
    generated workload (which creates its own files from op 0), so both
    trees start empty. This keeps replay deterministic without threading
    initial bytes through shrink.
    """
    _clear_tree(fused_root)
    shutil.rmtree(ref_root, ignore_errors=True)
    os.makedirs(ref_root, exist_ok=True)


def _is_transport_dead(root):
    """True if the mount itself is unresponsive (not a test finding).

    Only transport errors count: a live daemon answering EIO is a real
    readdir failure and must surface as a mismatch, not a rig problem.
    """
    try:
        os.listdir(root)
        return False
    except OSError as e:
        import errno as _eno
        return e.errno in (_eno.ENOTCONN, _eno.ESHUTDOWN, _eno.ENOENT)


def run_sequence(ops, fused_root, ref_root):
    """Apply ops pairwise; return (op_index, op, problems) at first divergence.

    Raises HarnessError if the mount is dead: transport failures are rig
    problems, never findings (recording them as seeds would enshrine noise).
    """
    if _is_transport_dead(fused_root):
        raise HarnessError("fused mount unresponsive before run")
    for i, op in enumerate(ops):
        ok_f, err_f = _apply(op, fused_root)
        ok_r, err_r = _apply(op, ref_root)
        if ok_f != ok_r:
            if not ok_f and _is_transport_dead(fused_root):
                raise HarnessError(f"mount died at op {i} {op}")
            msg = (f"success differs: fused ok={ok_f} ({err_f}) "
                   f"ref ok={ok_r} ({err_r})")
            return i, op, [msg]
        snap_f = _snapshot(fused_root)
        snap_r = _snapshot(ref_root)
        problems = _compare(snap_f, snap_r)
        if problems:
            if _is_transport_dead(fused_root):
                raise HarnessError(f"mount died at op {i} {op}")
            return i, op, problems
    return -1, None, []


def shrink(seed_ops, fused_root, ref_root, first_index, budget=64):
    """ddmin the failing prefix: keep halving while a mismatch reproduces.

    Returns (shrunk_ops, replay_problems): the replay's own mismatch, which
    can differ from the original (state-dependent failures shrink to the
    operations that still diverge from a clean slate). Stops after `budget`
    reproductions so a pathological case can't burn the whole CI window.
    """
    prefix = list(seed_ops[:first_index + 1])
    last_problems: list = []
    calls = [0]

    def reproduces(cand):
        if calls[0] >= budget:
            return False
        calls[0] += 1
        reset_pair(fused_root, ref_root)
        _, _, problems = run_sequence(cand, fused_root, ref_root)
        if problems:
            last_problems.clear()
            last_problems.extend(problems)
            return True
        return False

    n = 2
    while len(prefix) >= 2:
        chunk = max(1, len(prefix) // n)
        reduced = False
        for start in range(0, len(prefix), chunk):
            cand = prefix[:start] + prefix[start + chunk:]
            if cand and reproduces(cand):
                prefix = cand
                n = max(2, n - 1)
                reduced = True
                break
        if not reduced:
            if chunk == 1:
                break
            n = min(len(prefix), n * 2)
    # Final confirmation on a clean slate, so the saved seed is known to
    # reproduce by itself (not just as a ddmin intermediate).
    reset_pair(fused_root, ref_root)
    _, _, final_problems = run_sequence(prefix, fused_root, ref_root)
    return prefix, list(final_problems)


def _regress_path(seed):
    here = os.path.dirname(os.path.abspath(__file__))
    d = os.path.normpath(os.path.join(here, "..", "regress"))
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, f"model_{seed}.json")


@pytest.mark.fuse
@pytest.mark.parametrize("seed", SEEDS)
def test_model_conformance(private_mount: str, tmp_path, seed: int):
    if shutil.disk_usage(str(tmp_path)).free < 512 * 1024 * 1024:
        pytest.fail("harness: /tmp has <512MiB free — clean /tmp/pytest-of-kratos* first")
    ref_root = str(tmp_path / "ref")
    os.makedirs(ref_root, exist_ok=True)
    reset_pair(private_mount, ref_root)
    ops = gen_ops(seed, OPS_PER_SEED)
    try:
        idx, op, problems = run_sequence(ops, private_mount, ref_root)
    except HarnessError as e:
        pytest.fail(f"harness failure on seed {seed} (not a finding): {e}")
        return
    if problems:
        try:
            shrunk, replay_problems = shrink(ops, private_mount, ref_root, idx)
        except HarnessError as e:
            pytest.fail(f"seed {seed}: mismatch at op {idx} {op}: {problems[:3]} "
                        f"(shrink aborted, harness failure: {e})")
            return
        if replay_problems:
            with open(_regress_path(seed), "w") as f:
                json.dump({"seed": seed, "first_failure": idx, "op": op,
                           "problems": problems[:5], "shrunk_ops": shrunk,
                           "replay_problems": replay_problems[:5]}, f, indent=2)
            pytest.fail(f"seed {seed}: mismatch at op {idx} {op}: {problems[:5]} "
                        f"(shrunk {len(ops)} -> {len(shrunk)} ops, saved "
                        f"tests/regress/model_{seed}.json)")
        else:
            # The mismatch did not survive a clean-room replay (it depended
            # on accumulated daemon/image state that reset_pair wipes, e.g.
            # free-space layout history). No seed is saved: a vacuous seed
            # would pass replay and enshrine nothing. Investigate live.
            pytest.fail(f"seed {seed}: state-dependent mismatch at op {idx} {op}: "
                        f"{problems[:3]} (shrunk {len(ops)} -> {len(shrunk)} ops did "
                        f"NOT reproduce on replay; no seed saved)")


@pytest.mark.fuse
def test_regress_seeds(private_mount: str, tmp_path):
    """Replay every committed tests/regress/model_*.json seed: must be clean."""
    import glob
    here = os.path.dirname(os.path.abspath(__file__))
    seeds = sorted(glob.glob(os.path.normpath(os.path.join(here, "..", "regress", "model_*.json"))))
    for path in seeds:
        with open(path) as f:
            rec = json.load(f)
        ref_root = str(tmp_path / "ref")
        # Start both trees empty (clear mount contents, not the mount itself).
        for child in os.listdir(private_mount):
            full = os.path.join(private_mount, child)
            if os.path.isdir(full) and not os.path.islink(full):
                shutil.rmtree(full)
            else:
                os.unlink(full)
        shutil.rmtree(ref_root, ignore_errors=True)
        os.makedirs(ref_root, exist_ok=True)
        ops = [tuple(o) for o in rec["shrunk_ops"]]
        idx, op, problems = run_sequence(ops, private_mount, ref_root)
        assert not problems, f"{os.path.basename(path)} still diverges at op {idx} {op}: {problems[:5]}"
