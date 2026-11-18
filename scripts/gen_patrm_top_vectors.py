"""Case list and vectors for tb/tb_patrm_top.v (step 3.7). Every expected value comes from the Python model
(model/patrm.py for the frames, model/memmodel.py for the read bytes and the burst counts).

    python scripts/gen_patrm_top_vectors.py

Writes into data/vectors/patrm_top/ (not tracked; rerun this before the testbench):

  src_noise_<W>x<H>.hex      source image (seeded pseudo-random bytes), 64-bit little-endian words
  exp_noise_<tf>_<W>x<H>.hex expected output frame (patrm.warp_gray), same format
  cases.txt                  one line per testbench case (CASE_HEADER), file names relative to data/vectors/

Before writing, every frame is checked against the scalar implementation patrm.warp_gray_scalar on 2000 random
pixels plus the four corners; identity / mirror_cols / mirror_rows must equal the (mirrored) input.

Groups = letters of the step 3.7 prompt (e = the counter checks, done in every complete frame):
  a 0  every sim size x every transform x BLOCK_LEN 64 and 32
  b 1  driver sequence: configuration locked while busy, DONE W1C and interrupt, IRQ_EN = 0 with polling
  c 2  rejected starts, START while busy
  d 3  SLVERR on one read burst / one write response (first, middle, last)
  f 5  random memory timing
  g 6  frames back to back, aresetn in the middle of a frame followed by full frames
  h 7  speed table, 256x192
op: 0 plain frame, 1 lock + W1C checks, 2 read SLVERR on burst arg, 3 write SLVERR on burst arg, 4 aresetn arg cycles
after START, 5 START while busy, 6 the list of rejected starts (uses the case's size and transform as the good base).
"""
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from model import memmodel as MM             # noqa: E402
from model import patrm as P                 # noqa: E402
from model.gen_images import SIM_SIZES       # noqa: E402
from model.gen_transforms import load as load_transforms   # noqa: E402
from model.gen_vectors import write_hex      # noqa: E402

VEC_DIR = ROOT / "data" / "vectors"
SUB = "patrm_top"
OUT_DIR = VEC_DIR / SUB
SIZES = list(SIM_SIZES) + [(208, 120)]       # 208-byte rows cross 4 KB pages
SEED = 37_000
SPAN = MM.SPAN_MAX                           # build value of patrm_top
G = {"a": 0, "b": 1, "c": 2, "d": 3, "f": 5, "g": 6, "h": 7}
CASE_HEADER = ("group op name W H L b11 b12 b13 b21 b22 b23 lat_min lat_max ar_bp r_gap aw_bp w_bp b_lat_min b_lat_max "
               "seed irq arg bytes_rd rd_bursts wr_bursts src_file exp_file")
MAX_PIXELS = 256 * 192                       # tb_patrm_top.v MAXW * 8


def noise(W, H):
    return np.random.default_rng(SEED + 7 * W + H).integers(0, 256, size=(H, W), dtype=np.uint8)


