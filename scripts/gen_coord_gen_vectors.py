"""Case list and extra vectors for tb/tb_coord_gen.v (step 3.2). Everything comes from the Python model.

    python -m model.gen_vectors            (first; never run gen_images just for this)
    python scripts/gen_coord_gen_vectors.py

Uses the step 1.2 / 2.2 vectors that already exist in data/vectors/ (coord_vectors_*, sched_blocks_*) and writes
into data/vectors/coord_gen/ (not tracked; rerun this before the testbench):

  coord_vectors_<name>_<W>x<H>.txt                   same format as the step 1.2 files (u v X Y valid x0 y0 xf yf)
  sched_blocks_<name>_<W>x<H>_L<L>_S<S>.txt          same format as the step 2.2 files
      for the sets that are NOT in model/transforms.json (rot90 / rot180 are in transforms.json since
      housekeeping 10b and come from the step 1.2 / 2.2 files like every other transform):
      worked          the worked example of CLAUDE.md, b = (52429, -39322, 131072, 39322, 52429, 65536), 64x64
      wrap            the 32-bit wrap case of model/test_patrm.py test_06, 128x96. It is outside D4 on purpose
                      (it only tests arithmetic mod 2^32), so its block list is built without the D4 check.
      rand0..rand3    random block descriptors (u, v0 up to 4095, n 1..64, not in frame order) with full-range
                      32-bit coefficients; expected X, Y = model _coords_uv (direct multiply-add, wrapped).
                      The side fields (nrows, slots, s_col) are random; they only test the pass-through.
  cases.txt       one line per testbench case:
                  group name W H b11 b12 b13 b21 b22 b23 nblk npix bp gap abort abort_at blocks_file coords_file
                  group: 0 = a (stream, ready always 1), 2 = c (back-pressure), 3 = d (worked example),
                         4 = e (wrap), 5 = f (start / restart)
                  bp   = percent of cycles with pix_ready = 0;  gap = percent of descriptors that arrive late
                  abort: 0 = run the whole frame, 1 = aresetn low after abort_at pixels, 2 = the next frame's
                         frame_start after abort_at pixels
                  file names are relative to data/vectors/
"""
import os
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from model import gen_vectors as GV          # noqa: E402
from model import memmodel as MM             # noqa: E402
from model import patrm as P                 # noqa: E402
from model.gen_images import SIM_SIZES       # noqa: E402
from model.gen_transforms import load as load_transforms   # noqa: E402

VEC_DIR = ROOT / "data" / "vectors"
OUT_DIR = VEC_DIR / "coord_gen"
SUB = OUT_DIR.name

WORKED_B = (52429, -39322, 131072, 39322, 52429, 65536)            # CLAUDE.md worked example (D5)
WORKED_SIZE = (64, 64)
WRAP_B = (65536, 0x7FFF0000, -0x7FFF0000, 0, 65536, 0)             # model/test_patrm.py test_06
WRAP_SIZE = (128, 96)
RAND_SIZE = (4096, 4096)                                           # D11 maximum; only used for the D1 column
RAND_BLOCKS = 2000
SEED_RAND = 32_001
I32_MIN, I32_MAX = -(1 << 31), (1 << 31) - 1
RAND_FIXED_B = {1: (I32_MAX, I32_MIN, I32_MIN, I32_MIN, I32_MAX, I32_MAX),
                2: (-1, 65535, -32768, -65537, 32768, 1)}

GROUP = {"a": 0, "c": 2, "d": 3, "e": 4, "f": 5}
BP_CYCLE = (30, 5, 10, 15, 20, 25, 0)                              # percent of cycles with ready = 0
CASE_HEADER = "group name W H b11 b12 b13 b21 b22 b23 nblk npix bp gap abort abort_at blocks_file coords_file"


def count_lines(path):
    with open(path, "r") as f:
        return sum(1 for ln in f if ln.strip() and not ln.startswith("#"))


def blocks_name(name, W, H, L, S):
    return f"sched_blocks_{name}_{W}x{H}_L{L}_S{S}.txt"


def coords_name(name, W, H):
    return f"coord_vectors_{name}_{W}x{H}.txt"


def write_set(name, W, H, b, d4=True):
    """coord_vectors + sched_blocks (every SCHED_CONFIGS entry) for one transform that is not in transforms.json."""
    tf = {"name": name, "b": {f"{W}x{H}": list(b)}}
    GV.gen_coords(str(OUT_DIR), tf, W, H)
    if d4:
        ps = MM.build_passes("gray", W, H, b)[0]                    # D3 + D4 checks inside
    else:
        P.check_size(W, H, "gray")
        ps = MM.Pass("gray", [MM._lane(b, W, H)], H, W, [(1, 0)], (1, 0, 0))
    for L, S in MM.SCHED_CONFIGS:
        blocks, bursts = MM.schedule(ps, MM.make_blocks(ps, L, S), W, "P1", MM.NSLOT, MM.SRC_ADDR)
        header = [f"transform {name} size {W}x{H} (W x H) b {' '.join(str(c) for c in b)}",
                  f"mode gray BLOCK_LEN {L} SPAN_MAX {S} policy P1 NSLOT {MM.NSLOT} SRC_ADDR {MM.SRC_ADDR}"
                  + ("" if d4 else " (outside D4 on purpose: wrap test)")]
        text, _ = MM.schedule_text(blocks, bursts, header)
        with open(OUT_DIR / blocks_name(name, W, H, L, S), "w", newline="\n") as f:
            f.write(text)


