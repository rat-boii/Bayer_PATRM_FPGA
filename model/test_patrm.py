"""Step 1.1 checks for model/patrm.py (unittest, numpy only).

Run from the repo root:  python -m model.test_patrm   (or: python model/test_patrm.py)
Prints the measured numbers for each check, then exactly one final line: TEST PASS or TEST FAIL: <reason>.
"""

import math
import os
import sys
import tempfile
import time
import unittest

import numpy as np

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from model import patrm as P  # noqa: E402

REPORT = {}          # check number -> list of lines


def report(n, line):
    REPORT.setdefault(n, []).append(line)


def rand_img(W, H, seed):
    return np.random.default_rng(seed).integers(0, 256, size=(H, W), dtype=np.uint8)


WORKED_B = (52429, -39322, 131072, 39322, 52429, 65536)

# Transforms for checks 6 and 8: (label, forward params)
TRANSFORMS = [
    ("rot 5 deg", dict(rot_deg=5.0)),
    ("rot 15 deg", dict(rot_deg=15.0)),
    ("rot 37 deg", dict(rot_deg=37.0)),
    ("scale 0.8", dict(sx=0.8, sy=0.8)),
    ("scale 1.25", dict(sx=1.25, sy=1.25)),
    ("combined rot 20, sx 1.1, sy 0.9, shift (7.3,-4.6), col mirror",
     dict(rot_deg=20.0, sx=1.1, sy=0.9, shift=(7.3, -4.6), mirror_cols=True)),
]


