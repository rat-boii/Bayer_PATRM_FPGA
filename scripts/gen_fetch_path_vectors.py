"""Case list and vectors for tb/tb_fetch_path.v (step 3.6b). Every expected value comes from the Python model
(model/patrm.py for the pixels, model/memmodel.py for the schedule and the read bytes).

    python scripts/gen_fetch_path_vectors.py

Writes into data/vectors/fetch_path/ (not tracked; rerun this before the testbench):

  src_<img>_<W>x<H>.hex          source image, 64-bit little-endian words (byte k of word j = byte 8j + k), the
                                 format of model/gen_vectors.py; loaded into tb/axi_mem.v at SRC_ADDR
  dump_<img>_<tf>_<W>x<H>.hex    per-pixel stream in raster order (u outer, v inner), one 104-bit hex word per
                                 pixel: {valid[8], x0[16], y0[16], xf[16], yf[16], r1[8], r2[8], r3[8], r4[8]}
                                 (x0, y0 two's complement; r1..r4 = 0 for invalid pixels, as patrm.dump_stream)
  exp_<img>_<tf>_<W>x<H>.hex     expected output frame (patrm.warp_gray), same format as src
  cases.txt                      one line per testbench case (CASE_HEADER), file names relative to data/vectors/

Images: 'noise' (seeded pseudo-random bytes: a wrong byte or word almost never gives the right value) for the
checks, and the step 1.2 synthetic 'mixed' image for a few cases. Before writing, every frame is checked three
ways: the D of the dump (patrm._interp) == warp_gray == the scalar implementation warp_gray_scalar on 2000 random
pixels plus the four corners; for identity / mirror_cols / mirror_rows the frame must equal the (mirrored) input.

Groups (letters of the step 3.6b prompt; c = BYTES_RD and e = RD_STALL are checked in every case):
  a 0  every sim size (64x64, 128x96, 256x192, 208x120) x every transform x both (L, S) of memmodel.SCHED_CONFIGS
  b 1  identity, mirror_cols, mirror_rows x every sim size x both (L, S): output == input (mirrored) byte for byte
  d 3  random memory (ARREADY back-pressure, latency, RVALID gaps) and random op_ready back-pressure
  f 5  speed: identity, rot15, rot37, rot90 at 256x192, L = 64, S = 512, memory latency 20 and 40, no back-pressure
  g 6  aresetn / frame_start in the middle of a frame, then full frames; frames back to back (other size, transform)

bytes_rd = 8 x beats of memmodel.pass_reads(policy P1) for the case's (L, S); est = memmodel's speed ESTIMATE
max(W x H, beats + OVERHEAD x bursts) with OVERHEAD = 2.
"""
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from model import memmodel as MM             # noqa: E402
from model import patrm as P                 # noqa: E402
from model.gen_images import SIM_SIZES, mixed   # noqa: E402
from model.gen_transforms import load as load_transforms   # noqa: E402
from model.gen_vectors import write_hex      # noqa: E402

VEC_DIR = ROOT / "data" / "vectors"
SUB = "fetch_path"
OUT_DIR = VEC_DIR / SUB
SIZES = list(SIM_SIZES) + [(208, 120)]       # 208 B rows cross 4 KB pages
SEED = 36_002
G = {"a": 0, "b": 1, "d": 3, "f": 5, "g": 6}
CHECK = {"identity": 1, "mirror_cols": 2, "mirror_rows": 3}
CASE_HEADER = ("group name W H L S b11 b12 b13 b21 b22 b23 lat_min lat_max ar_bp r_gap op_bp seed abort abort_at "
               "check bytes_rd est_cycles bursts src_file dump_file exp_file")
MAX_PIXELS = 256 * 192                       # tb_fetch_path.v MAXP
MEM_BYTES = 65536                            # tb_fetch_path.v MEM_WORDS = 8192


def noise(W, H, seed):
    return np.random.default_rng(seed).integers(0, 256, size=(H, W), dtype=np.uint8)


