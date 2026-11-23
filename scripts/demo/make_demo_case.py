"""Demo: one real-photo transformation case for the top-level testbench (tb_patrm_top), to show in the Vivado simulator.

    python scripts/demo/make_demo_case.py                       rot15, 256x192 (the largest size the testbench holds)
    python scripts/demo/make_demo_case.py --transform rot37

Writes data/vectors_demo/patrm_top/: cases.txt with ONE case, the source image (the test photo, grayscale, scaled to
256x192) and the model's expected output as .hex files in the testbench's format, plus source.png and expected.png
for the slides. The counters the testbench checks (BYTES_RD, read and write bursts) are predicted with the same code as
scripts/gen_patrm_top_vectors.py, so the demo case is checked exactly like the regression cases.
Then: python scripts/demo/run_demo_sim.py  (opens the simulator GUI with the waveforms).
"""
import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "scripts"))
import gen_patrm_top_vectors as GV           # noqa: E402

PHOTO = REPO / "data" / "photos" / "mk_480x272.jpg"
DEMO_DIR = REPO / "data" / "vectors_demo"
W, H = 256, 192


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--transform", default="rot15", help="a name from model/transforms.json (default rot15)")
    a = ap.parse_args(argv)

    out = DEMO_DIR / GV.SUB
    out.mkdir(parents=True, exist_ok=True)
    GV.OUT_DIR = out                           # the generator writes its .hex files here

    im = Image.open(PHOTO).convert("L")
    s = max(W / im.width, H / im.height)
    im = im.resize((round(im.width * s), round(im.height * s)), Image.BILINEAR)
    x0, y0 = (im.width - W) // 2, (im.height - H) // 2
    photo = np.asarray(im.crop((x0, y0, x0 + W, y0 + H)), dtype=np.uint8).copy()

    g = GV.Gen()
    if a.transform not in g.tfs:
        raise SystemExit(f"unknown transform {a.transform}; choose from {', '.join(g.tfs)}")
    fn = f"src_photo_{W}x{H}.hex"
    GV.write_hex(out / fn, photo.tobytes())
    g.srcs[(W, H)] = (photo, f"{GV.SUB}/{fn}")   # use the photo instead of the generator's noise image
    g.add("a", a.transform, W, H, 64)
    (out / "cases.txt").write_text("# " + GV.CASE_HEADER + "\n" + g.cases[0] + "\n", newline="\n")

    exp = GV.P.warp_gray(photo, W, H, g.b_of(a.transform, W, H))
    Image.fromarray(photo).save(DEMO_DIR / "source.png")
    Image.fromarray(exp).save(DEMO_DIR / "expected.png")
    fields = g.cases[0].split()
    print(f"DEMO CASE OK: {a.transform} {W}x{H}, b = {fields[6:12]}, predicted BYTES_RD {fields[23]}, "
          f"read bursts {fields[24]}, write bursts {fields[25]}")
    print(f"  vectors {out}")
    print(f"  pictures {DEMO_DIR / 'source.png'} and {DEMO_DIR / 'expected.png'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
