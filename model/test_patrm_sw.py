"""ARM software baseline on the laptop: sw/patrm_sw/patrm_sw.c against model/patrm.py warp_gray (step 4.4, part 1).

    python -m model.test_patrm_sw

Compiles sw/patrm_sw (patrm_sw.c + host_main.c) with the laptop gcc at -O2 and at -O3 (-std=c99 -Wall -Wextra
-Werror -pedantic) and compares every output byte with the model:
  [1] build, both optimisation levels
  [2] worked example (CLAUDE.md): output (3,2) -> source (3.2, 4.4), r1..r4 = 100/140/120/160
  [3] all transforms x all images (checker, gradient, grid, mixed, photo) at the simulation sizes 64x64, 128x96
  [4] all transforms at the board sizes 480x272, 800x480 and the paper size 2448x2095 (photo)
  [5] 300 seeded random transforms (D4-valid, incl. far out of range, steep, mirrored, sub-pixel) on random images,
      sizes down to 8x1 and odd heights
  [6] identity and both mirrors reproduce the input exactly (D1)
  [7] a size breaking D3 (W = 12) is rejected
  [8] the comparison notices a single wrong byte
Laptop timing (information only) is printed for 2448x2095. The last line is TEST PASS or TEST FAIL: <reason>.
The gcc is the one on PATH, else the WinLibs package that winget installs (README, New laptop setup).
"""
import glob
import os
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from model import memmodel as MM             # noqa: E402
from model import patrm as P                 # noqa: E402
from model.gen_transforms import load as load_transforms   # noqa: E402

SRC_DIR = ROOT / "sw" / "patrm_sw"
GEN = ROOT / "data" / "gen"
OUT = ROOT / "build" / "test_patrm_sw"
CFLAGS = ["-std=c99", "-Wall", "-Wextra", "-Werror", "-pedantic"]
LEVELS = ("-O2", "-O3")
IMAGES = ("checker", "gradient", "grid", "mixed", "photo")


class Fail(Exception):
    pass


def check(cond, msg):
    if not cond:
        raise Fail(msg)


def find_host_gcc():
    gcc = shutil.which("gcc")
    if gcc:
        return Path(gcc)
    pattern = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Microsoft", "WinGet", "Packages",
                           "BrechtSanders.WinLibs*", "mingw64", "bin", "gcc.exe")
    hits = sorted(glob.glob(pattern))
    return Path(hits[-1]) if hits else None


def exe(level):
    return OUT / f"patrm_sw_host{level}.exe"


def run_c(level, src, W, H, b, repeats=0):
    """Runs the C build on src (uint8 H x W); returns the output array (and the laptop time per frame in us)."""
    sp, op = OUT / "src.raw", OUT / "out.raw"
    np.ascontiguousarray(src, dtype=np.uint8).tofile(sp)
    args = [str(exe(level)), str(sp), str(W), str(H)] + [str(int(c)) for c in b] + [str(op)]
    if repeats:
        args.append(str(repeats))
    p = subprocess.run(args, capture_output=True, text=True)
    if p.returncode != 0:
        raise Fail(f"C build {level} failed on {W}x{H} b={tuple(b)}: exit {p.returncode} {p.stderr.strip()}")
    out = np.fromfile(op, dtype=np.uint8)
    check(out.size == W * H, f"C output has {out.size} bytes, expected {W * H}")
    t = [float(ln.split()[1]) for ln in p.stdout.splitlines() if ln.startswith("TIME_US")]
    return out.reshape(H, W), (t[0] if t else None)


def compare(what, src, W, H, b, levels=LEVELS):
    exp = P.warp_gray(src, W, H, b)
    for level in levels:
        got, _ = run_c(level, src, W, H, b)
        diff = np.argwhere(got != exp)
        if diff.size:
            u, v = (int(x) for x in diff[0])
            raise Fail(f"{what} {level}: {len(diff)} bytes differ, first at (u,v)=({u},{v}): C {got[u, v]}, "
                       f"model {exp[u, v]}")
    return exp


