"""Step 1.3 checks for model/bayer.py.

Run from the repo root (after python -m model.gen_images and python -m model.gen_vectors):
    python -m model.test_bayer
Prints the numbers for each check, then exactly one final line: TEST PASS or TEST FAIL: <reason>.
"""

import os
import sys
import unittest

import numpy as np

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from model import bayer as BY  # noqa: E402
from model import bayer_figure as BF  # noqa: E402
from model import gen_vectors as V  # noqa: E402
from model import manifest as M  # noqa: E402
from model import patrm as P  # noqa: E402
from model.gen_images import rgb_chart  # noqa: E402

REPORT = {}
WORKED_B = (52429, -39322, 131072, 39322, 52429, 65536)


def report(n, line):
    REPORT.setdefault(n, []).append(line)


def rand_mosaic(W, H, seed):
    return np.random.default_rng(seed).integers(0, 256, size=(H, W), dtype=np.uint8)


def random_transforms(W, H, n=20, seed=2):
    rng = np.random.default_rng(seed)
    out = []
    for _ in range(n):
        fw = dict(rot_deg=float(rng.uniform(-45, 45)), sx=float(rng.uniform(0.7, 1.4)),
                  sy=float(rng.uniform(0.7, 1.4)), shift=(float(rng.uniform(-30, 30)), float(rng.uniform(-30, 30))))
        out.append((fw, P.make_b(W, H, **fw)))
    return out


def fmt_q(v):
    return f"{v} ({v / 65536:.6f})"