class Gen:
    def __init__(self):
        self.tfs = {t["name"]: t for t in load_transforms()}
        self.srcs = {}
        self.exps = {}
        self.preds = {}
        self.cases = []
        self.rng = np.random.default_rng(SEED)

    def b_of(self, tf, W, H):
        return tuple(int(c) for c in MM._b_for(self.tfs[tf], W, H))

    def src(self, W, H):
        key = (W, H)
        if key not in self.srcs:
            if W * H > MAX_PIXELS:
                raise SystemExit(f"{W}x{H} does not fit the testbench arrays")
            a = noise(W, H)
            fn = f"src_noise_{W}x{H}.hex"
            write_hex(OUT_DIR / fn, a.tobytes())
            self.srcs[key] = (a, f"{SUB}/{fn}")
        return self.srcs[key]

    def exp(self, tf, W, H):
        key = (tf, W, H)
        if key not in self.exps:
            a, _ = self.src(W, H)
            b = self.b_of(tf, W, H)
            e = P.warp_gray(a, W, H, b)
            pts = [(0, 0), (0, W - 1), (H - 1, 0), (H - 1, W - 1)]
            pts += [(int(p), int(q)) for p, q in zip(self.rng.integers(0, H, 2000), self.rng.integers(0, W, 2000))]
            sc = P.warp_gray_scalar(a, W, H, b, pts)
            if any(int(e[p, q]) != s for (p, q), s in zip(pts, sc)):
                raise SystemExit(f"{tf} {W}x{H}: warp_gray != warp_gray_scalar")
            ref = {"identity": a, "mirror_cols": a[:, ::-1], "mirror_rows": a[::-1, :]}.get(tf)
            if ref is not None and not np.array_equal(e, ref):
                raise SystemExit(f"{tf} {W}x{H}: output is not the (mirrored) input")
            fn = f"exp_noise_{tf}_{W}x{H}.hex"
            write_hex(OUT_DIR / fn, e.tobytes())
            self.exps[key] = f"{SUB}/{fn}"
        return self.exps[key]

    def pred(self, tf, W, H, L):
        key = (tf, W, H, L)
        if key not in self.preds:
            ps = MM.build_passes("gray", W, H, self.b_of(tf, W, H))[0]
            r = MM.pass_reads(ps, MM.make_blocks(ps, L, SPAN), W, "P1")
            self.preds[key] = (r["beats"] * MM.BEAT, r["bursts"])
        return self.preds[key]

    def add(self, group, tf, W, H, L=64, op=0, lat=(20, 20), ar_bp=0, r_gap=0, aw_bp=0, w_bp=0, b_lat=(20, 20),
            seed=1, irq=1, arg=0):
        b = self.b_of(tf, W, H)
        _, sf = self.src(W, H)
        ef = self.exp(tf, W, H)
        by, nb = self.pred(tf, W, H, L)
        wb = MM.write_stats("gray", W, H)["write_bursts"]
        self.cases.append(f"{G[group]} {op} {tf} {W} {H} {L} {' '.join(str(c) for c in b)} {lat[0]} {lat[1]} {ar_bp} "
                          f"{r_gap} {aw_bp} {w_bp} {b_lat[0]} {b_lat[1]} {seed} {irq} {arg} {by} {nb} {wb} {sf} {ef}")
        return nb, wb


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    g = Gen()
    rng = np.random.default_rng(SEED + 1)
    names = list(g.tfs)
    ri = lambda lo, hi: int(rng.integers(lo, hi + 1))    # noqa: E731

    # a: full frames
    for W, H in SIZES:
        for tf in names:
            for L in (64, 32):
                g.add("a", tf, W, H, L)

    # b: driver sequence
    g.add("b", "rot15", 128, 96, op=1)
    g.add("b", "rot37", 64, 64, irq=0)
    g.add("b", "identity", 128, 96, L=32, irq=0)

    # c: rejected starts, then START while a frame runs
    g.add("c", "identity", 64, 64, op=6)
    g.add("c", "rot15", 64, 64, op=5)

    # d: bus errors on the first, a middle and the last burst
    for tf, (W, H), L in (("rot15", (128, 96), 64), ("rot90", (64, 64), 32), ("identity", (208, 120), 64)):
        nr = g.pred(tf, W, H, L)[1]
        nw = MM.write_stats("gray", W, H)["write_bursts"]
        for pos in (0, nr // 2, nr - 1):
            g.add("d", tf, W, H, L, op=2, arg=pos)
        for pos in (0, nw // 2, nw - 1):
            g.add("d", tf, W, H, L, op=3, arg=pos)

    # f: random memory timing
    for k, tf in enumerate(names):
        W, H = SIZES[k % len(SIZES)]
        lo = ri(1, 40)
        blo = ri(1, 40)
        g.add("f", tf, W, H, (64, 32)[k % 2], lat=(lo, ri(lo, 60)), ar_bp=ri(0, 40), r_gap=ri(0, 40), aw_bp=ri(0, 40),
              w_bp=ri(0, 40), b_lat=(blo, ri(blo, 60)), seed=ri(1, 1 << 30))
    for tf, (W, H), L in (("rot37", (256, 192), 64), ("rot90", (208, 120), 32), ("combined", (128, 96), 64),
                          ("scale0p8", (256, 192), 64), ("identity", (256, 192), 32)):
        # fast reads, very slow writes (WREADY high 5 % of the cycles = 0.4 pixel per clock): out_fifo fills, WR_STALL
        # counts, the pixel pipeline freezes and prefetch waits for slots
        g.add("f", tf, W, H, L, lat=(1, 3), aw_bp=80, w_bp=95, b_lat=(40, 60), seed=ri(1, 1 << 30))
    g.add("f", "rot5", 208, 120, lat=(1, 60), ar_bp=50, r_gap=50, aw_bp=50, w_bp=50, b_lat=(1, 60), seed=ri(1, 1 << 30))
    g.add("f", "rot37", 208, 120, lat=(1, 1), b_lat=(1, 1), seed=5)

    # g: back to back (the next frame is programmed right after DONE is cleared), resets in the middle of a frame
    g.add("g", "rot15", 256, 192)
    g.add("g", "identity", 64, 64, L=32)
    g.add("g", "rot37", 208, 120)
    g.add("g", "rot90", 128, 96, L=32)
    g.add("g", "combined", 128, 96, op=4, arg=3000)      # while reading and writing
    g.add("g", "rot15", 128, 96)
    g.add("g", "rot180", 64, 64, op=4, arg=12)           # right after START
    g.add("g", "scale0p8", 64, 64)
    g.add("g", "rot5", 256, 192, op=4, arg=40000)        # late in the frame
    g.add("g", "mirror_rows", 256, 192)

    # h: speed (latency applies to reads and to write responses)
    for L_mem in (20, 40):
        for tf in ("identity", "rot15", "rot37", "rot90", "mirror_cols", "mirror_rows"):
            g.add("h", tf, 256, 192, lat=(L_mem, L_mem), b_lat=(L_mem, L_mem))

    with open(OUT_DIR / "cases.txt", "w", newline="\n") as f:
        f.write("# " + CASE_HEADER + "\n" + "\n".join(g.cases) + "\n")
    print(f"gen_patrm_top_vectors: {len(g.cases)} cases, {len(g.exps)} frames, {len(g.srcs)} images "
          f"-> {OUT_DIR / 'cases.txt'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