def write_rand(idx, rng):
    """Random descriptors + expected pixels. Returns (name, b, nblk, npix)."""
    name = f"rand{idx}"
    W, H = RAND_SIZE
    b = RAND_FIXED_B.get(idx) or tuple(int(x) for x in rng.integers(I32_MIN, I32_MAX + 1, size=6))
    edge = np.array([0, 1, 2, 4094, 4095, 2047, 2048, 4032])
    n = np.where(rng.random(RAND_BLOCKS) < 0.4, 1, rng.integers(1, MM.BLOCK_LEN_MAX + 1, size=RAND_BLOCKS))
    u = np.where(rng.random(RAND_BLOCKS) < 0.3, rng.choice(edge, RAND_BLOCKS), rng.integers(0, H, size=RAND_BLOCKS))
    v0 = np.where(rng.random(RAND_BLOCKS) < 0.3, rng.choice(edge, RAND_BLOCKS), rng.integers(0, W, size=RAND_BLOCKS))
    v0 = np.minimum(v0, W - n)                                       # the block stays inside the row
    nrows = rng.integers(0, 3, size=RAND_BLOCKS)
    blocks = []
    for j in range(RAND_BLOCKS):
        blocks.append(dict(id=j, u=int(u[j]), v0=int(v0[j]), n=int(n[j]), nvalid=0, reason=0, nrows=int(nrows[j]),
                           row_top=0, row_bot=0, s_col=int(rng.integers(0, W // 8)) * 8, span=0,
                           fetch_top=0, fetch_bot=0, slot_top=int(rng.integers(0, MM.NSLOT)),
                           slot_bot=int(rng.integers(0, MM.NSLOT))))
    header = [f"random descriptors {name} (not a frame) b {' '.join(str(c) for c in b)}",
              "only u v0 n nrows s_col slot_top slot_bot are used (scripts/gen_coord_gen_vectors.py)"]
    text, _ = MM.schedule_text(blocks, [], header)
    with open(OUT_DIR / blocks_name(name, W, H, MM.BLOCK_LEN_MAX, MM.SPAN_MAX), "w", newline="\n") as f:
        f.write(text)
    pu = np.repeat(u, n)
    pv = np.repeat(v0, n) + (np.arange(int(n.sum())) - np.repeat(np.cumsum(n) - n, n))
    X, Y = P._coords_uv(b, pu, pv)
    X64, Y64 = X.astype(np.int64), Y.astype(np.int64)
    valid = (X64 >= 0) & (X64 <= (H - 1) * P.ONE) & (Y64 >= 0) & (Y64 <= (W - 1) * P.ONE)
    GV._write_table(str(OUT_DIR / coords_name(name, W, H)), GV.COORD_HEADER,
                    [pu, pv, X64, Y64, valid, X64 >> 16, Y64 >> 16, X64 & 0xFFFF, Y64 & 0xFFFF])
    return name, b, RAND_BLOCKS, int(n.sum())


def wrap_stats(b, W, H):
    """(pixels whose exact b11 u + b12 v + b13 does not fit int32, how many of them are D1-valid after the wrap)."""
    u, v = np.meshgrid(np.arange(H, dtype=np.int64), np.arange(W, dtype=np.int64), indexing="ij")
    ex = b[0] * u + b[1] * v + b[2]
    ey = b[3] * u + b[4] * v + b[5]
    X, Y = P.coords(b, W, H)
    X64, Y64 = X.astype(np.int64), Y.astype(np.int64)
    wrapped = (ex != X64) | (ey != Y64)
    valid = (X64 >= 0) & (X64 <= (H - 1) * P.ONE) & (Y64 >= 0) & (Y64 <= (W - 1) * P.ONE)
    return int(wrapped.sum()), int((wrapped & valid).sum())


def main():
    std = load_transforms()
    for tf in std:
        for (W, H) in SIM_SIZES:
            for f in [coords_name(tf["name"], W, H)] + [blocks_name(tf["name"], W, H, L, S)
                                                         for L, S in MM.SCHED_CONFIGS]:
                if not (VEC_DIR / f).is_file():
                    raise SystemExit(f"data/vectors/{f} is missing: run python -m model.gen_vectors first")
    os.makedirs(OUT_DIR, exist_ok=True)

    # (name, W, H, b, folder) of every frame set; folder "" = the step 1.2 / 2.2 files
    sets = {}
    for tf in std:
        for (W, H) in SIM_SIZES:
            sets[(tf["name"], W, H)] = (tuple(tf["b"][f"{W}x{H}"]), "")
    for need in ("rot90", "rot180"):
        if not any(tf["name"] == need for tf in std):
            raise SystemExit(f"model/transforms.json has no {need}: run python -m model.gen_transforms")
    write_set("worked", *WORKED_SIZE, WORKED_B)
    sets[("worked",) + WORKED_SIZE] = (WORKED_B, SUB + "/")
    write_set("wrap", *WRAP_SIZE, WRAP_B, d4=False)
    sets[("wrap",) + WRAP_SIZE] = (WRAP_B, SUB + "/")

    cases = []

    def add(group, name, W, H, L, S, bp, gap, abort=0, abort_at=0, b=None, nblk=None, npix=None):
        if b is None:
            b, folder = sets[(name, W, H)]
        else:
            folder = SUB + "/"
        fb, fc = folder + blocks_name(name, W, H, L, S), folder + coords_name(name, W, H)
        nblk = count_lines(VEC_DIR / fb) if nblk is None else nblk
        npix = W * H if npix is None else npix
        if count_lines(VEC_DIR / fc) != npix:
            raise SystemExit(f"{fc}: expected {npix} pixel lines")
        if abort and not (0 < abort_at < npix):
            raise SystemExit(f"{name}: abort_at must be inside the frame")
        cases.append([GROUP[group], name, W, H, *b, nblk, npix, bp, gap, abort, abort_at, fb, fc])

    frame_names = [tf["name"] for tf in std]
    (L0, S0), (L1, S1) = MM.SCHED_CONFIGS                           # (64, 512) = D15/D16, (32, 32) = stress
    # a. every transform x sim size, ready always 1, descriptors always available
    for name in frame_names:
        for (W, H) in SIM_SIZES:
            add("a", name, W, H, L0, S0, 0, 0)
    # c. the same frames cut differently (L32 / S32), random back-pressure 0..30 %, half with late descriptors
    i = 0
    for name in frame_names:
        for (W, H) in SIM_SIZES:
            add("c", name, W, H, L1, S1, BP_CYCLE[i % len(BP_CYCLE)], 25 if i % 2 else 0)
            i += 1
    # d. worked example
    add("d", "worked", *WORKED_SIZE, L0, S0, 10, 0)
    # e. wrap: the step 1.1 case, then random descriptors with full-range coefficients
    add("e", "wrap", *WRAP_SIZE, L0, S0, 0, 0)
    add("e", "wrap", *WRAP_SIZE, L1, S1, 20, 25)
    rng = np.random.default_rng(SEED_RAND)
    rand_info = []
    for idx, (bp, gap) in enumerate(((0, 0), (15, 25), (30, 0), (10, 25))):
        name, b, nblk, npix = write_rand(idx, rng)
        add("e", name, *RAND_SIZE, MM.BLOCK_LEN_MAX, MM.SPAN_MAX, bp, gap, b=b, nblk=nblk, npix=npix)
        rand_info.append((name, b, nblk, npix))
    # f. start / restart: frames back to back with different transforms and sizes; reset and frame_start in
    #    the middle of a frame; the frame after each abort must be correct
    add("f", "rot15", 64, 64, L0, S0, 15, 0)
    add("f", "scale0p8", 128, 96, L0, S0, 0, 0)
    add("f", "rot37", 128, 96, L0, S0, 10, 0, abort=1, abort_at=5003)
    add("f", "combined", 64, 64, L0, S0, 20, 25)
    add("f", "mirror_cols", 256, 192, L0, S0, 5, 0, abort=2, abort_at=12345)
    add("f", "rot5", 128, 96, L1, S1, 0, 0)
    add("f", "rot90", 64, 64, L0, S0, 25, 0, abort=2, abort_at=777)
    add("f", "rot180", 64, 64, L0, S0, 30, 25)
    add("f", "scale1p25", 64, 64, L1, S1, 0, 0, abort=1, abort_at=1)
    add("f", "identity", 128, 96, L0, S0, 0, 0)

    with open(OUT_DIR / "cases.txt", "w", newline="\n") as f:
        f.write("# " + CASE_HEADER + "\n")
        for c in cases:
            f.write(" ".join(str(x) for x in c) + "\n")

    ngrp = {g: sum(1 for c in cases if c[0] == code) for g, code in GROUP.items()}
    nw, nwv = wrap_stats(WRAP_B, *WRAP_SIZE)
    print(f"wrote {OUT_DIR.relative_to(ROOT).as_posix()}/cases.txt: {len(cases)} cases "
          + ", ".join(f"{g}={n}" for g, n in ngrp.items()))
    print(f"frame sets: {len(std)} transforms of transforms.json ({', '.join(frame_names)}) "
          f"x sizes {', '.join(f'{w}x{h}' for w, h in SIM_SIZES)}")
    print(f"wrap {WRAP_SIZE[0]}x{WRAP_SIZE[1]} b = {WRAP_B}: {nw} pixels whose exact sum does not fit 32 bits, "
          f"{nwv} of them D1-valid after the wrap")
    for name, b, nblk, npix in rand_info:
        print(f"  {name}: {nblk} descriptors, {npix} pixels, b = {b}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
