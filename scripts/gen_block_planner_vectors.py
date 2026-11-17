"""Case list and extra vectors for tb/tb_block_planner.v (step 3.6a). Everything comes from the Python model
(model/memmodel.py make_blocks + schedule, policy P1, NSLOT 32).

    python -m model.gen_vectors            (first; the step 2.2 block lists of the sim sizes)
    python scripts/gen_block_planner_vectors.py

Writes into data/vectors/block_planner/ (not tracked; rerun this before the testbench):

  sched_blocks_<name>_<W>x<H>_L<L>_S<S>.txt   same format as the step 2.2 files (model/gen_vectors.py), for
      208x120         every transform of transforms.json at both SCHED_CONFIGS: rows of 208 bytes, so source
                      rows cross 4 KB pages (no sim size does: 64, 128, 256 all divide 4096); W % 16 == 0 and
                      H even, so Bayer can reuse the size; b from the forward parameters (memmodel._b_for)
      (also sched_bursts_*: the AR burst lists for the same cases, for later steps)
      BLOCK_LEN       L = 1, 7, 63, 64 and random L (group b)
      directed        D16 edges found by search over simple zoom / shear transforms (group c):
                        span_exact   a block whose aligned span reaches exactly SPAN_MAX and that goes on with
                                     more pixels (span == SPAN_MAX is allowed)
                        span_over    a block cut by rule (c) where the next pixel would make the span
                                     exactly SPAN_MAX + 8 (one 8-byte word more)
                        x0_lastpix   a block cut by rule (a) with n = BLOCK_LEN - 1: x0 changes on the pixel
                                     that would have been the last one allowed
                        x0_and_len   a block of n = BLOCK_LEN cut by rule (a): (a) and (b) at the same pixel,
                                     (a) wins (reason 1)
  cases.txt       one line per testbench case:
                  group name W H L S b11 b12 b13 b21 b22 b23 nblk nfetch bp abort abort_at blocks_file
                  group: 0 a, 1 b, 2 c, 3 d, 4 e, 5 f (letters of the step 3.6a prompt)
                  S    = SPAN_MAX of the DUT instance to use (512 or 32)
                  bp   = percent of cycles with desc_ready = 0 and (independently) fetch_ready = 0
                  abort: 0 = whole frame, 1 = aresetn low after abort_at descriptors,
                         2 = the next case's frame_start after abort_at descriptors
                  blocks_file is relative to data/vectors/
"""
import os
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from model import memmodel as MM             # noqa: E402
from model import patrm as P                 # noqa: E402
from model.gen_images import SIM_SIZES       # noqa: E402
from model.gen_transforms import load as load_transforms   # noqa: E402

VEC_DIR = ROOT / "data" / "vectors"
OUT_DIR = VEC_DIR / "block_planner"
SUB = OUT_DIR.name
PAGE_SIZE = (208, 120)                       # page-crossing size
SEED = 36_001
G = {"a": 0, "b": 1, "c": 2, "d": 3, "e": 4, "f": 5}
BP_CYCLE = (5, 10, 15, 20, 25, 30)
CASE_HEADER = "group name W H L S b11 b12 b13 b21 b22 b23 nblk nfetch bp abort abort_at blocks_file"
ONE = P.ONE


def blocks_name(name, W, H, L, S):
    return f"sched_blocks_{name}_{W}x{H}_L{L}_S{S}.txt"


def schedule_for(b, W, H, L, S):
    ps = MM.build_passes("gray", W, H, b)[0]          # D3 + D4 checks inside
    blk = MM.make_blocks(ps, L, S)
    return ps, blk, MM.schedule(ps, blk, W, "P1", MM.NSLOT, MM.SRC_ADDR)


def write_sched(name, b, W, H, L, S, note=None, bursts_too=False):
    """Model block list into OUT_DIR. Returns (relative file name, nblk, nfetch)."""
    _, _, (blocks, bursts) = schedule_for(b, W, H, L, S)
    header = [f"transform {name} size {W}x{H} (W x H) b {' '.join(str(c) for c in b)}",
              f"mode gray BLOCK_LEN {L} SPAN_MAX {S} policy P1 NSLOT {MM.NSLOT} SRC_ADDR {MM.SRC_ADDR}",
              "reason: 0 row end, 1 x0 change (D16a), 2 BLOCK_LEN (D16b), 3 SPAN_MAX (D16c); see model/memmodel.py"]
    if note:
        header.append(note)
    tb, tr = MM.schedule_text(blocks, bursts, header)
    fn = blocks_name(name, W, H, L, S)
    with open(OUT_DIR / fn, "w", newline="\n") as f:
        f.write(tb)
    if bursts_too:
        with open(OUT_DIR / fn.replace("sched_blocks_", "sched_bursts_"), "w", newline="\n") as f:
            f.write(tr)
    return f"{SUB}/{fn}", len(blocks), sum(1 for r in blocks if r["nrows"] > 0)


