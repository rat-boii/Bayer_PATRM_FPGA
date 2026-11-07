"""Try the reference model on any photo: input and output side by side, labelled.

    python -m model.try_warp <photo.jpg|png> --size 640x480 --rot 15 [--scale 0.9 [SY]] [--shift R C]
                             [--mirror cols|rows] [--bayer] [--out results/try_<name>.png]

The photo is centre-cropped and resized to W x H (as in gen_images), converted to grayscale, or to an
RGGB mosaic with --bayer. The forward transform (about the image centre) is quantised to b (D5) and run
through patrm.warp_gray, or bayer.warp_bayer with --bayer (both panels then shown after a simple
bilinear demosaic). Output: results/try_<name>.png (try_<name>_bayer.png with --bayer).
"""

import argparse
import os
import sys

import numpy as np

from model import bayer as BY
from model import patrm as P
from model.gen_images import photo_gray, photo_name, photo_rgb, rgb_to_rggb
from model.raw2png import array_to_image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def parse_size(s):
    try:
        W, H = (int(x) for x in s.lower().split("x"))
    except ValueError:
        raise argparse.ArgumentTypeError(f"size must be WxH, e.g. 640x480, got {s!r}")
    return W, H


def forward_params(rot=0.0, scale=(1.0,), shift=(0.0, 0.0), mirror=None):
    """make_b keyword arguments from the CLI/GUI controls. scale = (S,) or (SX, SY); mirror = None|'cols'|'rows'."""
    if len(scale) not in (1, 2):
        raise ValueError("scale takes one or two values")
    sx, sy = (scale[0], scale[0]) if len(scale) == 1 else scale
    return dict(rot_deg=float(rot), sx=float(sx), sy=float(sy), shift=(float(shift[0]), float(shift[1])),
                mirror_cols=mirror == "cols", mirror_rows=mirror == "rows")


def load_photo(path, W, H, bayer=False):
    """Photo -> uint8 (H, W): grayscale, or RGGB mosaic with bayer=True. Enforces D3."""
    P.check_size(W, H, "bayer" if bayer else "gray")
    return rgb_to_rggb(photo_rgb(path, W, H)) if bayer else photo_gray(path, W, H)


def run_warp(src, W, H, fw, bayer=False):
    """Quantise the forward transform and run the reference model. Returns (out, b, T or None).
    Raises ValueError with the D3/D4 message on a bad size or transform."""
    P.check_size(W, H, "bayer" if bayer else "gray")
    b = P.make_b(W, H, **fw)
    if bayer:
        return BY.warp_bayer(src, W, H, b), b, BY.plane_shifts(b)
    return P.warp_gray(src, W, H, b), b, None


def describe(fw):
    parts = [f"rot {fw['rot_deg']:g} deg"]
    if (fw["sx"], fw["sy"]) != (1.0, 1.0):
        parts.append(f"scale {fw['sx']:g}" if fw["sx"] == fw["sy"] else f"scale sx {fw['sx']:g} sy {fw['sy']:g}")
    if tuple(fw["shift"]) != (0.0, 0.0):
        parts.append(f"shift ({fw['shift'][0]:g}, {fw['shift'][1]:g}) px")
    if fw["mirror_cols"]:
        parts.append("mirror cols")
    if fw["mirror_rows"]:
        parts.append("mirror rows")
    return ", ".join(parts) + ", about centre"


def main(argv=None):
    from PIL import Image, ImageDraw
    p = argparse.ArgumentParser(prog="python -m model.try_warp", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("photo")
    p.add_argument("--size", type=parse_size, default=(640, 480), help="W x H, e.g. 640x480")
    p.add_argument("--rot", type=float, default=0.0, help="forward rotation, degrees, + = counter-clockwise")
    p.add_argument("--scale", type=float, nargs="+", default=[1.0], metavar="S", help="S, or SX SY")
    p.add_argument("--shift", type=float, nargs=2, default=[0.0, 0.0], metavar=("R", "C"),
                   help="forward shift in pixels (rows, columns)")
    p.add_argument("--mirror", choices=("cols", "rows"))
    p.add_argument("--bayer", action="store_true", help="RGGB mosaic and plane-wise warp_bayer")
    p.add_argument("--out", help="output PNG (default results/try_<name>[_bayer].png)")
    a = p.parse_args(argv)
    W, H = a.size
    try:
        fw = forward_params(a.rot, a.scale, a.shift, a.mirror)
        src = load_photo(a.photo, W, H, a.bayer)
        out, b, _ = run_warp(src, W, H, fw, a.bayer)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    def view(img):
        return array_to_image(img, a.bayer).convert("RGB")

    PAD, TOP = 10, 64
    sheet = Image.new("RGB", (2 * W + 3 * PAD, H + TOP + PAD), (255, 255, 255))
    d = ImageDraw.Draw(sheet)
    mode = "Bayer RGGB, plane-wise warp_bayer (shown demosaiced)" if a.bayer else "grayscale, warp_gray"
    d.text((PAD, 4), f"{os.path.basename(a.photo)}  {W}x{H} (W x H)  {mode}", fill=(0, 0, 0))
    d.text((PAD, 18), f"forward: {describe(fw)}", fill=(0, 0, 0))
    d.text((PAD, 32), "b = (" + ", ".join(str(c) for c in b) + ")  Q15.16 inverse map", fill=(0, 0, 0))
    if a.bayer:
        T = BY.plane_shifts(b)
        d.text((PAD, 46), "T_p: " + "  ".join(f"{k} {T[k]}" for k in BY.PLANES), fill=(0, 0, 0))
    for k, (label, img) in enumerate((("input", src), ("output (reference model)", out))):
        x = PAD + k * (W + PAD)
        sheet.paste(view(img), (x, TOP))
        d.rectangle((x - 1, TOP - 1, x + W, TOP + H), outline=(0, 0, 0))
        d.text((x + 4, TOP + 4), label, fill=(255, 0, 255))
    name = photo_name(a.photo) + ("_bayer" if a.bayer else "")
    path = a.out or os.path.join(ROOT, "results", f"try_{name}.png")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    sheet.save(path, optimize=True)
    print(f"try_warp: b = {b} -> {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
