"""Bayer figure and quality numbers for the slides (step 1.3, information only).

    python -m model.bayer_figure [--out results/bayer_step1_3.png]

RGB colour chart -> RGGB mosaic -> warp, two ways, each followed by a simple bilinear demosaic:
  NAIVE: the raw mosaic warped as if it were a grayscale image (patrm.warp_gray at full size)
  OURS:  plane-wise warp (bayer.warp_bayer)
Reference: float64 bilinear warp of the RGB image (unquantised b), per channel.
PSNR is computed over pixels whose float source coordinate lies at least MARGIN px inside the source.
"""

import argparse
import math
import os
import sys

import numpy as np

from model import bayer as BY
from model import patrm as P
from model.gen_images import rgb_chart, rgb_to_rggb

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(ROOT, "results", "bayer_step1_3.png")
MARGIN = 2


def smooth_rgb(W, H):
    """Low-frequency synthetic RGB image (no hard edges), for a second PSNR number."""
    u, v = np.meshgrid(np.arange(H, dtype=np.float64), np.arange(W, dtype=np.float64), indexing="ij")
    r = 128 + 100 * np.sin(2 * np.pi * v / 97.0)
    g = 128 + 100 * np.cos(2 * np.pi * u / 71.0)
    b = 128 + 100 * np.sin(2 * np.pi * (u + v) / 131.0)
    return np.clip(np.rint(np.stack([r, g, b], axis=2)), 0, 255).astype(np.uint8)


def float_rgb_warp(rgb, W, H, b_float):
    return np.stack([P.float_reference(rgb[..., c], W, H, b_float) for c in range(3)], axis=2)


def interior_mask(W, H, b_float, margin=MARGIN):
    b11, b12, b13, b21, b22, b23 = b_float
    u, v = np.meshgrid(np.arange(H, dtype=np.float64), np.arange(W, dtype=np.float64), indexing="ij")
    x = b11 * u + b12 * v + b13
    y = b21 * u + b22 * v + b23
    return (x >= margin) & (x <= H - 1 - margin) & (y >= margin) & (y <= W - 1 - margin)


def psnr(a, b, mask):
    d = (a.astype(np.float64) - b.astype(np.float64))[mask]
    mse = float(np.mean(d * d))
    return float("inf") if mse == 0 else 10 * math.log10(255.0 ** 2 / mse)


def compare(rgb, W, H, **forward):
    """Returns dict with the images and PSNRs of naive and plane-wise against the float RGB reference."""
    bf = P.make_b_float(W, H, **forward)
    bi = P.quantise_b(bf)
    mosaic = rgb_to_rggb(rgb)
    ref = float_rgb_warp(rgb, W, H, bf)
    naive = BY.demosaic_bilinear(P.warp_gray(mosaic, W, H, bi))
    ours = BY.demosaic_bilinear(BY.warp_bayer(mosaic, W, H, bi))
    m = interior_mask(W, H, bf)
    return dict(b=bi, mosaic=mosaic, ref=ref, naive=naive, ours=ours, mask=m,
                psnr_naive=psnr(naive, ref, m), psnr_ours=psnr(ours, ref, m), npix=int(m.sum()))


def main(argv=None):
    from PIL import Image, ImageDraw
    p = argparse.ArgumentParser(prog="python -m model.bayer_figure")
    p.add_argument("--out", default=DEFAULT_OUT)
    a = p.parse_args(argv)
    W, H = 640, 480
    rgb = rgb_chart(W, H)
    r = compare(rgb, W, H, rot_deg=15.0)

    def to_img(x):
        x = np.clip(np.floor(np.asarray(x, dtype=np.float64) + 0.5), 0, 255).astype(np.uint8)
        return Image.fromarray(x).convert("RGB")

    TW, TH, PAD, LAB = 320, 240, 8, 30
    crop = (210, 270, 280, 360)            # rows, cols of the zoomed region (output pixels)
    cr = lambda x: np.asarray(x)[crop[0]:crop[1], crop[2]:crop[3]]
    panels = [
        ("1. RGB colour chart (source)", to_img(rgb), False),
        ("2. RGGB mosaic (what the sensor gives)", to_img(r["mosaic"]), False),
        ("3. Reference: float RGB warp, 15 deg", to_img(r["ref"]), False),
        (f"4. NAIVE: mosaic warped as gray\n   + demosaic, PSNR {r['psnr_naive']:.1f} dB", to_img(r["naive"]), False),
        (f"5. OURS: plane-wise warp_bayer\n   + demosaic, PSNR {r['psnr_ours']:.1f} dB", to_img(r["ours"]), False),
        ("6. (empty)", None, False),
        ("7. zoom x4: reference", to_img(cr(r["ref"])), True),
        ("8. zoom x4: NAIVE", to_img(cr(r["naive"])), True),
        ("9. zoom x4: OURS", to_img(cr(r["ours"])), True),
    ]
    sheet = Image.new("RGB", (3 * TW + 4 * PAD, 3 * (TH + LAB + PAD) + PAD + 20), (255, 255, 255))
    d = ImageDraw.Draw(sheet)
    d.text((PAD, 4), f"Bayer RGGB warp, {W}x{H} (W x H), rotate 15 deg about centre. PSNR vs reference over "
                     f"{r['npix']} interior pixels. Zoom region: rows {crop[0]}-{crop[1]}, cols {crop[2]}-{crop[3]}.",
           fill=(0, 0, 0))
    for k, (label, img, zoom) in enumerate(panels):
        x = PAD + (k % 3) * (TW + PAD)
        y = 20 + PAD + (k // 3) * (TH + LAB + PAD)
        if img is None:
            d.text((x, y), "PSNR is computed against panel 3.\nHigher = closer to the float RGB warp.\n\n"
                           "NAIVE mixes R, G and B samples\nbecause the warp moves the colour\nfilter phase.",
                   fill=(0, 0, 0))
            continue
        d.multiline_text((x, y), label, fill=(0, 0, 0))
        th = img.resize((TW, TH), Image.NEAREST if zoom else Image.BILINEAR)
        sheet.paste(th, (x, y + LAB))
        d.rectangle((x - 1, y + LAB - 1, x + TW, y + LAB + TH), outline=(0, 0, 0))
        if k < 6 and k >= 2:
            # mark the zoom region on the output panels
            sx, sy = TW / W, TH / H
            d.rectangle((x + crop[2] * sx, y + LAB + crop[0] * sy, x + crop[3] * sx, y + LAB + crop[1] * sy),
                        outline=(255, 0, 255))
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    sheet.save(a.out, optimize=True)
    print(f"bayer_figure: PSNR naive {r['psnr_naive']:.2f} dB, plane-wise {r['psnr_ours']:.2f} dB "
          f"-> {os.path.relpath(a.out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
