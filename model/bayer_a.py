"""Bayer Option A, hardware view (step 5.1): what the engine does in MODE 1, written out so it can be checked.

spec/interface.md section 18 is the text; this file is the same rules as code. The bit-exact reference stays
model/bayer.py warp_bayer (split, warp each plane, merge). Nothing here calls split_rggb or merge_rggb: the passes
read the full mosaic at the memory row / column the spec gives and write it back through 64-bit words with WSTRB,
so a test that compares the two checks the addressing of the spec, not just the arithmetic.

One job = four plane passes in the order R, Gr, Gb, B (bayer.PLANES). Pass p, plane offset o = (o_row, o_col):
  coefficients   b_p = (b11, b12, T_px, b21, b22, T_py), T_p from the T registers (D2, D12)
  output grid    Hp x Wp = H/2 x W/2 plane pixels (u, v); D1 on the plane size (Hp - 1, Wp - 1)
  source         plane row x -> memory row 2x + o_row, plane column y -> memory column 2y + o_col,
                 byte address SRC_ADDR + (2x + o_row) * W + (2y + o_col); x1 = min(x0 + 1, Hp - 1),
                 y1 = min(y0 + 1, Wp - 1) are clamped in PLANE coordinates
  output         plane pixel (u, v) -> byte DST_ADDR + (2u + o_row) * W + 2v + o_col. Each output row 2u + o_row
                 is written as W/8 full 64-bit beats; word j carries plane pixels 4j .. 4j+3 in bytes o_col,
                 o_col + 2, o_col + 4, o_col + 6, the other bytes 0, WSTRB = 0x55 << o_col (D19)
  bursts         reads: memmodel.schedule() of the pass (Pass "A-<plane>"); writes: every output row split like a
                 gray row (<= 16 beats, no 4 KB crossing)
"""

import numpy as np

from model import bayer as BY
from model import memmodel as MM
from model import patrm as P

FILL = 0xA5                       # what the output area holds before the job (as the board tests fill it)


def pass_configs(b, W, H):
    """The four pass configurations, in pass order. Raises like warp_bayer for a bad size or transform."""
    P.check_size(W, H, "bayer")
    BY.check_bayer_transform(b, W, H)
    bp = BY.plane_b(b)
    out = []
    for k, p in enumerate(BY.PLANES):
        o_row, o_col = BY.OFFSETS[p]
        out.append(dict(index=k, plane=p, o_row=o_row, o_col=o_col, b=bp[p], Wp=W // 2, Hp=H // 2,
                        wstrb=0x55 << o_col))
    return out


def pass_pixels(mosaic, W, H, cfg):
    """Plane output (Hp, Wp) of one pass, read straight from the full mosaic with the stride-2 addressing."""
    Wp, Hp, o_row, o_col = cfg["Wp"], cfg["Hp"], cfg["o_row"], cfg["o_col"]
    X, Y = P.coords(cfg["b"], Wp, Hp)
    X = X.astype(np.int64)
    Y = Y.astype(np.int64)
    valid = (X >= 0) & (X <= (Hp - 1) * P.ONE) & (Y >= 0) & (Y <= (Wp - 1) * P.ONE)
    Xv = np.where(valid, X, 0)
    Yv = np.where(valid, Y, 0)
    x0, y0 = Xv >> 16, Yv >> 16
    xf, yf = Xv & 0xFFFF, Yv & 0xFFFF
    x1 = np.minimum(x0 + 1, Hp - 1)
    y1 = np.minimum(y0 + 1, Wp - 1)
    flat = np.asarray(mosaic, dtype=np.int64).ravel()

    def byte(x, y):                              # memory row 2x + o_row, memory column 2y + o_col
        return flat[(2 * x + o_row) * W + 2 * y + o_col]
    d = P.interp_d10(xf, yf, byte(x0, y0), byte(x0, y1), byte(x1, y0), byte(x1, y1))[4]
    return np.where(valid, d, 0).astype(np.uint8)


def pass_words(plane, W, cfg):
    """Output words of one pass: (Hp, W/8) uint64 data and the (constant) strobe. Byte k = bits 8k+7:8k."""
    Hp, Wp = plane.shape
    full = np.zeros((Hp, W), dtype=np.uint8)
    full[:, cfg["o_col"]::2] = plane                      # plane pixel v -> byte 2v + o_col of the row
    return full.view("<u8").reshape(Hp, W // 8), cfg["wstrb"]


def write_rows(W, cfg, dst_addr=MM.DST_ADDR):
    """Byte address of every output row the pass writes, in order (row 2u + o_row)."""
    return [dst_addr + (2 * u + cfg["o_row"]) * W for u in range(cfg["Hp"])]


def apply_pass(mem, W, cfg, words, wstrb, dst_addr=MM.DST_ADDR):
    """Write the pass into mem (flat uint8 array = the output area at dst_addr) as the AXI slave would:
    only bytes whose strobe bit is 1 change. Returns (beats, bursts) issued."""
    mask = np.array([(wstrb >> k) & 1 for k in range(8)], dtype=bool)
    beats = bursts = 0
    wb = words.view(np.uint8).reshape(words.shape[0], W)
    for u, a in enumerate(write_rows(W, cfg, dst_addr)):
        row = a - dst_addr
        seg = mem[row:row + W].reshape(W // 8, 8)
        new = wb[u].reshape(W // 8, 8)
        seg[:, mask] = new[:, mask]
        mem[row:row + W] = seg.ravel()
        bl = MM.split_bursts(a, a + W)
        bursts += len(bl)
        beats += sum(n for _, n in bl)
    return beats, bursts


def read_schedule(W, H, b, L=MM.BLOCK_LEN_MAX, span_max=MM.SPAN_MAX, policy="P1", nslot=MM.NSLOT):
    """Per pass (pass order): (Pass, block dict, schedule blocks, schedule bursts), from model/memmodel.py."""
    out = []
    for ps in MM.build_passes("A", W, H, b):
        blk = MM.make_blocks(ps, L, span_max)
        sb, bu = MM.schedule(ps, blk, W, policy, nslot)
        out.append((ps, blk, sb, bu))
    return out


def run_job(mosaic, W, H, b, L=MM.BLOCK_LEN_MAX, span_max=MM.SPAN_MAX):
    """The whole Option A job. Returns (output mosaic (H, W) uint8, counters dict).
    Counters as the hardware defines them (spec/interface.md sections 13 and 18): BYTES_RD = 8 x R beats of the
    four read schedules, BYTES_WR = 8 x W beats (masked beats included)."""
    cfgs = pass_configs(b, W, H)
    mem = np.full(W * H, FILL, dtype=np.uint8)
    wr_beats = wr_bursts = 0
    for cfg in cfgs:
        plane = pass_pixels(mosaic, W, H, cfg)
        words, strb = pass_words(plane, W, cfg)
        be, bu = apply_pass(mem, W, cfg, words, strb)
        wr_beats += be
        wr_bursts += bu
    rd_beats = rd_bursts = 0
    for _, _, _, bursts in read_schedule(W, H, b, L, span_max):
        rd_bursts += len(bursts)
        rd_beats += sum(r[5] for r in bursts)
    return mem.reshape(H, W), dict(bytes_rd=8 * rd_beats, rd_bursts=rd_bursts, bytes_wr=8 * wr_beats,
                                   wr_bursts=wr_bursts, passes=len(cfgs))
