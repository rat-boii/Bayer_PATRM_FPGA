"""Image quality of our fixed-point warp against an ideal floating-point bilinear warp: PSNR and SSIM.

    python scripts/quality_metrics.py            -> results/quality/psnr_ssim.txt

What is measured: the integer warp of model/patrm.py (Q15.16 coefficients from D5 quantisation, D10 integer weights,
truncation to 8 bits) and model/bayer.py (plane-wise, integer T_p of D2) against model/patrm.float_reference() with the
unquantised float coefficients (float64, no rounding). The FPGA output is bit-exact with the integer model on every
board case (0 differing bytes), so these numbers are the hardware's numbers. They measure only the cost of the
fixed-point arithmetic, not the bilinear method itself.

PSNR = 10 log10(255^2 / MSE) over all W x H pixels (outside-the-source pixels are 0 in both). SSIM: mean SSIM with a
7 x 7 uniform window, K1 = 0.01, K2 = 0.03, L = 255 (the scikit-image defaults), computed here without scipy/skimage.
Also reported: largest absolute error and the share of pixels equal to floor(float) (truncation of the ideal value).
"""
import json
import math
import sys
import time
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))
from model import patrm as P            # noqa: E402
from model import bayer as BY           # noqa: E402

GEN = REPO / "data" / "gen"
OUT = REPO / "results" / "quality" / "psnr_ssim.txt"
GRAY = [("photo-mk-480x272", 2448, 2095), ("photo-mk-480x272", 800, 480)]
BAYER = [("photo-mk-480x272", 2448, 2048), ("photo-mk-480x272", 800, 480)]


def box7(a):
    """7 x 7 mean over 'valid' windows via an integral image."""
    s = np.pad(a, ((1, 0), (1, 0))).cumsum(0).cumsum(1)
    k = 7
    return (s[k:, k:] - s[:-k, k:] - s[k:, :-k] + s[:-k, :-k]) / (k * k)


def ssim(x, y, L=255.0):
    x = x.astype(np.float64)
    y = y.astype(np.float64)
    c1, c2 = (0.01 * L) ** 2, (0.03 * L) ** 2
    mx, my = box7(x), box7(y)
    n = 49
    vx = (box7(x * x) - mx * mx) * n / (n - 1)
    vy = (box7(y * y) - my * my) * n / (n - 1)
    cxy = (box7(x * y) - mx * my) * n / (n - 1)
    s = ((2 * mx * my + c1) * (2 * cxy + c2)) / ((mx * mx + my * my + c1) * (vx + vy + c2))
    return float(s.mean())


def psnr(out, ref):
    mse = float(np.mean((out.astype(np.float64) - ref) ** 2))
    return math.inf if mse == 0 else 10 * math.log10(255.0 ** 2 / mse)


def stats(out, ref):
    err = np.abs(out.astype(np.float64) - ref)
    return dict(psnr=psnr(out, ref), ssim=ssim(out, ref), maxerr=float(err.max()),
                floor_eq=float(np.mean(out.astype(np.int64) == np.floor(ref + 1e-9).astype(np.int64))) * 100)


def bayer_float(raw, W, H, bf):
    """Float reference for Bayer: each plane warped with float coefficients and float shift t_p = ((A-I)o + t)/2."""
    b11, b12, b13, b21, b22, b23 = bf
    planes = BY.split_rggb(raw, W, H)
    full = np.zeros((H, W))
    for p, (orow, ocol) in BY.OFFSETS.items():
        tx = ((b11 - 1) * orow + b12 * ocol + b13) / 2
        ty = (b21 * orow + (b22 - 1) * ocol + b23) / 2
        full[orow::2, ocol::2] = P.float_reference(planes[p], W // 2, H // 2, (b11, b12, tx, b21, b22, ty))
    return full


def main():
    tfs = json.loads((REPO / "model" / "transforms.json").read_text(encoding="utf-8"))["transforms"]
    lines = [f"PSNR / SSIM of the fixed-point warp (= FPGA output, bit-exact) against an ideal float64 bilinear warp",
             f"scripts/quality_metrics.py, {time.strftime('%Y-%m-%d %H:%M')}. PSNR in dB over all pixels; SSIM 7x7 uniform, "
             f"L = 255; max err in grey levels; floor = share of pixels equal to the truncated ideal value.", ""]
    for kind, title, cases in (("gray", "Grayscale (model/patrm.warp_gray)", GRAY),
                               ("bayer", "Bayer, plane-wise (model/bayer.warp_bayer, = Option A and Option B)", BAYER)):
        for name, W, H in cases:
            path = GEN / f"{'gray' if kind == 'gray' else 'rggb'}_{name}_{W}x{H}.raw"
            src = np.fromfile(path, dtype=np.uint8).reshape(H, W)
            lines.append(f"{title}, {path.name}")
            lines.append(f"  {'transform':12} {'PSNR dB':>8} {'SSIM':>8} {'max err':>8} {'floor %':>8}")
            for t in tfs:
                fw = dict(t["forward"])
                if "shift" in fw:
                    fw["shift"] = tuple(fw["shift"])
                bf = P.make_b_float(W, H, **fw)
                bi = tuple(int(c) for c in P.quantise_b(bf))
                if kind == "gray":
                    out = P.warp_gray(src, W, H, bi)
                    ref = P.float_reference(src, W, H, bf)
                else:
                    out = BY.warp_bayer(src, W, H, bi)
                    ref = bayer_float(src, W, H, bf)
                s = stats(out, ref)
                lines.append(f"  {t['name']:12} {s['psnr']:8.2f} {s['ssim']:8.5f} {s['maxerr']:8.2f} {s['floor_eq']:8.2f}")
                print(lines[-1], flush=True)
            lines.append("")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {OUT.relative_to(REPO)}")


if __name__ == "__main__":
    main()
