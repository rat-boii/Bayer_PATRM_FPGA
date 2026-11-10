"""Memory-access model: the exact block / fetch schedule the RTL follows (step 1.4, made exact in step 2.2).
All throughput figures are ESTIMATES, not measurements.

The paper only says: burst length follows the coordinate slope and a ping-pong RAM pair prefetches the next
block while the current one is interpolated. Our rules (D14, D15, D16; the RTL must follow them exactly):

Blocks   Output pixels are scanned row by row, v = 0 .. Wo-1. A pixel is valid by D1; its key is its source top
         row x0 (Option B: the pair (min x0, max x0) over the four lanes). A block starts at v = 0 of every
         output row, and before pixel v when the first of these holds (this is also the recorded end reason):
           (a) x0   v is valid, the row already had a valid pixel, and key(v) != key of the most recent valid
                    pixel of this output row. Invalid pixels never end a block on their own and never change
                    the key; a block may start with invalid pixels.
           (b) len  the block already has BLOCK_LEN pixels (valid or not).
           (c) span v is valid and adding it would make the block's aligned byte span exceed SPAN_MAX.
         span = ceil8(max column + 1) - floor8(min column) over the block's valid pixels, in source-row bytes
         (Bayer A: full-resolution columns 2y + o_col; Bayer B: union of the lanes). One column range per block,
         shared by all its rows. A single pixel always fits (span <= 16 <= SPAN_MAX).
Rows     A block with valid pixels needs source rows x0 and x1 = min(x0 + 1, H - 1); at the bottom edge
         (x0 = H - 1) that is ONE row, and r3/r4 are read from the same row (their weight is 0 by D1).
         Columns: y1 = min(y0 + 1, W - 1), so the range never passes the row end (W is a multiple of 8).
         A block whose pixels are all invalid needs no rows and fetches nothing.
Reads    Per needed row: byte range [s, e) = SRC_ADDR + row*W + [floor8(cmin), ceil8(cmax + 1)), split into
         AXI3 bursts of <= 16 beats x 8 bytes, never across 4 KB; rows in order top, bottom; blocks in order.
Policies P0: fetch every needed row of every block.
         P1 (D14, the hardware): skip a row if the PREVIOUS FETCHING BLOCK (the last earlier block with a valid
             pixel) needed that same row AND that block's aligned range [s', e') covers [s, e). The compare
             uses the range the previous block needed, not a possibly wider range still in its slot. Partial
             overlap = no reuse: the whole range is fetched again.
Slots    (schedule() only) the on-chip buffer is NSLOT row slots of SPAN_MAX bytes. A reused row keeps its
         slot. A fetched row takes the next slot of a ring (pointer advances by one per fetched row), skipping
         slots the current block already uses. The RTL waits until every earlier block using that slot has
         been interpolated before overwriting it; the slot numbers therefore depend only on the block list.
Writes   Output rows in 128-byte bursts (no 4 KB crossing) at DST_ADDR. Bayer A writes every full row
         once per plane pass with WSTRB on every other byte; Bayer B writes whole row pairs.
Bayer A  Four plane passes; plane row x -> full row 2x+o_row, plane column y -> full column 2y+o_col; the
         FULL-resolution bytes covering the plane span are read (about 2x the useful bytes).
Bayer B  One pass in plane coordinates, four lanes (coords of b_p = coords of b_R + T_p - T_R, D6); per
         block the union of the lanes' needs is read as full-resolution row pairs (2x, 2x+1).
Speed    ESTIMATE: cycles = max(output pixels / pixels per clock, read beats + OVERHEAD x read bursts)
         (per pass for Bayer A, passes summed); pixels per clock = 1 (gray, A) or 4 (B); assumes enough
         blocks in flight and >= 2 outstanding reads to hide the DDR latency. fps at 100 MHz (D8).
         Port ceiling 64 bit x 100 MHz = 800 MB/s (theoretical).

    python -m model.memmodel [--out results/memmodel_step1_4] [--overhead 2]     step 1.4 report
    python -m model.memmodel --step22                                           step 2.2 report
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
SPAN_MAX = 512                  # D16: largest aligned byte span of a block (= one buffer slot)
BLOCK_LEN_MAX = 64              # D15: synthesis parameter; driver default BLOCK_LEN
NSLOT = 32                      # buffer row slots (proposal, spec/interface.md); slot = SPAN_MAX bytes
REASONS = {0: "row", 1: "x0", 2: "len", 3: "span"}     # why a block ended (D16 order a, b, c)

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

def aligned_span(cmin, cmax):
    """Bytes of the 8-byte aligned range covering memory columns cmin..cmax (inclusive)."""
    return ((cmax + 1 + BEAT - 1) // BEAT) * BEAT - (cmin // BEAT) * BEAT


def pixel_needs(ps):
    """Per output pixel (union over lanes): anyv, rlo, rhi (plane rows), clo, chi (plane columns), key,
    mc0, mc1 (memory columns, colmap applied). Arrays of the output grid shape."""
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
    cm, alo, ahi = ps.colmap
    mc0 = np.where(anyv, cm * clo + alo, BIG)
    mc1 = np.where(anyv, cm * chi + ahi, -BIG)
    return dict(anyv=anyv, rlo=rlo, rhi=rhi, clo=clo, chi=chi, key=key, mc0=mc0, mc1=mc1)


def _apply_span_rule(start, boundary, anyv, mc0, mc1, L, span_max):
    """Rule (c). start/boundary are flat bool arrays (rule (a)+(b) starts, rule (a) / row starts).
    Blocks that would exceed span_max are re-planned pixel by pixel over their whole key run (rule (c)
    restarts the BLOCK_LEN count, so the rest of the run shifts)."""
    st = np.flatnonzero(start)
    lo = np.minimum.reduceat(mc0, st)
    hi = np.maximum.reduceat(mc1, st)
    has = lo < BIG
    span = np.where(has, aligned_span(np.where(has, lo, 0), np.where(has, hi, 0)), 0)
    bad = np.flatnonzero(span > span_max)
    if bad.size == 0:
        return start
    start = start.copy()
    run_id = np.cumsum(boundary) - 1
    run_st = np.flatnonzero(boundary)
    run_end = np.r_[run_st[1:], boundary.size]
    for r in np.unique(run_id[st[bad]]):
        a, e = int(run_st[r]), int(run_end[r])
        n, lo_, hi_ = 0, BIG, -BIG
        for q in range(a, e):
            new = q == a or n == L
            if not new and anyv[q]:
                if aligned_span(min(lo_, int(mc0[q])), max(hi_, int(mc1[q]))) > span_max:
                    new = True
            if new:
                n, lo_, hi_ = 0, BIG, -BIG
            start[q] = new
            n += 1
            if anyv[q]:
                lo_, hi_ = min(lo_, int(mc0[q])), max(hi_, int(mc1[q]))
    return start


def make_blocks(ps, Lmax, span_max=SPAN_MAX):
    """Cut the pass into blocks by D16 rules (a) x0, (b) BLOCK_LEN = Lmax, (c) span_max (None = no rule c).
    Returns dict with bid (block id per output pixel), nblocks, per block (all blocks, in order): start
    (flat pixel index), n (pixels), nvalid, reason (REASONS); and for blocks that need data (in order):
    ids, rlo, rhi (plane rows needed, inclusive), clo, chi (plane columns needed, inclusive)."""
    if span_max is not None and (span_max < 2 * BEAT or span_max % BEAT):
        raise ValueError("span_max must be a multiple of 8 and >= 16")
    nd = pixel_needs(ps)
    anyv, key = nd["anyv"], nd["key"]
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
    if L < 1:
        raise ValueError("BLOCK_LEN must be >= 1")
    start = (boundary | (((cols - vstart) % L) == 0)).ravel()
    fv = anyv.ravel()
    if span_max is not None:
        start = _apply_span_rule(start, boundary.ravel(), fv, nd["mc0"].ravel(), nd["mc1"].ravel(), L, span_max)
    bid = np.cumsum(start) - 1
    nblocks = int(bid[-1]) + 1
    bst = np.flatnonzero(start)
    bn = np.diff(np.r_[bst, start.size])
    nvalid = np.add.reduceat(fv.astype(np.int64), bst)
    # end reason: the start rule that fired at the next pixel of the same output row
    nxt_px = bst + bn
    reason = np.zeros(nblocks, dtype=np.int64)
    inrow = (nxt_px % Wo) != 0
    q = nxt_px[inrow]
    bflat = boundary.ravel()
    r = np.where(bflat[q], 1, np.where(bn[inrow] == L, 2, 3))
    reason[inrow] = r
    out = dict(bid=bid.reshape(Ho, Wo), nblocks=nblocks, start=bst, n=bn, nvalid=nvalid, reason=reason,
               Wo=Wo, L=L, span_max=span_max)
    vb = bid[fv]
    if vb.size == 0:
        e = np.zeros(0, dtype=np.int64)
        out.update(ids=e, rlo=e, rhi=e, clo=e, chi=e)
        return out
    st = np.flatnonzero(np.r_[True, vb[1:] != vb[:-1]])
    out.update(ids=vb[st],
               rlo=np.minimum.reduceat(nd["rlo"].ravel()[fv], st), rhi=np.maximum.reduceat(nd["rhi"].ravel()[fv], st),
               clo=np.minimum.reduceat(nd["clo"].ravel()[fv], st), chi=np.maximum.reduceat(nd["chi"].ravel()[fv], st))
    return out


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


SCHED_BLOCK_COLS = ("id", "u", "v0", "n", "nvalid", "reason", "nrows", "row_top", "row_bot", "s_col", "span",
                    "fetch_top", "fetch_bot", "slot_top", "slot_bot")
SCHED_BURST_COLS = ("block", "row", "slot", "word", "addr", "beats")


def schedule(ps, blk, W, policy="P1", nslot=NSLOT, src_addr=SRC_ADDR):
    """The exact schedule the RTL follows for one pass (gray or one Bayer A plane pass: one memory row per
    plane row). Returns (blocks, bursts):
      blocks: one dict per block (all blocks, in order) with SCHED_BLOCK_COLS; blocks without valid pixels
              have nrows = 0 and -1 in the row/slot/range fields. nrows = 1 at the bottom edge (row_bot =
              row_top, slot_bot = slot_top, fetch_bot = 0).
      bursts: AR order, one tuple per burst (block id, memory row, slot, first word in the slot, byte address,
              beats).
    Slots: see the module docstring (ring of nslot slots, reused rows keep their slot)."""
    if len(ps.rowmap) != 1:
        raise ValueError("schedule() covers gray and Bayer A passes (one memory row per plane row)")
    if nslot < 4:
        raise ValueError("nslot must be >= 4")
    mul, add = ps.rowmap[0]
    s_col, e_col, nr = _block_geometry(ps, blk)
    nfb = len(blk["ids"])
    reuse = np.zeros((2, nfb), dtype=bool)
    for k in range(2):
        reuse[k] = _reuse_mask(blk, s_col, e_col, blk["rlo"] + k, policy) & (k < nr)
    if nfb and nr.max() > 2:
        raise ValueError("a gray / Bayer A block needs at most 2 rows")
    fidx = {int(b): i for i, b in enumerate(blk["ids"])}
    Wo = blk["Wo"]
    blocks, bursts = [], []
    prev, ptr = {}, 0
    for j in range(blk["nblocks"]):
        st = int(blk["start"][j])
        rec = dict(id=j, u=st // Wo, v0=st % Wo, n=int(blk["n"][j]), nvalid=int(blk["nvalid"][j]),
                   reason=int(blk["reason"][j]), nrows=0, row_top=-1, row_bot=-1, s_col=-1, span=0,
                   fetch_top=0, fetch_bot=0, slot_top=-1, slot_bot=-1)
        i = fidx.get(j)
        if i is not None:
            rows = [mul * (int(blk["rlo"][i]) + k) + add for k in range(int(nr[i]))]
            slots, used = [None] * len(rows), set()
            for k, r in enumerate(rows):
                if reuse[k][i]:
                    slots[k] = prev[r]
                    used.add(prev[r])
            for k, r in enumerate(rows):
                if slots[k] is None:
                    while ptr in used:
                        ptr = (ptr + 1) % nslot
                    slots[k] = ptr
                    used.add(ptr)
                    ptr = (ptr + 1) % nslot
            sc, ec = int(s_col[i]), int(e_col[i])
            for k, r in enumerate(rows):
                if not reuse[k][i]:
                    s0 = src_addr + r * W + sc
                    for addr, beats in split_bursts(s0, src_addr + r * W + ec):
                        bursts.append((j, r, slots[k], (addr - s0) // BEAT, addr, beats))
            rec.update(nrows=len(rows), row_top=rows[0], row_bot=rows[-1], s_col=sc, span=ec - sc,
                       fetch_top=int(not reuse[0][i]),
                       fetch_bot=int(len(rows) == 2 and not reuse[1][i]),
                       slot_top=slots[0], slot_bot=slots[-1])
            prev = dict(zip(rows, slots))
        blocks.append(rec)
    return blocks, bursts


def schedule_text(blocks, bursts, header):
    """Text of the two dump files (blocks, bursts): '#' header lines, then one line of integers per record."""
    hb = "\n".join("# " + h for h in header)
    tb = [hb, "# " + " ".join(SCHED_BLOCK_COLS)]
    tb += [" ".join(str(b[c]) for c in SCHED_BLOCK_COLS) for b in blocks]
    tr = [hb, "# " + " ".join(SCHED_BURST_COLS)]
    tr += [" ".join(str(x) for x in r) for r in bursts]
    return "\n".join(tb) + "\n", "\n".join(tr) + "\n"


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


# ---------------------------------------------------------------------------
# Step 2.2 report: exact schedule (D14 P1, D15 BLOCK_LEN 64, D16 SPAN_MAX 512)
# ---------------------------------------------------------------------------

OUT_22 = os.path.join(ROOT, "results", "memmodel_step2_2")
SCHED_CONFIGS = ((64, 512), (32, 32))   # (BLOCK_LEN, SPAN_MAX): D15/D16, and a stress setting for rule (c)
EXTREMES = [("scale0p1", dict(sx=0.1, sy=0.1)), ("scale0p25", dict(sx=0.25, sy=0.25)),
            ("cols0p1", dict(sy=0.1)), ("rot30_scale0p2", dict(rot_deg=30.0, sx=0.2, sy=0.2))]
COMPARE_KEYS = ("blocks", "bursts", "beats", "bytes_read", "est_cycles", "est_fps", "max_footprint")


def block_reasons(mode, W, H, b, L, span_max=SPAN_MAX):
    """Count of block end reasons and the largest block span / footprint over all passes."""
    cnt = {v: 0 for v in REASONS.values()}
    max_span = max_fp = 0
    for ps in build_passes(mode, W, H, b):
        blk = make_blocks(ps, L, span_max)
        for k, v in REASONS.items():
            cnt[v] += int((blk["reason"] == k).sum())
        s_col, e_col, nr = _block_geometry(ps, blk)
        if len(nr):
            span = e_col - s_col
            max_span = max(max_span, int(span.max()))
            max_fp = max(max_fp, int((nr * len(ps.rowmap) * span).max()))
    return cnt, max_span, max_fp


def generate_report_22(out_base=OUT_22, overhead=OVERHEAD, log=print):
    cfg = [("gray", W, H) for W, H in GRAY_SIZES]
    rows = run_configs(cfg, overhead=overhead, log=log)
    # compare with the step 1.4 CSV (same rules except D16 (c), which cannot fire for these transforms)
    old = {}
    path14 = DEFAULT_OUT + ".csv"
    if os.path.exists(path14):
        with open(path14) as f:
            for r in csv.DictReader(f):
                if r["mode"] == "gray":
                    old[(r["size"], r["transform"], int(r["lmax"]), r["policy"])] = r
    same = diff = 0
    diffs = []
    for r in rows:
        o = old.get((r["size"], r["transform"], r["lmax"], r["policy"]))
        if o is None:
            continue
        d = [k for k in COMPARE_KEYS if _fmt(r[k]) != o[k]]
        if d:
            diff += 1
            diffs.append(f"{r['size']} {r['transform']} L{r['lmax']} {r['policy']}: {', '.join(d)}")
        else:
            same += 1
    ext = []
    for name, fw in EXTREMES:
        for mode, (W, H) in (("gray", GRAY_SIZES[-1]), ("A", BAYER_SIZES[0])):
            b = P.make_b(W, H, **fw)
            st = frame_stats(mode, W, H, b, BLOCK_LEN_MAX, "P1", overhead=overhead)
            cnt, mspan, mfp = block_reasons(mode, W, H, b, BLOCK_LEN_MAX)
            ext.append([name, mode, f"{W}x{H}", st["blocks"], cnt["row"], cnt["x0"], cnt["len"], cnt["span"],
                        mspan, mfp, f"{st['read_amp']:.2f}", f"{st['est_fps']:.1f}"])
            if log:
                log(f"  extreme {name} {mode}: {cnt}")
    idx = {(r["size"], r["transform"], r["lmax"], r["policy"]): r for r in rows}
    names = [t[0] for t in TF_LIST]
    md = ["# Memory schedule, step 2.2 (exact hardware rules)", "",
          "Rules: D14 (P1 row reuse), D15 (BLOCK_LEN_MAX 64, driver default 64), D16 (block ends at x0 change, "
          f"BLOCK_LEN, or SPAN_MAX = {SPAN_MAX} bytes); exact definitions in the docstring of `model/memmodel.py` "
          "and in `spec/interface.md`. **All speeds are ESTIMATES** (same formula as step 1.4: "
          f"cycles = max(pixels, read beats + {overhead} x read bursts) at 100 MHz, latency assumed hidden). "
          "Full data: `memmodel_step2_2.csv`.", "",
          "## Comparison with step 1.4 (grayscale, all sizes, Lmax 16/32/64, P0 and P1)", "",
          f"{same} of {same + diff} rows identical to `memmodel_step1_4.csv` in "
          f"{', '.join(COMPARE_KEYS)}." + ("" if not diff else " Differences: " + "; ".join(diffs[:10])),
          "Reason: rule (c) never fires for the nine test transforms (largest block span at 2448x2095 is far "
          f"below {SPAN_MAX} bytes), and rules (a), (b) and P1 are the step 1.4 rules, now written down exactly.",
          "", f"## Grayscale {GRAY_SIZES[-1][0]}x{GRAY_SIZES[-1][1]}, P1, BLOCK_LEN 64 (D15): the configuration we build", ""]
    W, H = GRAY_SIZES[-1]
    lines = []
    for n in names:
        r = idx[(f"{W}x{H}", n, 64, "P1")]
        lines.append([n, r["blocks"], r["bursts"], f"{r['read_amp']:.2f}", f"{r['mean_burst_beats']:.2f}",
                      f"{r['est_fps']:.1f}", f"{r['est_read_mbps']:.0f}", r["max_span"], r["max_footprint"]])
    md += [_md_table(["transform", "blocks", "bursts", "amp", "mean burst (beats)", "fps (est)",
                      "read MB/s (est)", "max span (B)", "max footprint (B)"], lines), ""]
    md += ["## Grayscale, all sizes, P1: estimated fps (Lmax 16 / 32 / 64), unchanged from step 1.4", ""]
    lines = []
    for n in names:
        ln = [n]
        for (W, H) in GRAY_SIZES:
            ln.append(" / ".join(f"{idx[(f'{W}x{H}', n, L, 'P1')]['est_fps']:.0f}" for L in LMAXES))
        lines.append(ln)
    md += [_md_table(["transform"] + [f"{W}x{H}" for W, H in GRAY_SIZES], lines), ""]
    md += ["## Extreme zoom-out (rule (c) at work), BLOCK_LEN 64, P1", "",
           "Every D4-valid transform is supported: rule (c) caps every block at "
           f"{SPAN_MAX} bytes per row, so a gray or Bayer A block never needs more than 2 x {SPAN_MAX} bytes "
           "of buffer. Here the estimate stays at the compute bound (1 pixel per clock): most output pixels of a "
           "zoom-out fall outside the source and need no data, and the valid ones read long bursts; rule (c) "
           "only splits the blocks that would be too wide. Speed falls only where blocks become very short "
           "(large rotations, see the table above).", ""]
    md += [_md_table(["transform", "mode", "size", "blocks", "end: row", "end: x0", "end: len", "end: span",
                      "max span (B)", "max footprint (B)", "amp", "fps (est)"], ext), ""]
    md += ["## On-chip buffer", "",
           f"NSLOT = {NSLOT} row slots x SPAN_MAX = {SPAN_MAX} bytes = {NSLOT * SPAN_MAX // 1024} KB "
           "(gray and Bayer A need at most 2 slots per block; see spec/interface.md for the RAM organisation).", ""]
    os.makedirs(os.path.dirname(out_base), exist_ok=True)
    with open(out_base + ".csv", "w", newline="\n") as f:
        f.write(rows_to_csv(rows, COLUMNS))
    with open(out_base + ".md", "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(md) + "\n")
    return rows, same, diff, ext


def main(argv=None):
    p = argparse.ArgumentParser(prog="python -m model.memmodel", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out", default=DEFAULT_OUT, help="output base path (.csv, _tiles.csv, .md are added)")
    p.add_argument("--overhead", type=int, default=OVERHEAD, help="cycles per read burst (estimate)")
    p.add_argument("--step22", action="store_true", help="write the step 2.2 report (results/memmodel_step2_2)")
    a = p.parse_args(argv)
    t0 = time.perf_counter()
    if a.step22:
        rows, same, diff, _ = generate_report_22(overhead=a.overhead)
        print(f"memmodel step 2.2: {len(rows)} rows, {same} identical to step 1.4, {diff} differ -> "
              f"{OUT_22}.md ({time.perf_counter() - t0:.0f} s)")
        return 0
    rows, tiles = generate_report(a.out, a.overhead)
    print(f"memmodel: {len(rows)} rows + {len(tiles)} tile rows -> {a.out}.csv/.md "
          f"({time.perf_counter() - t0:.0f} s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