def image(kind, W, H):
    hits = sorted(GEN.glob(f"gray_{kind}*_{W}x{H}.raw"))
    check(len(hits) == 1, f"image {kind} {W}x{H}: {len(hits)} files in data/gen (run python -m model.gen_images)")
    return np.fromfile(hits[0], dtype=np.uint8).reshape(H, W)


def t1_build():
    print("[1] build")
    gcc = find_host_gcc()
    check(gcc is not None, "no laptop gcc: install it with  winget install BrechtSanders.WinLibs.POSIX.UCRT")
    ver = subprocess.run([str(gcc), "--version"], capture_output=True, text=True).stdout.splitlines()[0]
    print(f"      compiler {gcc}\n      {ver}")
    OUT.mkdir(parents=True, exist_ok=True)
    for level in LEVELS:
        p = subprocess.run([str(gcc)] + CFLAGS + [level, "-o", str(exe(level)), str(SRC_DIR / "patrm_sw.c"),
                                                  str(SRC_DIR / "host_main.c")], capture_output=True, text=True)
        check(p.returncode == 0, f"compile {level} failed:\n{p.stdout}{p.stderr}")
        print(f"      {' '.join(CFLAGS)} {level}: 0 warnings")


def t2_worked_example():
    print("[2] worked example")
    W = H = 16
    b = (52429, -39322, 131072, 39322, 52429, 65536)
    src = np.full((H, W), 50, dtype=np.uint8)
    src[3, 4], src[3, 5], src[4, 4], src[4, 5] = 100, 140, 120, 160
    exp = compare("worked example", src, W, H, b)
    X = b[0] * 3 + b[1] * 2 + b[2]
    Y = b[3] * 3 + b[4] * 2 + b[5]
    check((X >> 16, Y >> 16) == (3, 4), f"(3,2) maps to ({X / 65536:.4f}, {Y / 65536:.4f}), not (3.2, 4.4)")
    note = ("same as exact arithmetic" if exp[3, 2] == 120 else
            "exact arithmetic gives 120; the Q15.16 coefficients and the D10 weights truncate")
    print(f"      (u,v)=(3,2) -> (x,y)=({X / 65536:.5f}, {Y / 65536:.5f}); C = model = {exp[3, 2]} ({note})")


def t3_sim_sizes(tfs):
    print("[3] all transforms x all images, simulation sizes")
    n = 0
    for W, H in ((64, 64), (128, 96)):
        for kind in IMAGES:
            src = image(kind, W, H)
            for tf in tfs:
                compare(f"{kind} {tf['name']} {W}x{H}", src, W, H, MM._b_for(tf, W, H))
                n += 1
    print(f"      {n} cases x {len(LEVELS)} builds: 0 differing bytes")


def t4_board_sizes(tfs):
    print("[4] all transforms, board and paper sizes (photo)")
    n = 0
    for W, H in ((480, 272), (800, 480), (2448, 2095)):
        src = image("photo", W, H)
        for tf in tfs:
            compare(f"photo {tf['name']} {W}x{H}", src, W, H, MM._b_for(tf, W, H))
            n += 1
    print(f"      {n} cases x {len(LEVELS)} builds: 0 differing bytes")