class Gen:
    def __init__(self):
        self.tfs = {t["name"]: t for t in load_transforms()}
        self.srcs = {}
        self.dumps = {}
        self.preds = {}
        self.cases = []
        self.rng = np.random.default_rng(SEED)

    def b_of(self, name, W, H):
        return tuple(int(c) for c in MM._b_for(self.tfs[name], W, H))

    def src(self, img, W, H):
        key = (img, W, H)
        if key not in self.srcs:
            if W * H > MEM_BYTES or W * H > MAX_PIXELS:
                raise SystemExit(f"{W}x{H} does not fit the testbench memory / pixel arrays")
            a = noise(W, H, SEED + 7 * W + H) if img == "noise" else mixed(W, H)
            fn = f"src_{img}_{W}x{H}.hex"
            write_hex(OUT_DIR / fn, a.tobytes())
            self.srcs[key] = (a, f"{SUB}/{fn}")
        return self.srcs[key]

    def dump(self, img, tf, W, H):
        key = (img, tf, W, H)
        if key in self.dumps:
            return self.dumps[key]
        a, _ = self.src(img, W, H)
        b = self.b_of(tf, W, H)
        u, v = np.meshgrid(np.arange(H, dtype=np.int64), np.arange(W, dtype=np.int64), indexing="ij")
        X, Y = P._coords_uv(b, u, v)
        d = P._interp(a, W, H, X, Y)
        exp = P.warp_gray(a, W, H, b)
        if not np.array_equal(d["D"].reshape(H, W), exp.astype(np.int64)):
            raise SystemExit(f"{tf} {W}x{H}: dump D != warp_gray")
        # independent scalar implementation on random pixels and the corners
        pts = [(0, 0), (0, W - 1), (H - 1, 0), (H - 1, W - 1)]
        pts += [(int(p), int(q)) for p, q in zip(self.rng.integers(0, H, 2000), self.rng.integers(0, W, 2000))]
        sc = P.warp_gray_scalar(a, W, H, b, pts)
        if any(int(exp[p, q]) != s for (p, q), s in zip(pts, sc)):
            raise SystemExit(f"{tf} {W}x{H}: warp_gray != warp_gray_scalar")
        ref = {"identity": a, "mirror_cols": a[:, ::-1], "mirror_rows": a[::-1, :]}.get(tf)
        if ref is not None and not np.array_equal(exp, ref):
            raise SystemExit(f"{tf} {W}x{H}: output is not the (mirrored) input")
        f = lambda k: d[k].astype(np.int64).ravel()                        # noqa: E731
        valid, x0, y0, xf, yf = f("valid"), f("x0") & 0xFFFF, f("y0") & 0xFFFF, f("xf"), f("yf")
        r = [f(k) for k in ("r1", "r2", "r3", "r4")]
        stem = f"{img}_{tf}_{W}x{H}"
        with open(OUT_DIR / f"dump_{stem}.hex", "w", newline="\n") as fo:
            for i in range(W * H):
                fo.write(f"{int(valid[i]):02x}{int(x0[i]):04x}{int(y0[i]):04x}{int(xf[i]):04x}{int(yf[i]):04x}"
                         f"{int(r[0][i]):02x}{int(r[1][i]):02x}{int(r[2][i]):02x}{int(r[3][i]):02x}\n")
        write_hex(OUT_DIR / f"exp_{stem}.hex", exp.tobytes())
        self.dumps[key] = (f"{SUB}/dump_{stem}.hex", f"{SUB}/exp_{stem}.hex")
        return self.dumps[key]

    def pred(self, tf, W, H, L, S):
        key = (tf, W, H, L, S)
        if key not in self.preds:
            ps = MM.build_passes("gray", W, H, self.b_of(tf, W, H))[0]
            blk = MM.make_blocks(ps, L, S)
            r = MM.pass_reads(ps, blk, W, "P1")
            est = max(W * H, r["beats"] + MM.OVERHEAD * r["bursts"])
            self.preds[key] = (r["beats"] * MM.BEAT, est, r["bursts"])
        return self.preds[key]

    def add(self, group, tf, W, H, L, S, img="noise", lat=(20, 20), ar_bp=0, r_gap=0, op_bp=0, seed=1,
            abort=0, abort_at=0):
        b = self.b_of(tf, W, H)
        _, sf = self.src(img, W, H)
        df, ef = self.dump(img, tf, W, H)
        by, est, nb = self.pred(tf, W, H, L, S)
        chk = CHECK.get(tf, 0) if group == "b" else 0
        self.cases.append(f"{G[group]} {tf} {W} {H} {L} {S} {' '.join(str(c) for c in b)} {lat[0]} {lat[1]} {ar_bp} "
                          f"{r_gap} {op_bp} {seed} {abort} {abort_at} {chk} {by} {est} {nb} {sf} {df} {ef}")


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    g = Gen()
    rng = np.random.default_rng(SEED + 1)
    names = list(g.tfs)

    # a: every sim size x every transform x both (L, S); memory latency 20, no back-pressure
    for (W, H) in SIZES:
        for tf in names:
            for L, S in MM.SCHED_CONFIGS:
                g.add("a", tf, W, H, L, S, img="mixed" if (tf == "combined" and W == 128) else "noise")

    # b: identity and both mirrors reproduce the input (last row and column included)
    for (W, H) in SIZES:
        for tf in CHECK:
            for L, S in MM.SCHED_CONFIGS:
                g.add("b", tf, W, H, L, S)

    # d: random memory behaviour and random downstream back-pressure
    for k, tf in enumerate(names):
        W, H = SIZES[k % len(SIZES)]
        L, S = MM.SCHED_CONFIGS[k % 2]
        lo = int(rng.integers(1, 41))
        hi = int(rng.integers(lo, 61))
        g.add("d", tf, W, H, L, S, lat=(lo, hi), ar_bp=int(rng.integers(0, 31)), r_gap=int(rng.integers(0, 31)),
              op_bp=int(rng.integers(5, 31)), seed=int(rng.integers(1, 1 << 30)))
    # fast memory + heavy downstream back-pressure: prefetch runs ahead and waits for slots (slot reuse checks)
    for tf, (W, H), L, S in (("rot37", (256, 192), 64, 512), ("rot90", (256, 192), 64, 512),
                             ("rot15", (208, 120), 32, 32), ("combined", (128, 96), 64, 512),
                             ("scale0p8", (256, 192), 64, 512), ("identity", (208, 120), 32, 32)):
        g.add("d", tf, W, H, L, S, lat=(1, 3), op_bp=60, seed=int(rng.integers(1, 1 << 30)))
    # 1-cycle memory, no back-pressure, and the full random mix on the page-crossing size
    g.add("d", "rot37", 208, 120, 64, 512, lat=(1, 1), seed=5)
    g.add("d", "rot5", 208, 120, 64, 512, lat=(1, 60), ar_bp=30, r_gap=30, op_bp=30, seed=6)

    # f: speed, no back-pressure
    for L_mem in (20, 40):
        for tf in ("identity", "rot15", "rot37", "rot90"):
            g.add("f", tf, 256, 192, 64, 512, lat=(L_mem, L_mem))

    # g: aborts and back-to-back frames (each frame starts right after the previous one)
    g.add("g", "rot15", 64, 64, 64, 512, abort=1, abort_at=1000)                 # aresetn after 1000 pixels
    g.add("g", "identity", 128, 96, 64, 512)
    g.add("g", "rot37", 208, 120, 32, 32, lat=(30, 60), abort=2, abort_at=3000)  # frame_start after 3000 pixels
    g.add("g", "rot90", 64, 64, 64, 512)
    g.add("g", "combined", 256, 192, 64, 512, abort=2, abort_at=7)               # frame_start very early
    g.add("g", "scale0p8", 128, 96, 32, 32)
    g.add("g", "mirror_rows", 208, 120, 64, 512)                                 # back to back, other size
    g.add("g", "rot180", 64, 64, 32, 32, abort=1, abort_at=0)                    # aresetn right after frame_start
    g.add("g", "scale1p25", 256, 192, 64, 512)

    with open(OUT_DIR / "cases.txt", "w", newline="\n") as f:
        f.write("# " + CASE_HEADER + "\n" + "\n".join(g.cases) + "\n")
    print(f"gen_fetch_path_vectors: {len(g.cases)} cases, {len(g.dumps)} pixel dumps, {len(g.srcs)} images "
          f"-> {OUT_DIR / 'cases.txt'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