def count_file(path):
    """(nblk, nfetch) of an existing block list."""
    nblk = nfetch = 0
    with open(path) as f:
        for ln in f:
            if ln.startswith("#") or not ln.strip():
                continue
            nblk += 1
            nfetch += int(ln.split()[6]) > 0
    return nblk, nfetch


# ---------------------------------------------------------------------------
# Group c: search for the D16 edge cases
# ---------------------------------------------------------------------------

def block_edges(ps, blk, L, S):
    """Which edge situations a block list contains (see the module docstring)."""
    nd = MM.pixel_needs(ps)
    anyv, mc0, mc1 = nd["anyv"].ravel(), nd["mc0"].ravel(), nd["mc1"].ravel()
    found = set()
    total = anyv.size
    for j in range(blk["nblocks"]):
        st, n, rs = int(blk["start"][j]), int(blk["n"][j]), int(blk["reason"][j])
        lo, hi = MM.BIG, -MM.BIG
        for q in range(st, st + n):
            if anyv[q]:
                lo, hi = min(lo, int(mc0[q])), max(hi, int(mc1[q]))
                if MM.aligned_span(lo, hi) == S and q < st + n - 1:
                    found.add("span_exact")
        nq = st + n
        if rs == 3 and nq < total and anyv[nq] and lo < MM.BIG:
            if MM.aligned_span(min(lo, int(mc0[nq])), max(hi, int(mc1[nq]))) == S + 8:
                found.add("span_over")
        if rs == 1 and n == L - 1:
            found.add("x0_lastpix")
        if rs == 1 and n == L:
            found.add("x0_and_len")
    return found


def search_directed(L, S, W, H, kinds, cands):
    """First candidate b (in order) for each wanted kind. Returns {kind: b}."""
    out = {}
    for b in cands:
        try:
            ps, blk, _ = schedule_for(b, W, H, L, S)
        except ValueError:
            continue
        for k in block_edges(ps, blk, L, S) & set(kinds):
            out.setdefault(k, b)
        if all(k in out for k in kinds):
            break
    return out


def span_candidates(step_lo, step_hi, nstep):
    """Rows: identity (x = u). Columns: zoom-out y = s v + y_off (s around SPAN / L pixels)."""
    for s in np.linspace(step_lo, step_hi, nstep):
        for off in (0.0, 0.3, 1.0, 2.5, 3.7, 5.0, 6.5):
            yield (ONE, 0, 0, 0, int(np.floor(s * ONE + 0.5)), int(np.floor(off * ONE + 0.5)))


def x0_candidates(L, cstep):
    """Rows: x = u + v / k + x_off (x0 changes every about k pixels along an output row). Columns: y = cstep v
    (cstep < 1 keeps rule (c) away when SPAN_MAX is small)."""
    for k in np.linspace(L - 3, L + 2, 41):
        for off in (0.0, 0.1, 0.25, 0.5, 0.8):
            yield (ONE, int(np.floor(ONE / k + 0.5)), int(np.floor(off * ONE + 0.5)), 0,
                   int(np.floor(cstep * ONE + 0.5)), 0)


# ---------------------------------------------------------------------------

