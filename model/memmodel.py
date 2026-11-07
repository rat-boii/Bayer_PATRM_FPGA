"""Memory-access model (step 1.4). OUR INTERPRETATION of the paper's block/burst/ping-pong scheme;
all throughput figures are ESTIMATES, not measurements.

The paper only says: burst length follows the coordinate slope (b12 != 0: about 1/|b12| output pixels per
source row change; b12 = 0: the whole row) and a ping-pong RAM pair prefetches the next block while the
current one is interpolated. Our interpretation, modelled here:

Blocks   Each output row is cut into blocks = maximal runs of consecutive output pixels whose VALID pixels
         share the same top source row x0 (so the block needs rows x0 and x0+1), capped at Lmax pixels.
         Invalid pixels (D1) need no data and never split a block. Option B: the key is the pair
         (min x0, max x0) over the four lanes.
Reads    Per block and needed source row: column span [min y0, max y0+1] (clamped, D1) -> 8-byte aligned
         byte range at SRC_ADDR + row*W + col -> AXI3 bursts of <= 16 beats x 8 bytes, never across 4 KB.
Policies P0: fetch every needed row of every block.
         P1: skip a row if the previous block (that fetched anything, same pass) needed that row with a
             covering aligned column range (the data are still on chip).
Buffer   footprint = needed source rows x aligned span bytes; ping-pong = 2 x the largest footprint.
Writes   Output rows in 128-byte bursts (no 4 KB crossing) at DST_ADDR. Bayer A writes every full row
         once per plane pass with WSTRB on every other byte; Bayer B writes whole row pairs.
Bayer A  Four plane passes; plane row x -> full row 2x+o_row, plane column y -> full column 2y+o_col; the
         FULL-resolution bytes covering the plane span are read (about 2x the useful bytes).
Bayer B  One pass in plane coordinates, four lanes (coords of b_p = coords of b_R + T_p - T_R, D6); per
         block the union of the lanes' needs is read as full-resolution row pairs (2x, 2x+1).
Speed    ESTIMATE: cycles = max(output pixels / pixels per clock, read beats + OVERHEAD x read bursts)
         (per pass for Bayer A, passes summed); pixels per clock = 1 (gray, A) or 4 (B); assumes >= 2
         outstanding reads hide the latency. fps at 100 MHz (D8). Port ceiling 64 bit x 100 MHz = 800 MB/s
         (theoretical).

    python -m model.memmodel [--out results/memmodel_step1_4] [--overhead 2]
"""

import argparse
import csv
import io
import os
import sys
import time

import numpy as np

from model import bayer as BY
from model import patrm as P
from model.gen_transforms import TRANSFORMS as TF_LIST
from model.gen_transforms import load as load_transforms

SRC_ADDR = 0x1000_0000          # 4 KB aligned (proposed in step 0.3)
DST_ADDR = 0x1800_0000
BEAT = 8                        # bytes per beat (64-bit HP port)
MAX_BEATS = 16                  # AXI3 burst limit
BURST_BYTES = BEAT * MAX_BEATS  # 128
PAGE = 4096                     # AXI 4 KB boundary
CLK_HZ = 100e6                  # D8
PORT_MBPS = BEAT * CLK_HZ / 1e6  # 800 MB/s theoretical
OVERHEAD = 2                    # cycles per read burst (parameter)
BIG = 1 << 40

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(ROOT, "results", "memmodel_step1_4")


# ---------------------------------------------------------------------------
# Bursts
# ---------------------------------------------------------------------------