class Step11(unittest.TestCase):

    def test_01_worked_example(self):
        b = WORKED_B
        u, v = 3, 2
        # Place r1..r4 at the neighbours of (u,v) in an otherwise random 64x64 image.
        W = H = 64
        src = rand_img(W, H, 1)
        X, Y = P.coords(b, W, H)
        x0, y0 = int(X[u, v]) >> 16, int(Y[u, v]) >> 16
        src[x0, y0], src[x0, y0 + 1], src[x0 + 1, y0], src[x0 + 1, y0 + 1] = 100, 140, 120, 160
        d = P.dump_stream(os.path.join(tempfile.gettempdir(), "patrm_worked.npz"), src, W, H, b,
                          region=(u, v, 1, 1))
        got = {k: int(d[k][0]) for k in P.DUMP_FIELDS}
        exp = dict(X=209715, Y=288360, x0=3, xf=13107, y0=4, yf=26216, r1=100, r2=140, r3=120, r4=160,
                   w1=31458, w2=20972, w3=7863, w4=5243, valid=1, D=120)
        for k, e in exp.items():
            self.assertEqual(got[k], e, f"worked example {k}")
        self.assertEqual(sum(got[k] for k in ("w1", "w2", "w3", "w4")), 65536)
        self.assertEqual(int(P.warp_gray(src, W, H, b)[u, v]), 120)
        self.assertEqual(P.warp_gray_scalar(src, W, H, b, pixels=[(u, v)])[0], 120)
        report(1, "worked example: " + ", ".join(f"{k}={got[k]}" for k in
               ("X", "Y", "x0", "xf", "y0", "yf", "w1", "w2", "w3", "w4", "D")))
        # make_b: inverse rotation with cos 0.8 / sin 0.6 and inverse shift (2,1).
        # Forward parameters: rotation -atan2(0.6, 0.8) = -36.8699 deg (clockwise), about the origin,
        # forward shift = -R*(2,1) = (-2.2, 0.4).
        rot = -math.degrees(math.atan2(0.6, 0.8))
        bf = P.make_b_float(W, H, rot_deg=rot, shift=(-2.2, 0.4), about="origin")
        bi = P.make_b(W, H, rot_deg=rot, shift=(-2.2, 0.4), about="origin")
        self.assertEqual(bi, WORKED_B)
        report(1, f"make_b(rot={rot:.4f} deg, shift=(-2.2, 0.4), about origin): float b = "
               + ", ".join(f"{c:.6f}" for c in bf) + f" -> {bi}  (matches)")
        # Same b straight from the inverse floats (0.8, -0.6, 2, 0.6, 0.8, 1).
        self.assertEqual(P.quantise_b((0.8, -0.6, 2, 0.6, 0.8, 1)), WORKED_B)

    def test_02_identity(self):
        for W, H in ((64, 64), (640, 480)):
            src = rand_img(W, H, 2)
            b = P.make_b(W, H)
            self.assertEqual(b, (65536, 0, 0, 0, 65536, 0))
            out = P.warp_gray(src, W, H, b)
            ndiff = int(np.count_nonzero(out != src))
            self.assertEqual(ndiff, 0, f"identity {W}x{H}")
            report(2, f"identity {W}x{H}: {ndiff} differing pixels (last row and column included)")

    def test_03_integer_shift(self):
        W, H = 640, 480
        src = rand_img(W, H, 3)
        b = P.make_b(W, H, shift=(5, -3))
        self.assertEqual(b, (65536, 0, -5 * 65536, 0, 65536, 3 * 65536))
        exp = np.zeros_like(src)
        exp[5:, :W - 3] = src[:H - 5, 3:]
        out = P.warp_gray(src, W, H, b)
        ndiff = int(np.count_nonzero(out != exp))
        self.assertEqual(ndiff, 0)
        report(3, f"shift +5 rows, -3 cols at {W}x{H}: b={b}, {ndiff} differing pixels vs shifted copy "
               f"(top 5 rows and right 3 columns are 0)")

    def test_04_mirrors(self):
        for W, H in ((64, 64), (640, 480)):
            src = rand_img(W, H, 4)
            bc = P.make_b(W, H, mirror_cols=True)
            br = P.make_b(W, H, mirror_rows=True)
            self.assertEqual(bc, (65536, 0, 0, 0, -65536, (W - 1) * 65536))
            self.assertEqual(br, (-65536, 0, (H - 1) * 65536, 0, 65536, 0))
            nc = int(np.count_nonzero(P.warp_gray(src, W, H, bc) != src[:, ::-1]))
            nr = int(np.count_nonzero(P.warp_gray(src, W, H, br) != src[::-1, :]))
            self.assertEqual(nc, 0)
            self.assertEqual(nr, 0)
            report(4, f"{W}x{H}: column mirror (b22=-1, b23=W-1) {nc} diffs; row mirror (b11=-1, b13=H-1) "
                      f"{nr} diffs")

    def test_05_flat_255(self):
        W, H = 640, 480
        src = np.full((H, W), 255, dtype=np.uint8)
        b = P.make_b(W, H, rot_deg=15.0)
        X, Y = P.coords(b, W, H)
        valid = P._interp(src, W, H, X, Y)["valid"]
        out = P.warp_gray(src, W, H, b)
        nvalid = int(valid.sum())
        bad = int(np.count_nonzero(out[valid] != 255))
        self.assertGreater(nvalid, 0)
        self.assertEqual(bad, 0)
        self.assertEqual(int(np.count_nonzero(out[~valid])), 0)
        report(5, f"flat 255, rot 15 deg, {W}x{H}: {nvalid} valid pixels, {bad} not 255; "
                  f"{W * H - nvalid} invalid pixels all 0")

    def test_06_blocked_equals_direct(self):
        cases = 0
        for (W, H) in ((128, 96), (640, 480)):
            lens = (1, 7, 16, 64, W)
            for label, fw in TRANSFORMS[:5]:
                b = P.make_b(W, H, **fw)
                X, Y = P.coords(b, W, H)
                for L in lens:
                    for rows in ((None, 1, 5) if W == 128 else (None,)):
                        if W == 640 and L in (1, W):
                            continue  # covered at 128x96; slow loops at full size
                        Xb, Yb = P.coords_blocked(b, W, H, L, block_rows=rows)
                        self.assertTrue(np.array_equal(X, Xb) and np.array_equal(Y, Yb),
                                        f"{label} {W}x{H} L={L} rows={rows}")
                        cases += 1
        # A transform whose intermediate sums wrap past 32 bits but whose final coordinates fit.
        W, H = 128, 96
        big = (65536, 0x7FFF0000, -0x7FFF0000, 0, 65536, 0)   # X wraps for v >= 1, b12*v huge
        X, Y = P.coords(big, W, H)
        for L in (1, 7, 16, 64, W):
            Xb, Yb = P.coords_blocked(big, W, H, L)
            self.assertTrue(np.array_equal(X, Xb) and np.array_equal(Y, Yb))
            cases += 1
        report(6, f"coords_blocked == coords in {cases}/{cases} cases: block lengths 1, 7, 16, 64, W; "
                  f"rot 5/15/37 deg, scale 0.8/1.25; 128x96 (block rows H, 1, 5) and 640x480 "
                  f"(L=7,16,64); plus a 32-bit wrap case")

    def test_07_vector_vs_scalar(self):
        W, H = 640, 480
        src = rand_img(W, H, 7)
        b = P.make_b(W, H, rot_deg=37.0)
        out = P.warp_gray(src, W, H, b)
        rng = np.random.default_rng(70)
        us = rng.integers(0, H, 2000)
        vs = rng.integers(0, W, 2000)
        pix = list(zip(us.tolist(), vs.tolist()))
        sc = P.warp_gray_scalar(src, W, H, b, pixels=pix)
        vec = [int(out[u, v]) for u, v in pix]
        ndiff = sum(1 for a, c in zip(vec, sc) if a != c)
        nvalid = sum(1 for a in sc if a != 0)
        self.assertEqual(ndiff, 0)
        # Whole-frame scalar on a small image as well.
        W2, H2 = 64, 64
        s2 = rand_img(W2, H2, 71)
        b2 = P.make_b(W2, H2, rot_deg=37.0, sx=1.1, sy=0.9)
        n2 = int(np.count_nonzero(P.warp_gray(s2, W2, H2, b2) != P.warp_gray_scalar(s2, W2, H2, b2)))
        self.assertEqual(n2, 0)
        report(7, f"vectorised vs scalar, rot 37 deg {W}x{H}: {ndiff} of 2000 random pixels differ "
                  f"({nvalid} non-zero); full 64x64 frame (rot 37, scale 1.1/0.9): {n2} differ")

    def test_08_vs_float(self):
        W, H = 640, 480
        src = rand_img(W, H, 8)
        for label, fw in TRANSFORMS:
            bf = P.make_b_float(W, H, **fw)
            bi = P.quantise_b(bf)
            P.check_transform(bi, W, H)
            out = P.warp_gray(src, W, H, bi).astype(np.int64)
            fq = P.float_reference(src, W, H, [c / 65536.0 for c in bi])
            d = out - np.floor(fq).astype(np.int64)
            X, Y = P.coords(bi, W, H)
            valid = P._interp(src, W, H, X, Y)["valid"]
            mx = int(np.abs(d).max())
            nd = int(np.count_nonzero(d))
            self.assertLessEqual(mx, 1, label)
            fu = P.float_reference(src, W, H, bf)
            du = out - np.floor(fu).astype(np.int64)
            report(8, f"{label}: quantised b -> max |model - floor(float)| = {mx}, differing "
                      f"{nd}/{W * H} = {100.0 * nd / (W * H):.4f}% of all, "
                      f"{100.0 * nd / max(1, int(valid.sum())):.4f}% of {int(valid.sum())} valid | "
                      f"info, unquantised b: max {int(np.abs(du).max())}, "
                      f"differing {100.0 * np.count_nonzero(du) / (W * H):.4f}%")

    def test_09_rejects(self):
        W, H = 640, 480
        bad = P.make_b(W, H, sx=0.01, sy=0.01)        # 100x zoom-out: corner (0,W-1) maps to ~31600 px
        with self.assertRaises(ValueError) as cm:
            P.check_transform(bad, W, H)
        with self.assertRaises(ValueError):
            P.warp_gray(rand_img(W, H, 9), W, H, bad)
        msg_t = str(cm.exception)
        with self.assertRaises(ValueError) as cm2:
            P.check_size(644, 480, "gray")
        msg_s = str(cm2.exception)
        with self.assertRaises(ValueError):
            P.warp_gray(rand_img(644, 480, 9), 644, 480, (65536, 0, 0, 0, 65536, 0))
        with self.assertRaises(ValueError):
            P.check_size(648, 480, "bayer")      # not a multiple of 16
        with self.assertRaises(ValueError):
            P.check_size(640, 481, "bayer")      # odd height
        P.check_size(640, 480, "bayer")
        P.check_transform(P.make_b(W, H, rot_deg=37.0), W, H)
        report(9, f"D4 raises for scale 0.01 (b={bad}): \"{msg_t}\"")
        report(9, f"D3 raises for W=644: \"{msg_s}\"; Bayer 648x480 and 640x481 also rejected")

    def test_10_timing(self):
        W, H = 2448, 2095
        src = rand_img(W, H, 10)
        b = P.make_b(W, H, rot_deg=15.0)
        t0 = time.perf_counter()
        P.warp_gray(src, W, H, b)
        dt = time.perf_counter() - t0
        report(10, f"info: warp_gray 2448x2095 (W x H), rot 15 deg: {dt:.2f} s on this laptop")


def main():
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Step11)
    res = unittest.TextTestRunner(stream=sys.stderr, verbosity=2).run(suite)
    for n in sorted(REPORT):
        for line in REPORT[n]:
            print(f"[{n}] {line}")
    sys.stdout.flush()
    if res.wasSuccessful():
        print("TEST PASS")
        return 0
    first = (res.failures + res.errors)[0]
    reason = first[1].strip().splitlines()[-1]
    print(f"TEST FAIL: {first[0].id().split('.')[-1]}: {reason}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
