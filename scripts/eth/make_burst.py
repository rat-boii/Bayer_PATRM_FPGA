"""Make a test burst of PNG frames for the video demo (step 10.3) until real footage is chosen.

    python scripts/eth/make_burst.py                       100 frames, 800x480 -> data/gen/burst_800x480/
    python scripts/eth/make_burst.py --size 640x480 --n 60

A slow pan and zoom across the test photo (data/photos/mk_480x272.jpg, scaled up, so it is soft at 800x480), with a
bright marker that moves across the frame and the frame number drawn in, so motion and frame order are visible.
Grayscale PNG, exactly W x H. data/gen/ is generated content and is not in git.
"""
import argparse
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw

REPO = Path(__file__).resolve().parents[2]
PHOTO = REPO / "data" / "photos" / "mk_480x272.jpg"


def parse_size(text):
    w, h = text.lower().split("x")
    return int(w), int(h)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--size", type=parse_size, default=(800, 480), help="W x H (default 800x480)")
    ap.add_argument("--n", type=int, default=100, help="number of frames (default 100)")
    ap.add_argument("--out", default="", help="output folder (default data/gen/burst_<W>x<H>)")
    a = ap.parse_args(argv)
    W, H = a.size
    out = Path(a.out) if a.out else REPO / "data" / "gen" / f"burst_{W}x{H}"
    out.mkdir(parents=True, exist_ok=True)
    base = Image.open(PHOTO).convert("L")
    # big enough to pan and zoom in: 1.6 x the frame, keeping the photo's aspect by covering
    scale = 1.6 * max(W / base.width, H / base.height)
    big = base.resize((round(base.width * scale), round(base.height * scale)), Image.BICUBIC)
    for k in range(a.n):
        t = k / max(1, a.n - 1)
        zoom = 1.0 + 0.25 * math.sin(math.pi * t)               # 1.0 -> 1.25 -> 1.0
        cw, ch = W * 1.45 / zoom, H * 1.45 / zoom               # crop window in the big image
        cx = (big.width - cw) * t                               # pan left -> right
        cy = (big.height - ch) * (0.5 + 0.4 * math.sin(2 * math.pi * t))
        frame = big.crop((round(cx), round(cy), round(cx + cw), round(cy + ch))).resize((W, H), Image.BILINEAR)
        d = ImageDraw.Draw(frame)
        mx = int((W - 40) * t)                                   # marker moves left -> right
        my = int((H - 40) * (0.5 + 0.45 * math.sin(4 * math.pi * t)))
        d.rectangle((mx, my, mx + 40, my + 40), fill=255, outline=0, width=3)
        d.rectangle((8, 8, 120, 40), fill=0)
        d.text((16, 16), f"frame {k:03d}", fill=255)
        frame.save(out / f"frame_{k:03d}.png")
    print(f"MAKE_BURST OK: {a.n} frames {W}x{H} -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