def split_bursts(s, e):
    """Explicit burst list for byte range [s, e) (both 8-byte aligned): [(addr, beats), ...]."""
    if s % BEAT or e % BEAT:
        raise ValueError("range must be 8-byte aligned")
    out = []
    a = s
    while a < e:
        nxt = min(e, a + BURST_BYTES, (a // PAGE + 1) * PAGE)
        out.append((a, (nxt - a) // BEAT))
        a = nxt
    return out


def burst_count(s, e):
    """Number of bursts split_bursts would produce, vectorised (int64 arrays)."""
    s = np.asarray(s, dtype=np.int64)
    e = np.asarray(e, dtype=np.int64)
    p0 = s // PAGE
    p1 = (np.maximum(e, s + 1) - 1) // PAGE

    def ceil(n):
        return (n + BURST_BYTES - 1) // BURST_BYTES
    same = ceil(e - s)
    split = ceil((p0 + 1) * PAGE - s) + (p1 - p0 - 1) * (PAGE // BURST_BYTES) + ceil(e - p1 * PAGE)
    return np.where(e <= s, 0, np.where(p0 == p1, same, split))


# ---------------------------------------------------------------------------
# Passes (what is warped, and how plane rows/columns map to memory)
# ---------------------------------------------------------------------------

class Pass:
    """One sweep over an output grid. lanes = list of (valid, x0, y0) int arrays of the output grid shape,
    in plane coordinates of size (Hp, Wp). rowmap = [(mul, add)] memory rows per plane row;
    colmap = (mul, add_lo, add_hi) memory column span for a plane column span."""

    def __init__(self, name, lanes, Hp, Wp, rowmap, colmap):
        self.name, self.lanes, self.Hp, self.Wp = name, lanes, Hp, Wp
        self.rowmap, self.colmap = rowmap, colmap


def _lane(b, Wp, Hp):
    X, Y = P.coords(b, Wp, Hp)
    X = X.astype(np.int64)
    Y = Y.astype(np.int64)
    valid = (X >= 0) & (X <= (Hp - 1) * P.ONE) & (Y >= 0) & (Y <= (Wp - 1) * P.ONE)
    return valid, X >> 16, Y >> 16


def build_passes(mode, W, H, b):
    """mode: 'gray', 'A' or 'B'. b = full-size integer coefficients."""
    if mode == "gray":
        P.check_size(W, H, "gray")
        P.check_transform(b, W, H)
        return [Pass("gray", [_lane(b, W, H)], H, W, [(1, 0)], (1, 0, 0))]
    P.check_size(W, H, "bayer")
    BY.check_bayer_transform(b, W, H)
    bp = BY.plane_b(b)
    Wp, Hp = W // 2, H // 2
    if mode == "A":
        return [Pass(f"A-{p}", [_lane(bp[p], Wp, Hp)], Hp, Wp, [(2, BY.OFFSETS[p][0])],
                     (2, BY.OFFSETS[p][1], BY.OFFSETS[p][1])) for p in BY.PLANES]
    if mode == "B":
        return [Pass("B", [_lane(bp[p], Wp, Hp) for p in BY.PLANES], Hp, Wp, [(2, 0), (2, 1)], (2, 0, 1))]
    raise ValueError(f"unknown mode {mode!r}")


# ---------------------------------------------------------------------------
# Blocks
# ---------------------------------------------------------------------------

def make_blocks(ps, Lmax):
    """Cut the pass into blocks. Returns dict with
    bid: block id per output pixel (Ho, Wo); nblocks; and for blocks that need data (in order):
    ids, rlo, rhi (plane rows needed, inclusive), clo, chi (plane columns needed, inclusive)."""
    valid = np.stack([l[0] for l in ps.lanes])
    x0 = np.stack([l[1] for l in ps.lanes])
    y0 = np.stack([l[2] for l in ps.lanes])
    x1 = np.minimum(x0 + 1, ps.Hp - 1)
    y1 = np.minimum(y0 + 1, ps.Wp - 1)
    anyv = valid.any(axis=0)
    rlo = np.where(valid, x0, BIG).min(axis=0)
    rhi = np.where(valid, x1, -BIG).max(axis=0)
    clo = np.where(valid, y0, BIG).min(axis=0)
    chi = np.where(valid, y1, -BIG).max(axis=0)
    kmax = np.where(valid, x0, -BIG).max(axis=0)
    key = np.where(anyv, rlo * (1 << 20) + (kmax - rlo), -1)
    Ho, Wo = anyv.shape
    cols = np.arange(Wo)
    # invalid pixels take the key of the last valid pixel in the row (or the next one at the row start)
    last = np.maximum.accumulate(np.where(anyv, cols, -1), axis=1)
    nxt = np.minimum.accumulate(np.where(anyv, cols, Wo)[:, ::-1], axis=1)[:, ::-1]
    src = np.where(last >= 0, last, np.where(nxt < Wo, nxt, 0))
    keyf = np.take_along_axis(key, src, axis=1)
    boundary = np.ones((Ho, Wo), dtype=bool)
    boundary[:, 1:] = keyf[:, 1:] != keyf[:, :-1]
    vstart = np.maximum.accumulate(np.where(boundary, cols, 0), axis=1)
    L = Wo if Lmax is None else int(Lmax)
    start = boundary | (((cols - vstart) % L) == 0)
    bid = np.cumsum(start.ravel()) - 1
    nblocks = int(bid[-1]) + 1
    fv = anyv.ravel()
    vb = bid[fv]
    if vb.size == 0:
        e = np.zeros(0, dtype=np.int64)
        return dict(bid=bid.reshape(Ho, Wo), nblocks=nblocks, ids=e, rlo=e, rhi=e, clo=e, chi=e)
    st = np.flatnonzero(np.r_[True, vb[1:] != vb[:-1]])
    return dict(bid=bid.reshape(Ho, Wo), nblocks=nblocks, ids=vb[st],
                rlo=np.minimum.reduceat(rlo.ravel()[fv], st), rhi=np.maximum.reduceat(rhi.ravel()[fv], st),
                clo=np.minimum.reduceat(clo.ravel()[fv], st), chi=np.maximum.reduceat(chi.ravel()[fv], st))


def _block_geometry(ps, blk):
    cm, alo, ahi = ps.colmap
    c0 = cm * blk["clo"] + alo
    c1 = cm * blk["chi"] + ahi
    s_col = (c0 // BEAT) * BEAT
    e_col = ((c1 + 1 + BEAT - 1) // BEAT) * BEAT
    nr = blk["rhi"] - blk["rlo"] + 1
    return s_col, e_col, nr


def _reuse_mask(blk, s_col, e_col, x, policy):
    """True where plane row x of each block is already held by the previous fetching block (P1)."""
    if policy == "P0" or len(x) == 0:
        return np.zeros(len(x), dtype=bool)
    p_rlo = np.r_[BIG, blk["rlo"][:-1]]
    p_rhi = np.r_[-BIG, blk["rhi"][:-1]]
    p_s = np.r_[BIG, s_col[:-1]]
    p_e = np.r_[-BIG, e_col[:-1]]
    return (p_s <= s_col) & (p_e >= e_col) & (x >= p_rlo) & (x <= p_rhi)


def pass_reads(ps, blk, W, policy, src_addr=SRC_ADDR):
    """Read statistics of one pass for a fetch policy ('P0' or 'P1')."""
    s_col, e_col, nr = _block_geometry(ps, blk)
    span = e_col - s_col
    bursts = beats = fetched_rows = 0
    for k in range(int(nr.max()) if len(nr) else 0):
        m = k < nr
        x = blk["rlo"] + k
        fetch = m & ~_reuse_mask(blk, s_col, e_col, x, policy)
        for mul, add in ps.rowmap:
            r = mul * x[fetch] + add
            s = src_addr + r * W + s_col[fetch]
            bursts += int(burst_count(s, s + span[fetch]).sum())
            beats += int((span[fetch] // BEAT).sum())
            fetched_rows += int(fetch.sum())
    nmem = nr * len(ps.rowmap)
    fp = nmem * span
    return dict(bursts=bursts, beats=beats, fetched_rows=fetched_rows,
                max_rows=int(nmem.max()) if len(nmem) else 0, max_span=int(span.max()) if len(span) else 0,
                max_footprint=int(fp.max()) if len(fp) else 0)


def pass_detail(ps, blk, W, policy, src_addr=SRC_ADDR):
    """Explicit per-block fetch list (small images only, for tests and examples):
    list of dicts {id, rows: [(mem_row, s, e, fetched, bursts)]}."""
    s_col, e_col, nr = _block_geometry(ps, blk)
    reuse = {}
    for k in range(int(nr.max()) if len(nr) else 0):
        x = blk["rlo"] + k
        reuse[k] = _reuse_mask(blk, s_col, e_col, x, policy) & (k < nr)
    out = []
    for i in range(len(blk["ids"])):
        rows = []
        for k in range(int(nr[i])):
            x = int(blk["rlo"][i]) + k
            for mul, add in ps.rowmap:
                r = mul * x + add
                s = src_addr + r * W + int(s_col[i])
                e = src_addr + r * W + int(e_col[i])
                fetched = not bool(reuse[k][i])
                rows.append((r, s, e, fetched, split_bursts(s, e) if fetched else []))
        out.append(dict(id=int(blk["ids"][i]), rows=rows))
    return out


# ---------------------------------------------------------------------------
# Writes and frame totals
# ---------------------------------------------------------------------------

def write_stats(mode, W, H, dst_addr=DST_ADDR):
    """Write bursts/beats; useful bytes = W*H in every mode."""
    rows = np.arange(H, dtype=np.int64)
    s = dst_addr + rows * W
    # gray and B: every full row written once, all strobes on.
    # A: four plane passes; each full row is written by two of them (R+Gr rows even, Gb+B rows odd),
    #    each time with WSTRB on every other byte.
    k = 2 if mode == "A" else 1
    passes = 4 if mode == "A" else 1
    bursts = k * int(burst_count(s, s + W).sum())
    beats = k * H * (W // BEAT)
    return dict(write_bursts=bursts, write_beats=beats, write_bus_bytes=beats * BEAT, bytes_written=W * H,
                write_passes=passes)


def frame_stats(mode, W, H, b, Lmax, policy, passes=None, blocks=None, overhead=OVERHEAD):
    """All numbers for one (mode, size, transform, Lmax, policy). passes/blocks may be passed in (cache)."""
    passes = passes or build_passes(mode, W, H, b)
    blocks = blocks or [make_blocks(ps, Lmax) for ps in passes]
    tot = dict(blocks=0, fetch_blocks=0, bursts=0, beats=0, max_rows=0, max_span=0, max_footprint=0)
    cycles = compute = 0
    for ps, blk in zip(passes, blocks):
        r = pass_reads(ps, blk, W, policy)
        # one output-grid point per clock: 1 pixel (gray, A) or one plane pixel = 4 lanes (B)
        c = ps.lanes[0][0].size
        compute += c
        cycles += max(c, r["beats"] + overhead * r["bursts"])
        tot["blocks"] += blk["nblocks"]
        tot["fetch_blocks"] += len(blk["ids"])
        tot["bursts"] += r["bursts"]
        tot["beats"] += r["beats"]
        for k in ("max_rows", "max_span", "max_footprint"):
            tot[k] = max(tot[k], r[k])
    wr = write_stats(mode, W, H)
    bytes_read = tot["beats"] * BEAT
    fps = CLK_HZ / cycles
    rd_mbps = bytes_read * fps / 1e6
    return dict(mode=mode, size=f"{W}x{H}", lmax=Lmax, policy=policy, **tot,
                bytes_read=bytes_read, read_amp=bytes_read / (W * H),
                mean_burst_beats=tot["beats"] / tot["bursts"] if tot["bursts"] else 0.0,
                **wr, pingpong_bytes=2 * tot["max_footprint"], est_cycles=int(round(cycles)),
                est_fps=fps, est_read_mbps=rd_mbps, est_port_util_pct=100.0 * rd_mbps / PORT_MBPS,
                compute_bound=bool(cycles <= compute + 0.5))


# ---------------------------------------------------------------------------
# Information only: output-tile model
# ---------------------------------------------------------------------------

def tile_stats(W, H, b, T, src_addr=SRC_ADDR):
    """T x T output tiles, each fetching the source bounding box of its valid pixels (gray)."""
    valid, x0, y0 = _lane(b, W, H)
    x1 = np.minimum(x0 + 1, H - 1)
    y1 = np.minimum(y0 + 1, W - 1)
    Ht, Wt = -(-H // T), -(-W // T)

    def tiles(a, fill, fn):
        pad = np.full((Ht * T, Wt * T), fill, dtype=np.int64)
        pad[:H, :W] = np.where(valid, a, fill)
        return fn(pad.reshape(Ht, T, Wt, T), axis=(1, 3))
    r0 = tiles(x0, BIG, np.min)
    r1 = tiles(x1, -BIG, np.max)
    c0 = tiles(y0, BIG, np.min)
    c1 = tiles(y1, -BIG, np.max)
    has = r0 < BIG
    r0, r1, c0, c1 = r0[has], r1[has], c0[has], c1[has]
    s_col = (c0 // BEAT) * BEAT
    e_col = ((c1 + BEAT) // BEAT) * BEAT
    span = e_col - s_col
    nr = r1 - r0 + 1
    bursts = beats = 0
    for k in range(int(nr.max()) if len(nr) else 0):
        m = k < nr
        s = src_addr + (r0[m] + k) * W + s_col[m]
        bursts += int(burst_count(s, s + span[m]).sum())
        beats += int((span[m] // BEAT).sum())
    fp = nr * span
    return dict(size=f"{W}x{H}", tile=T, tiles=int(has.sum()), bursts=bursts, bytes_read=beats * BEAT,
                read_amp=beats * BEAT / (W * H), mean_burst_beats=beats / bursts if bursts else 0.0,
                max_footprint=int(fp.max()) if len(fp) else 0, pingpong_bytes=2 * int(fp.max()) if len(fp) else 0)


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

GRAY_SIZES = [(640, 480), (1920, 1080), (2448, 2095)]
BAYER_SIZES = [(2448, 2048)]
WIDE_SIZE = (4096, 2160)            # worst-case buffer check at the proposed maximum width
LMAXES = (16, 32, 64)
POLICIES = ("P0", "P1")
TILES = (16, 32, 64)

COLUMNS = ["mode", "size", "transform", "lmax", "policy", "blocks", "fetch_blocks", "bursts", "beats",
           "bytes_read", "read_amp", "mean_burst_beats", "write_bursts", "write_beats", "write_bus_bytes",
           "bytes_written", "max_rows", "max_span", "max_footprint", "pingpong_bytes", "est_cycles", "est_fps",
           "est_read_mbps", "est_port_util_pct", "compute_bound"]
TILE_COLUMNS = ["size", "transform", "tile", "tiles", "bursts", "bytes_read", "read_amp", "mean_burst_beats",
                "max_footprint", "pingpong_bytes"]


def _b_for(tf, W, H):
    key = f"{W}x{H}"
    if key in tf["b"]:
        return tuple(tf["b"][key])
    fw = {k: (tuple(v) if k == "shift" else v) for k, v in tf["forward"].items()}
    return P.make_b(W, H, **fw)


def run_configs(configs, transforms=None, lmaxes=LMAXES, policies=POLICIES, overhead=OVERHEAD, log=None):
    """configs = [(mode, W, H)]. Returns list of row dicts."""
    transforms = transforms or load_transforms()
    rows = []
    for mode, W, H in configs:
        for tf in transforms:
            t0 = time.perf_counter()
            b = _b_for(tf, W, H)
            passes = build_passes(mode, W, H, b)
            for L in lmaxes:
                blocks = [make_blocks(ps, L) for ps in passes]
                for pol in policies:
                    r = frame_stats(mode, W, H, b, L, pol, passes, blocks, overhead)
                    r["transform"] = tf["name"]
                    rows.append(r)
            if log:
                log(f"  {mode} {W}x{H} {tf['name']}: {time.perf_counter() - t0:.1f} s")
    return rows


def _fmt(v):
    if isinstance(v, float):
        return f"{v:.4f}"
    if v is None:
        return "row"
    return str(v)


def rows_to_csv(rows, columns):
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(columns)
    for r in rows:
        w.writerow([_fmt(r[c]) for c in columns])
    return buf.getvalue()


def _md_table(header, lines):
    out = ["| " + " | ".join(header) + " |", "|" + "|".join("---" for _ in header) + "|"]
    out += ["| " + " | ".join(str(x) for x in ln) + " |" for ln in lines]
    return "\n".join(out)


def make_markdown(rows, tiles, overhead):
    idx = {(r["mode"], r["size"], r["transform"], r["lmax"], r["policy"]): r for r in rows}
    names = [t[0] for t in TF_LIST]
    md = ["# Memory-access model, step 1.4",
          "",
          "**Our interpretation** of the paper's scheme (blocks = runs of output pixels sharing source row x0, "
          "capped at Lmax; ping-pong prefetch). **All speeds are ESTIMATES** from "
          f"cycles = max(pixels / pixels-per-clock, read beats + {overhead} x read bursts) at 100 MHz; "
          "port ceiling 64 bit x 100 MHz = 800 MB/s (theoretical). Full data: `memmodel_step1_4.csv`. "
          "P0 = fetch both rows every block; P1 = reuse rows the previous block already holds. "
          "amp = bytes read / (W x H).",
          ""]
    for (W, H) in GRAY_SIZES[-1:]:
        md += [f"## Grayscale {W}x{H} (W x H, paper size)", ""]
        lines = []
        for n in names:
            for L in LMAXES:
                a, c = idx[("gray", f"{W}x{H}", n, L, "P0")], idx[("gray", f"{W}x{H}", n, L, "P1")]
                lines.append([n, L, a["blocks"], a["bursts"], c["bursts"], f"{a['read_amp']:.2f}",
                              f"{c['read_amp']:.2f}", f"{c['mean_burst_beats']:.2f}", f"{a['est_fps']:.1f}",
                              f"{c['est_fps']:.1f}", f"{c['est_read_mbps']:.0f}", a["max_footprint"],
                              a["pingpong_bytes"]])
        md += [_md_table(["transform", "Lmax", "blocks", "bursts P0", "bursts P1", "amp P0", "amp P1",
                          "mean burst P1 (beats)", "fps P0 (est)", "fps P1 (est)", "read MB/s P1 (est)",
                          "max footprint (B)", "ping-pong (B)"], lines), ""]
    md += ["## Grayscale, all sizes, P1: estimated fps (Lmax 16 / 32 / 64)", ""]
    lines = []
    for n in names:
        ln = [n]
        for (W, H) in GRAY_SIZES:
            ln.append(" / ".join(f"{idx[('gray', f'{W}x{H}', n, L, 'P1')]['est_fps']:.0f}" for L in LMAXES))
        lines.append(ln)
    md += [_md_table(["transform"] + [f"{W}x{H}" for W, H in GRAY_SIZES], lines), ""]
    for (W, H) in BAYER_SIZES:
        md += [f"## Bayer {W}x{H}: Option A vs Option B (P1)", ""]
        lines = []
        for n in names:
            for L in LMAXES:
                a, bb = idx[("A", f"{W}x{H}", n, L, "P1")], idx[("B", f"{W}x{H}", n, L, "P1")]
                lines.append([n, L, f"{a['read_amp']:.2f}", f"{bb['read_amp']:.2f}",
                              f"{a['bytes_read'] / bb['bytes_read']:.2f}", f"{a['est_fps']:.1f}",
                              f"{bb['est_fps']:.1f}", f"{a['write_bus_bytes'] / (W * H):.0f}x",
                              a["pingpong_bytes"], bb["pingpong_bytes"]])
        md += [_md_table(["transform", "Lmax", "amp A", "amp B", "A/B bytes", "fps A (est)", "fps B (est)",
                          "A write beats vs W*H", "ping-pong A (B)", "ping-pong B (B)"], lines), ""]
    W, H = WIDE_SIZE
    md += [f"## Worst-case ping-pong buffer at width 4096 ({W}x{H}), over all transforms", ""]
    lines = []
    for mode in ("gray", "A", "B"):
        for L in LMAXES:
            cand = [idx[(mode, f"{W}x{H}", n, L, "P0")] for n in names]
            worst = max(cand, key=lambda r: r["max_footprint"])
            lines.append([mode, L, worst["max_rows"], worst["max_span"], worst["max_footprint"],
                          worst["pingpong_bytes"], worst["transform"]])
    md += [_md_table(["mode", "Lmax", "max rows", "max span (B)", "max footprint (B)", "ping-pong (B)",
                      "worst transform"], lines), ""]
    md += ["## Information only: output-tile model (gray, fetch source bounding box per T x T tile)", ""]
    lines = [[t["size"], t["transform"], t["tile"], f"{t['read_amp']:.2f}", f"{t['mean_burst_beats']:.2f}",
              t["pingpong_bytes"]] for t in tiles]
    md += [_md_table(["size", "transform", "T", "amp", "mean burst (beats)", "ping-pong (B)"], lines), ""]
    return "\n".join(md) + "\n"


def generate_report(out_base=DEFAULT_OUT, overhead=OVERHEAD, log=print):
    configs = ([("gray", W, H) for W, H in GRAY_SIZES] + [(m, W, H) for W, H in BAYER_SIZES for m in ("A", "B")]
               + [(m, *WIDE_SIZE) for m in ("gray", "A", "B")])
    rows = run_configs(configs, overhead=overhead, log=log)
    tiles = []
    for tf in load_transforms():
        if tf["name"] not in ("identity", "rot15", "rot37", "scale1p25"):
            continue
        for (W, H) in GRAY_SIZES[-1:]:
            for T in TILES:
                t = tile_stats(W, H, _b_for(tf, W, H), T)
                t["transform"] = tf["name"]
                tiles.append(t)
    csv_text = rows_to_csv(rows, COLUMNS)
    md = make_markdown(rows, tiles, overhead)
    os.makedirs(os.path.dirname(out_base), exist_ok=True)
    with open(out_base + ".csv", "w", newline="\n") as f:
        f.write(csv_text)
    with open(out_base + "_tiles.csv", "w", newline="\n") as f:
        f.write(rows_to_csv(tiles, TILE_COLUMNS))
    with open(out_base + ".md", "w", encoding="utf-8", newline="\n") as f:
        f.write(md)
    return rows, tiles


def main(argv=None):
    p = argparse.ArgumentParser(prog="python -m model.memmodel", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out", default=DEFAULT_OUT, help="output base path (.csv, _tiles.csv, .md are added)")
    p.add_argument("--overhead", type=int, default=OVERHEAD, help="cycles per read burst (estimate)")
    a = p.parse_args(argv)
    t0 = time.perf_counter()
    rows, tiles = generate_report(a.out, a.overhead)
    print(f"memmodel: {len(rows)} rows + {len(tiles)} tile rows -> {a.out}.csv/.md "
          f"({time.perf_counter() - t0:.0f} s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