def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(SEED)
    tfs = load_transforms()
    cases = []

    def add(group, name, W, H, L, S, b, fn, nblk, nfetch, bp=0, abort=0, abort_at=0):
        cases.append(f"{G[group]} {name} {W} {H} {L} {S} {' '.join(str(c) for c in b)} {nblk} {nfetch} "
                     f"{bp} {abort} {abort_at} {fn}")

    def std_file(tf, W, H, L, S):
        """Block list of a transforms.json transform: the step 2.2 file for sim sizes, else a new one."""
        if (W, H) in SIM_SIZES:
            fn = f"sched_blocks_{tf['name']}_{W}x{H}_L{L}_S{S}.txt"
            if not (VEC_DIR / fn).is_file():
                raise SystemExit(f"{VEC_DIR / fn} missing: run python -m model.gen_vectors first")
            return (fn,) + count_file(VEC_DIR / fn), tuple(tf["b"][f"{W}x{H}"])
        b = MM._b_for(tf, W, H)
        return write_sched(tf["name"], b, W, H, L, S, bursts_too=True), b

    # a: every sim size + the page-crossing size, every transform, every (L, S) of the step 2.2 vectors
    sizes = list(SIM_SIZES) + [PAGE_SIZE]
    for (W, H) in sizes:
        for tf in tfs:
            for L, S in MM.SCHED_CONFIGS:
                (fn, nblk, nfetch), b = std_file(tf, W, H, L, S)
                add("a", tf["name"], W, H, L, S, b, fn, nblk, nfetch)

    # b: BLOCK_LEN 1, 7, 63, 64 (every transform, 64x64) and random BLOCK_LEN (several sizes, both SPAN_MAX)
    for L in (1, 7, 63, 64):
        for tf in tfs:
            b = tuple(tf["b"]["64x64"])
            fn, nblk, nfetch = write_sched(tf["name"], b, 64, 64, L, 512)
            add("b", tf["name"], 64, 64, L, 512, b, fn, nblk, nfetch)
    for k, tf in enumerate(tfs):
        L = int(rng.integers(1, MM.BLOCK_LEN_MAX + 1))
        S = 32 if k % 3 == 2 else 512
        W, H = (128, 96) if k % 2 else PAGE_SIZE
        b = tuple(tf["b"][f"{W}x{H}"]) if (W, H) in SIM_SIZES else MM._b_for(tf, W, H)
        fn, nblk, nfetch = write_sched(tf["name"], b, W, H, L, S)
        add("b", tf["name"], W, H, L, S, b, fn, nblk, nfetch)

    # c: D16 edges (directed), SPAN_MAX 512 with BLOCK_LEN 64 and SPAN_MAX 32 with BLOCK_LEN 32
    found_all = []
    for L, S, Wc, Hc, lo, hi, cstep in ((64, 512, 1024, 8, 7.6, 8.6, 1.0), (32, 32, 256, 8, 0.6, 1.4, 0.5)):
        got = search_directed(L, S, Wc, Hc, ("span_exact", "span_over"), span_candidates(lo, hi, 101))
        got.update(search_directed(L, S, 512, 64, ("x0_lastpix", "x0_and_len"), x0_candidates(L, cstep)))
        for kind in ("span_exact", "span_over", "x0_lastpix", "x0_and_len"):
            if kind not in got:
                raise SystemExit(f"group c: no transform found for {kind} at L{L} S{S}")
            b = got[kind]
            W, H = (512, 64) if kind.startswith("x0") else (Wc, Hc)
            name = f"c_{kind}"
            fn, nblk, nfetch = write_sched(name, b, W, H, L, S, note=f"directed D16 edge case: {kind}")
            add("c", name, W, H, L, S, b, fn, nblk, nfetch)
            found_all.append(f"{name} L{L} S{S} {W}x{H} b={b}")

    # d: random back-pressure on both output ports
    for k, tf in enumerate(tfs):
        (fn, nblk, nfetch), b = std_file(tf, 128, 96, 32, 32)
        add("d", tf["name"], 128, 96, 32, 32, b, fn, nblk, nfetch, bp=BP_CYCLE[k % len(BP_CYCLE)])
    for k, name in enumerate(("rot15", "rot90", "combined", "identity")):
        tf = next(t for t in tfs if t["name"] == name)
        (fn, nblk, nfetch), b = std_file(tf, *PAGE_SIZE, 64, 512)
        add("d", name, *PAGE_SIZE, 64, 512, b, fn, nblk, nfetch, bp=30 - 5 * k)

    # e: rate with ready always 1 (rot90 64x64: every block is 1 pixel; 256x192: invalid runs join blocks)
    for name, W, H in (("identity", 256, 192), ("rot90", 256, 192), ("rot90", 64, 64)):
        tf = next(t for t in tfs if t["name"] == name)
        (fn, nblk, nfetch), b = std_file(tf, W, H, 64, 512)
        add("e", name, W, H, 64, 512, b, fn, nblk, nfetch)

    # f: frames back to back with different cfg; aresetn and frame_start in the middle of a frame
    seq = [("rot15", 64, 64, 64, 512, 0, 1, 100),        # aresetn after 100 descriptors
           ("identity", 128, 96, 64, 512, 7, 0, 0),
           ("rot37", 208, 120, 32, 32, 0, 2, 500),       # next frame_start after 500 descriptors
           ("rot90", 64, 64, 64, 512, 15, 0, 0),
           ("scale0p8", 128, 96, 32, 32, 0, 2, 3),
           ("combined", 64, 64, 64, 512, 0, 1, 0),        # aresetn right after frame_start (0 descriptors)
           ("mirror_rows", 128, 96, 64, 512, 20, 0, 0),
           ("scale1p25", 64, 64, 32, 32, 0, 0, 0)]
    for name, W, H, L, S, bp, abort, at in seq:
        tf = next(t for t in tfs if t["name"] == name)
        (fn, nblk, nfetch), b = std_file(tf, W, H, L, S)
        add("f", name, W, H, L, S, b, fn, nblk, nfetch, bp=bp, abort=abort, abort_at=at)

    with open(OUT_DIR / "cases.txt", "w", newline="\n") as f:
        f.write("# " + CASE_HEADER + "\n" + "\n".join(cases) + "\n")
    print(f"gen_block_planner_vectors: {len(cases)} cases -> {OUT_DIR / 'cases.txt'}")
    for s in found_all:
        print("  directed:", s)
    return 0


if __name__ == "__main__":
    sys.exit(main())
