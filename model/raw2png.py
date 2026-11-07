"""View a raw image: convert raw GRAY8 or raw RGGB8 (row-major, no header) to PNG.

    python -m model.raw2png <file.raw> --w W --h H [--bayer [--mosaic]] [--out file.png]

Grayscale -> gray PNG. --bayer -> colour PNG after a simple bilinear demosaic (bayer.demosaic_bilinear);
--bayer --mosaic -> the raw mosaic shown as gray. Default output: <file>.png next to the input.
"""

import argparse
import os
import sys

import numpy as np

from model import bayer as BY
from model import patrm as P


def raw_to_image(path, W, H, bayer=False, mosaic=False):
    """Returns a PIL image."""
    from PIL import Image
    data = np.fromfile(path, dtype=np.uint8)
    if data.size != W * H:
        raise ValueError(f"{path} has {data.size} bytes, expected W*H = {W}*{H} = {W * H}")
    img = data.reshape(H, W)
    if not bayer or mosaic:
        return Image.fromarray(img, mode="L")
    P.check_size(W, H, "bayer")
    rgb = np.clip(np.floor(BY.demosaic_bilinear(img) + 0.5), 0, 255).astype(np.uint8)
    return Image.fromarray(rgb, mode="RGB")


def main(argv=None):
    p = argparse.ArgumentParser(prog="python -m model.raw2png", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("raw")
    p.add_argument("--w", type=int, required=True, help="width W")
    p.add_argument("--h", type=int, required=True, help="height H")
    p.add_argument("--bayer", action="store_true", help="input is an RGGB mosaic; demosaic to colour")
    p.add_argument("--mosaic", action="store_true", help="with --bayer: show the raw mosaic as gray")
    p.add_argument("--out", help="output PNG (default: <raw>.png)")
    a = p.parse_args(argv)
    out = a.out or os.path.splitext(a.raw)[0] + ".png"
    try:
        im = raw_to_image(a.raw, a.w, a.h, a.bayer, a.mosaic)
    except (ValueError, OSError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    im.save(out)
    print(f"raw2png: {a.raw} ({a.w}x{a.h}, {'Bayer ' + ('mosaic' if a.mosaic else 'demosaiced') if a.bayer else 'gray'})"
          f" -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
