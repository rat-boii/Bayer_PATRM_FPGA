"""Contact sheet for a visual check: every 640x480 gray source image and its 15-degree model output.

    python -m model.contact_sheet [--out results/contact_sheet_step1_2.png]
"""

import argparse
import os
import sys

import numpy as np

from model import patrm as P
from model.gen_transforms import load as load_transforms
from model.gen_vectors import gray_images_at

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(ROOT, "results", "contact_sheet_step1_2.png")
W, H = 640, 480
TW, TH = 320, 240          # thumbnail size
PAD, LABEL = 8, 18


def main(argv=None):
    from PIL import Image, ImageDraw
    p = argparse.ArgumentParser(prog="python -m model.contact_sheet")
    p.add_argument("--out", default=DEFAULT_OUT)
    a = p.parse_args(argv)
    b = tuple(next(t for t in load_transforms() if t["name"] == "rot15")["b"][f"{W}x{H}"])
    imgs = gray_images_at(W, H)
    if not imgs:
        raise SystemExit("no 640x480 images: run python -m model.gen_images first")
    rows = len(imgs)
    sheet = Image.new("L", (2 * TW + 3 * PAD, rows * (TH + LABEL + PAD) + PAD + LABEL), 255)
    d = ImageDraw.Draw(sheet)
    d.text((PAD, 2), f"source {W}x{H} (W x H)", fill=0)
    d.text((2 * PAD + TW, 2), "model output, rotate 15 deg about centre", fill=0)
    for i, (name, path) in enumerate(imgs):
        src = np.fromfile(path, dtype=np.uint8).reshape(H, W)
        out = P.warp_gray(src, W, H, b)
        y = LABEL + PAD + i * (TH + LABEL + PAD)
        d.text((PAD, y), name, fill=0)
        for j, img in enumerate((src, out)):
            th = Image.fromarray(img).resize((TW, TH), Image.BILINEAR)
            sheet.paste(th, (PAD + j * (TW + PAD), y + LABEL - 4))
            d.rectangle((PAD + j * (TW + PAD) - 1, y + LABEL - 5, PAD + j * (TW + PAD) + TW, y + LABEL - 4 + TH),
                        outline=0)
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    sheet.save(a.out, optimize=True)
    print(f"contact_sheet: {rows} images -> {os.path.relpath(a.out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