def t5_random():
    print("[5] random transforms")
    rng = np.random.default_rng(20261121)
    sizes = [(8, 1), (8, 7), (16, 3), (24, 17), (64, 63), (136, 40), (200, 9), (256, 129)]
    n, tried, zeros, partial = 0, 0, 0, 0
    while n < 300:
        W, H = sizes[tried % len(sizes)]
        kind = tried % 3
        tried += 1
        if kind == 0:                     # rotation + scale + shift + optional mirror, via the model's helper
            fw = dict(rot_deg=float(rng.uniform(-180, 180)), sx=float(rng.uniform(0.3, 3.0)),
                      sy=float(rng.uniform(0.3, 3.0)), shift=(float(rng.uniform(-2 * H, 2 * H)),
                                                               float(rng.uniform(-2 * W, 2 * W))))
            if rng.random() < 0.3:
                fw["mirror_cols"] = True
            try:
                b = P.make_b(W, H, **fw)
            except (TypeError, ValueError):
                fw.pop("mirror_cols", None)
                b = P.make_b(W, H, **fw)
        else:                             # raw integer coefficients, incl. steep and sub-pixel steps
            lim = 4 if kind == 1 else 1
            b = tuple(int(x) for x in (rng.integers(-lim * 65536, lim * 65536 + 1),
                                       rng.integers(-lim * 65536, lim * 65536 + 1),
                                       rng.integers(-(H + 8) * 65536, (H + 8) * 65536),
                                       rng.integers(-lim * 65536, lim * 65536 + 1),
                                       rng.integers(-lim * 65536, lim * 65536 + 1),
                                       rng.integers(-(W + 8) * 65536, (W + 8) * 65536)))
            if H == 1:                    # one source row: X must be exactly 0, so pin the row part (b12 = b13 = 0)
                b = (b[0], 0, 0) + b[3:]
        try:
            P.check_transform(b, W, H)
        except ValueError:
            continue
        X, Y = P.coords(b, W, H)
        valid = (X >= 0) & (X <= (H - 1) * 65536) & (Y >= 0) & (Y <= (W - 1) * 65536)
        if not valid.any() and zeros >= 30:
            continue                      # at most 30 cases that map entirely out of range (all-zero output)
        src = rng.integers(0, 256, size=(H, W), dtype=np.uint8)
        compare(f"random #{n} {W}x{H} b={b}", src, W, H, b)
        zeros += int(not valid.any())
        partial += int(valid.any() and not valid.all())
        n += 1
    print(f"      {n} transforms ({tried - n} skipped: D4-invalid, or more fully-out cases than needed): "
          f"{zeros} entirely out of range, {partial} partly, {n - zeros - partial} entirely inside; "
          f"0 differing bytes")


def t6_exact():
    print("[6] identity and mirrors reproduce the input")
    W, H = 128, 96
    src = image("photo", W, H)
    one = 65536
    for name, b, ref in (("identity", (one, 0, 0, 0, one, 0), src),
                         ("mirror_cols", (one, 0, 0, 0, -one, (W - 1) * one), src[:, ::-1]),
                         ("mirror_rows", (-one, 0, (H - 1) * one, 0, one, 0), src[::-1, :])):
        exp = compare(name, src, W, H, b)
        check(np.array_equal(exp, ref), f"{name}: model output is not the exact {name} of the input")
    print("      identity, mirror_cols, mirror_rows: exact, C = model")


def t7_bad_size():
    print("[7] D3 size rule")
    sp = OUT / "src12.raw"
    np.zeros(12 * 4, dtype=np.uint8).tofile(sp)
    p = subprocess.run([str(exe("-O2")), str(sp), "12", "4", "65536", "0", "0", "0", "65536", "0",
                        str(OUT / "out12.raw")], capture_output=True, text=True)
    check(p.returncode != 0 and "returned -1" in p.stderr, f"W = 12 was not rejected (exit {p.returncode})")
    print("      W = 12 rejected with PATRM_SW_BAD_SIZE")


def t8_detects():
    print("[8] the comparison detects a difference")
    W, H = 64, 64
    src = image("mixed", W, H)
    b = (65536, 0, 0, 0, 65536, 0)
    got, _ = run_c("-O2", src, W, H, b)
    bad = P.warp_gray(src, W, H, b).copy()
    bad[17, 23] ^= 1
    check(np.count_nonzero(got != bad) == 1, "a single changed byte was not seen")
    print("      one flipped bit in the reference -> 1 differing byte found")


def timing():
    print("[-] laptop timing, 2448x2095 photo (information only, not a measurement for the report)")
    W, H = 2448, 2095
    src = image("photo", W, H)
    for name in ("identity", "rot15", "rot37"):
        tf = next(t for t in load_transforms() if t["name"] == name)
        for level in LEVELS:
            _, t = run_c(level, src, W, H, MM._b_for(tf, W, H), repeats=5)
            print(f"      {name:<9} {level}: {t / 1000:.1f} ms per frame")


def main():
    tfs = load_transforms()
    try:
        for t in (t1_build, t2_worked_example, lambda: t3_sim_sizes(tfs), lambda: t4_board_sizes(tfs), t5_random,
                  t6_exact, t7_bad_size, t8_detects, timing):
            t()
    except Fail as e:
        print(f"TEST FAIL: {e}")
        return 1
    print("TEST PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