class Step13(unittest.TestCase):

    def test_01_worked_example(self):
        T = BY.plane_shifts(WORKED_B)
        self.assertEqual(T["B"], (39321, 45875))
        L = BY.lane_offsets(WORKED_B)
        for p in ("Gr", "Gb", "B"):
            self.assertEqual(L[p], (T[p][0] - T["R"][0], T[p][1] - T["R"][1]))
        report(1, f"b = {WORKED_B}: T_B = {T['B']} (= {T['B'][0] / 65536:.6f}, {T['B'][1] / 65536:.6f}; exact 0.6, 0.7)")
        for p in ("R", "Gr", "Gb"):
            report(1, f"T_{p} = {T[p]} (= {T[p][0] / 65536:.6f}, {T[p][1] / 65536:.6f})")
        report(1, "lane offsets T_p - T_R: " + ", ".join(f"{p} {L[p]}" for p in ("Gr", "Gb", "B")))

    def test_02_geometry(self):
        W, H = 640, 480
        rng = np.random.default_rng(20)
        maxdev = {"x": 0, "y": 0}
        ones = 0
        total = 0
        for fw, b in random_transforms(W, H):
            b11, b12, b13, b21, b22, b23 = b
            bp = BY.plane_b(b)
            for p, (orow, ocol) in BY.OFFSETS.items():
                i = rng.integers(0, H // 2, 1000).astype(np.int64)
                j = rng.integers(0, W // 2, 1000).astype(np.int64)
                Xp, Yp = P._coords_uv(bp[p], i, j)
                Xf, Yf = P._coords_uv(b, 2 * i + orow, 2 * j + ocol)
                dx = np.abs(2 * Xp.astype(np.int64) + orow * 65536 - Xf.astype(np.int64))
                dy = np.abs(2 * Yp.astype(np.int64) + ocol * 65536 - Yf.astype(np.int64))
                maxdev["x"] = max(maxdev["x"], int(dx.max()))
                maxdev["y"] = max(maxdev["y"], int(dy.max()))
                ones += int(np.count_nonzero(dx == 1) + np.count_nonzero(dy == 1))
                total += 2 * len(i)
        self.assertLessEqual(max(maxdev.values()), 1)
        report(2, f"20 random transforms (rot -45..45 deg, sx/sy 0.7..1.4, shift +/-30 px) at {W}x{H}, "
                  f"1000 random pixels per plane: max |2*X_p + o_row*65536 - X_full| = {maxdev['x']}, "
                  f"max |2*Y_p + o_col*65536 - Y_full| = {maxdev['y']} (Q15.16 LSB); "
                  f"{ones} of {total} coordinates are off by 1 LSB (D2 floor), the rest exact")

    def test_03_lane_offsets(self):
        W, H = 128, 96
        Wp, Hp = W // 2, H // 2
        mism = 0
        for fw, b in random_transforms(640, 480) + [(None, WORKED_B)]:
            bp = BY.plane_b(b)
            XR, YR = P.coords(bp["R"], Wp, Hp)
            for p, (dx, dy) in BY.lane_offsets(b).items():
                Xp, Yp = P.coords(bp[p], Wp, Hp)
                with np.errstate(over="ignore"):
                    Xs = XR + np.int32(dx)
                    Ys = YR + np.int32(dy)
                mism += int(np.count_nonzero(Xs != Xp) + np.count_nonzero(Ys != Yp))
        self.assertEqual(mism, 0)
        report(3, f"D6: coords(b_R) + (T_p - T_R) == coords(b_p) for Gr, Gb, B on every pixel of the "
                  f"{Wp}x{Hp} planes of a {W}x{H} frame, 21 transforms: {mism} mismatches")

    def test_04_identity(self):
        for W, H in ((64, 64), (640, 480)):
            raw = rand_mosaic(W, H, 4)
            out = BY.warp_bayer(raw, W, H, (65536, 0, 0, 0, 65536, 0))
            nd = int(np.count_nonzero(out != raw))
            self.assertEqual(nd, 0)
            self.assertTrue(np.array_equal(out[-1, :], raw[-1, :]) and np.array_equal(out[:, -1], raw[:, -1]))
            T = BY.plane_shifts((65536, 0, 0, 0, 65536, 0))
            self.assertTrue(all(t == (0, 0) for t in T.values()))
            report(4, f"identity {W}x{H}: {nd} differing pixels, all four planes incl. last row/column; "
                      f"all T_p = (0, 0)")

    def test_05_even_shift(self):
        W, H = 640, 480
        raw = rand_mosaic(W, H, 5)
        b = P.make_b(W, H, shift=(2, -4))
        out = BY.warp_bayer(raw, W, H, b)
        exp = np.zeros_like(raw)
        exp[2:, :W - 4] = raw[:H - 2, 4:]
        nd = int(np.count_nonzero(out != exp))
        self.assertEqual(nd, 0)
        T = BY.plane_shifts(b)
        report(5, f"shift +2 rows, -4 cols at {W}x{H}: b = {b}, T_R = {T['R']} (plane shift +1, -2), "
                  f"{nd} differing pixels vs shifted mosaic (zeros in)")

    def test_06_column_mirror_info(self):
        W, H = 640, 480
        b = P.make_b(W, H, mirror_cols=True)
        T = BY.plane_shifts(b)
        fr = {p: (T[p][0] & 0xFFFF, T[p][1] & 0xFFFF) for p in BY.PLANES}
        report(6, f"column mirror b = {b}: T_y per plane = "
               + ", ".join(f"{p} {fmt_q(T[p][1])}" for p in BY.PLANES))
        report(6, "fractions (xf, yf) of T_p: " + ", ".join(f"{p} {fr[p]}" for p in BY.PLANES)
               + "  -> yf = 32768 = 0.5 plane pixel in every plane")
        for name, raw in (("random mosaic", rand_mosaic(W, H, 6)),
                          ("colour chart mosaic", BF.rgb_to_rggb(rgb_chart(W, H)))):
            out = BY.warp_bayer(raw, W, H, b)
            pix_mirror = raw[:, ::-1]
            d = np.abs(out.astype(int) - pix_mirror.astype(int))
            # colour-correct mirror: mirror each plane, then merge (moves content by one full-res pixel)
            planes = BY.split_rggb(raw, W, H)
            plane_mirror = BY.merge_rggb({p: planes[p][:, ::-1] for p in BY.PLANES}, W, H)
            d2 = np.abs(out.astype(int) - plane_mirror.astype(int))
            zero_cols = [c for c in range(W) if not out[:, c].any() and raw[:, ::-1][:, c].any()]
            report(6, f"{name}: exact copy of pixel mirror? {bool(d.max() == 0)}; max |diff| vs pixel mirror "
                      f"{int(d.max())}, {100.0 * np.count_nonzero(d) / d.size:.1f}% pixels differ; vs plane-wise "
                      f"mirror max {int(d2.max())}, {100.0 * np.count_nonzero(d2) / d2.size:.1f}% differ; "
                      f"output columns forced to 0 (out of range, D1): {zero_cols[:4]}")
        report(6, "note: a pixel mirror of RGGB with even W yields GRBG, so no Bayer-domain warp can equal it; "
                  "the plane-wise warp blends each plane pixel with its neighbour (yf = 0.5)")

    def test_07_rejects(self):
        for (W, H) in ((648, 480), (640, 481)):
            with self.assertRaises(ValueError):
                P.check_size(W, H, "bayer")
            with self.assertRaises(ValueError):
                BY.warp_bayer(np.zeros((H, W), np.uint8), W, H, (65536, 0, 0, 0, 65536, 0))
            with self.assertRaises(ValueError):
                BY.split_rggb(np.zeros((H, W), np.uint8), W, H)
        bad = P.make_b(640, 480, sx=0.01, sy=0.01)
        with self.assertRaises(ValueError) as cm:
            BY.warp_bayer(np.zeros((480, 640), np.uint8), 640, 480, bad)
        msgs = []
        for (W, H) in ((648, 480), (640, 481)):
            try:
                P.check_size(W, H, "bayer")
            except ValueError as e:
                msgs.append(str(e))
        report(7, f"D3: \"{msgs[0]}\"; \"{msgs[1]}\" (warp_bayer and split_rggb also raise)")
        report(7, f"D4: scale 0.01 rejected: \"{cm.exception}\"")

    def test_08_psnr_info(self):
        W, H = 640, 480
        cases = [("rot 5", dict(rot_deg=5.0)), ("rot 15", dict(rot_deg=15.0)), ("rot 37", dict(rot_deg=37.0)),
                 ("combined (rot 10, scale 0.9, shift 6.5,-4.25)",
                  dict(rot_deg=10.0, sx=0.9, sy=0.9, shift=(6.5, -4.25)))]
        for img_name, rgb in (("colour chart", rgb_chart(W, H)), ("smooth sinusoids", BF.smooth_rgb(W, H))):
            parts = []
            for label, fw in cases:
                r = BF.compare(rgb, W, H, **fw)
                parts.append(f"{label}: naive {r['psnr_naive']:.2f} dB, plane-wise {r['psnr_ours']:.2f} dB")
            report(8, f"{img_name} {W}x{H}: " + "; ".join(parts))

    def test_09_vectors(self):
        man = M.load()
        bay = [e for e in man["vectors"] if e["kind"].startswith("bayer_")]
        gray = [e for e in man["vectors"] if not e["kind"].startswith("bayer_")]
        self.assertGreater(len(bay), 0, "no Bayer vectors in the manifest")
        bad_b = sum(M.sha256_file(os.path.join(M.DATA_DIR, e["file"])) != e["sha256"] for e in bay)
        bad_g = sum(M.sha256_file(os.path.join(M.DATA_DIR, e["file"])) != e["sha256"] for e in gray)
        self.assertEqual(bad_b, 0)
        self.assertEqual(bad_g, 0)
        exps = [e for e in bay if e["kind"].startswith("bayer_exp")]
        npix = 0
        for e in exps:
            stem = os.path.basename(e["file"])[len("exp_"):-len(".hex")]
            W, H, b, T = V.read_cfg(os.path.join(V.DEFAULT_OUT, f"cfg_{stem}.txt"))
            self.assertEqual(T, BY.plane_shifts(b), stem)
            src = np.frombuffer(V.read_hex(os.path.join(V.DEFAULT_OUT, f"src_{stem}.hex")), np.uint8)
            exp = np.frombuffer(V.read_hex(os.path.join(V.DEFAULT_OUT, f"exp_{stem}.hex")), np.uint8)
            out = BY.warp_bayer(src.reshape(H, W), W, H, b)
            self.assertEqual(int(np.count_nonzero(out.ravel() != exp)), 0, stem)
            npix += W * H
        report(9, f"{len(bay)} Bayer vector files ({len(exps)} frames): SHA-256 match ({bad_b} mismatches); "
                  f"exp_rggb == warp_bayer(src_rggb) re-read from files, 0 differing bytes of {npix}; "
                  f"cfg T_p == plane_shifts(b) in every frame")
        report(9, f"existing gray vectors: {len(gray)} entries, {bad_g} SHA-256 mismatches (unchanged)")


def main():
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Step13)
    res = unittest.TextTestRunner(stream=sys.stderr, verbosity=2).run(suite)
    for n in sorted(REPORT):
        for line in REPORT[n]:
            print(f"[{n}] {line}")
    sys.stdout.flush()
    if res.wasSuccessful():
        print("TEST PASS")
        return 0
    first = (res.failures + res.errors)[0]
    print(f"TEST FAIL: {first[0].id().split('.')[-1]}: {first[1].strip().splitlines()[-1]}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
