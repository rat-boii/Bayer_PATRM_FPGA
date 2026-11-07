"""Deterministic test images (step 1.2). Raw GRAY8 / raw RGGB8, row-major, no header.

    python -m model.gen_images [--photos data/photos] [--out data/gen] [--update-manifest | --rewrite-manifest]

Grayscale (every size in GRAY_SIZES):  gray_<kind>_<W>x<H>.raw
    kinds: checker, gradient, grid, mixed (synthetic), photo-<name> (each JPG/PNG in data/photos/)
Bayer RGGB (every size in BAYER_SIZES, D3): rggb_<kind>_<W>x<H>.raw
    kinds: chart (synthetic RGB colour chart), photo-<name>
All synthetic content is analytic (no randomness); photos are converted with Pillow
(convert('RGB'), centre crop to W:H, LANCZOS resize, convert('L') for gray).
"""

import argparse
import os
import re
import sys

import numpy as np

from model import manifest as M
from model.patrm import check_size

SIM_SIZES = [(64, 64), (128, 96), (256, 192)]
BOARD_SIZES = [(480, 272), (640, 480), (800, 480), (1920, 1080), (2448, 2048)]
PAPER_SIZE = (2448, 2095)                              # gray only (H odd -> not a Bayer size)
GRAY_SIZES = SIM_SIZES + BOARD_SIZES + [PAPER_SIZE]    # all W x H
BAYER_SIZES = [s for s in GRAY_SIZES if s[0] % 16 == 0 and s[1] % 2 == 0]
SYNTH_KINDS = ("checker", "gradient", "grid", "mixed")
PHOTO_EXT = (".jpg", ".jpeg", ".png")

DEFAULT_OUT = os.path.join(M.DATA_DIR, "gen")
DEFAULT_PHOTOS = os.path.join(M.DATA_DIR, "photos")


# ---------------------------------------------------------------------------
# Synthetic grayscale patterns, uint8 (H, W)
# ---------------------------------------------------------------------------

def _uv(W, H):
    return np.meshgrid(np.arange(H, dtype=np.int64), np.arange(W, dtype=np.int64), indexing="ij")


def checker(W, H):
    c = max(4, min(W, H) // 12)
    u, v = _uv(W, H)
    return (((u // c + v // c) % 2) * 255).astype(np.uint8)


def gradient(W, H):
    """Rows and columns both ramp 0..255; value = mean of the two ramps."""
    u, v = _uv(W, H)
    return (((u * 255) // max(1, H - 1) + (v * 255) // max(1, W - 1)) // 2).astype(np.uint8)


def grid(W, H):
    n = max(8, W // 20)
    img = np.full((H, W), 16, dtype=np.uint8)
    img[::n, :] = 240
    img[:, ::n] = 240
    img[-1, :] = 240
    img[:, -1] = 240
    return img


def mixed(W, H):
    """Quadrants: flat white | gradient / checkerboard | white disc on dark."""
    h2, w2 = H // 2, W // 2
    img = np.empty((H, W), dtype=np.uint8)
    img[:h2, :w2] = 255
    img[:h2, w2:] = gradient(W - w2, h2)
    img[h2:, :w2] = checker(w2, H - h2)
    hh, ww = H - h2, W - w2
    u, v = _uv(ww, hh)
    r = 0.4 * min(hh, ww)
    disc = (u - (hh - 1) / 2.0) ** 2 + (v - (ww - 1) / 2.0) ** 2 <= r * r
    img[h2:, w2:] = np.where(disc, 255, 20).astype(np.uint8)
    return img


SYNTH = {"checker": checker, "gradient": gradient, "grid": grid, "mixed": mixed}


def rgb_chart(W, H):
    """Synthetic RGB colour chart (H, W, 3): 8 colour bars on top, R/G ramps and a blue disc below."""
    img = np.zeros((H, W, 3), dtype=np.uint8)
    h2 = H // 2
    bars = [(255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
            (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0)]
    for i, col in enumerate(bars):
        img[:h2, (i * W) // 8:((i + 1) * W) // 8] = col
    u, v = _uv(W, H - h2)
    img[h2:, :, 0] = (v * 255 // max(1, W - 1)).astype(np.uint8)
    img[h2:, :, 1] = (u * 255 // max(1, H - h2 - 1)).astype(np.uint8)
    r = 0.35 * min(H - h2, W)
    disc = (u - (H - h2 - 1) / 2.0) ** 2 + (v - (W - 1) / 2.0) ** 2 <= r * r
    img[h2:, :, 2] = np.where(disc, 255, 0).astype(np.uint8)
    return img


def rgb_to_rggb(rgb):
    """Mosaic an RGB image (H, W, 3) to RGGB (H, W): R (0,0), Gr (0,1), Gb (1,0), B (1,1)."""
    rgb = np.asarray(rgb)
    if rgb.ndim != 3 or rgb.shape[2] != 3:
        raise ValueError("rgb must have shape (H, W, 3)")
    out = np.empty(rgb.shape[:2], dtype=rgb.dtype)
    out[0::2, 0::2] = rgb[0::2, 0::2, 0]   # R
    out[0::2, 1::2] = rgb[0::2, 1::2, 1]   # Gr
    out[1::2, 0::2] = rgb[1::2, 0::2, 1]   # Gb
    out[1::2, 1::2] = rgb[1::2, 1::2, 2]   # B
    return out


# ---------------------------------------------------------------------------
# Photos
# ---------------------------------------------------------------------------

def find_photos(photo_dir):
    if not os.path.isdir(photo_dir):
        return []
    return sorted(os.path.join(photo_dir, f) for f in os.listdir(photo_dir)
                  if f.lower().endswith(PHOTO_EXT))


def photo_name(path):
    return re.sub(r"[^A-Za-z0-9]+", "-", os.path.splitext(os.path.basename(path))[0]).strip("-").lower()


def photo_rgb(path, W, H):
    """Centre-crop to W:H and resize to W x H. Returns uint8 (H, W, 3)."""
    from PIL import Image
    with Image.open(path) as im:
        im = im.convert("RGB")
        sw, sh = im.size
        if sw * H > sh * W:            # too wide: crop columns
            cw, ch = (sh * W) // H, sh
        else:                          # too tall: crop rows
            cw, ch = sw, (sw * H) // W
        x0, y0 = (sw - cw) // 2, (sh - ch) // 2
        im = im.crop((x0, y0, x0 + cw, y0 + ch)).resize((W, H), Image.LANCZOS)
        return np.asarray(im, dtype=np.uint8).copy()


def photo_gray(path, W, H):
    from PIL import Image
    return np.asarray(Image.fromarray(photo_rgb(path, W, H)).convert("L"), dtype=np.uint8).copy()


# ---------------------------------------------------------------------------

def write_raw(path, img):
    img = np.ascontiguousarray(img, dtype=np.uint8)
    img.tofile(path)


def generate(out_dir=DEFAULT_OUT, photo_dir=DEFAULT_PHOTOS, gray_sizes=GRAY_SIZES, bayer_sizes=BAYER_SIZES):
    """Write all images. Returns (manifest entries, number of photos found)."""
    os.makedirs(out_dir, exist_ok=True)
    photos = find_photos(photo_dir)
    entries = []
    for (W, H) in gray_sizes:
        check_size(W, H, "gray")
        items = [(k, SYNTH[k](W, H)) for k in SYNTH_KINDS]
        items += [("photo-" + photo_name(p), photo_gray(p, W, H)) for p in photos]
        for kind, img in items:
            assert img.shape == (H, W)
            path = os.path.join(out_dir, f"gray_{kind}_{W}x{H}.raw")
            write_raw(path, img)
            entries.append(M.entry(path, W, H, "gray:" + kind))
    for (W, H) in bayer_sizes:
        check_size(W, H, "bayer")
        items = [("chart", rgb_to_rggb(rgb_chart(W, H)))]
        items += [("photo-" + photo_name(p), rgb_to_rggb(photo_rgb(p, W, H))) for p in photos]
        for kind, img in items:
            path = os.path.join(out_dir, f"rggb_{kind}_{W}x{H}.raw")
            write_raw(path, img)
            entries.append(M.entry(path, W, H, "rggb:" + kind))
    return entries, len(photos)


def main(argv=None):
    p = argparse.ArgumentParser(prog="python -m model.gen_images", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--photos", default=DEFAULT_PHOTOS)
    p.add_argument("--out", default=DEFAULT_OUT)
    p.add_argument("--update-manifest", action="store_true",
                   help="add NEW files to data/manifest.json; existing entries are kept and still checked")
    p.add_argument("--rewrite-manifest", action="store_true",
                   help="rewrite the whole 'images' section (only after an intended change)")
    a = p.parse_args(argv)
    entries, nphotos = generate(a.out, a.photos)
    print(f"gen_images: {len(entries)} files in {os.path.relpath(a.out)}; photos found in "
          f"{os.path.relpath(a.photos)}: {nphotos}" + ("" if nphotos else " (synthetic only)"))
    bad = M.sync_section("images", entries, update=a.update_manifest, rewrite=a.rewrite_manifest)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
