"""Step 5.1 check: the Option A spec (spec/interface.md section 18, model/bayer_a.py) against the reference model.

    python -m model.test_bayer_a            # all checks
    python -m model.test_bayer_a --quick    # without the 480x272 board-size group

  [1] pass order R, Gr, Gb, B; b_p uses T_p from bayer.plane_shifts (D2/D12); WSTRB 0x55 / 0xAA / 0x55 / 0xAA;
      the four (row parity, strobe) pairs write every byte of a frame exactly once
  [2] bit-exact with bayer.warp_bayer: sim sizes 64x64, 128x96, 256x192, 208x120 x all transforms x 2 mosaics,
      no fill byte left in the output
  [3] board size 480x272 x all transforms (skipped with --quick)
  [4] 40 seeded random D4-valid transforms (rotation, scale, shift, mirror) + the memmodel.EXTREMES zooms (rule (c)
      cuts blocks at SPAN_MAX) on random mosaics, sim sizes; the zooms also at 1024x64 and 2048x64, where a
      block reaches the 64-word slot bound (checked)
  [5] counters: BYTES_WR = 2 x W x H and write bursts = memmodel.write_stats("A"); BYTES_RD of the four read
      schedules = memmodel.frame_stats("A") (L 64, SPAN_MAX 512, P1)
  [6] read schedule of every pass in [2] and [4], both (BLOCK_LEN, SPAN_MAX) configs of memmodel.SCHED_CONFIGS:
      bursts inside the source frame and on rows of the pass's parity; every valid pixel's four neighbour bytes
      (memory rows 2x + o_row, columns 2y + o_col) lie in its block's rows and fetched column range; command words
      <= 64 and reused rows inside the range their slot holds (the step 3.6b slot-word rule still holds)
  [7] identity reproduces the input mosaic exactly; an even integer shift moves it by whole pixels
  [8] the comparison notices a wrong column offset and a full strobe (8'hFF) in the last pass
The last line is TEST PASS or TEST FAIL: <reason>.
"""
import argparse
import os
import sys
import time

import numpy as np

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from model import bayer as BY            # noqa: E402
from model import bayer_a as BA          # noqa: E402
from model import memmodel as MM         # noqa: E402
from model import patrm as P             # noqa: E402

SIM_SIZES = [(64, 64), (128, 96), (256, 192), (208, 120)]
BOARD_SIZES = [(480, 272)]
WIDE_SIZES = [(1024, 64), (2048, 64)]      # extreme zooms only
SLOT_WORDS = 64


class Fail(Exception):
    pass


def check(cond, msg):
    if not cond:
        raise Fail(msg)


def mosaic(W, H, seed):
    return np.random.default_rng(seed).integers(0, 256, size=(H, W), dtype=np.uint8)


def gradient_mosaic(W, H):
    u, v = np.meshgrid(np.arange(H), np.arange(W), indexing="ij")
    return ((u * 7 + v * 3 + (u % 2) * 60 + (v % 2) * 120) % 256).astype(np.uint8)


def random_transforms(W, H, n, seed):
    rng = np.random.default_rng(seed)
    out = []
    while len(out) < n:
        fw = dict(rot_deg=float(rng.uniform(-180, 180)), sx=float(rng.uniform(0.3, 2.5)),
                  sy=float(rng.uniform(0.3, 2.5)),
                  shift=(float(rng.uniform(-0.6, 0.6) * H), float(rng.uniform(-0.6, 0.6) * W)),
                  mirror_rows=bool(rng.integers(2)), mirror_cols=bool(rng.integers(2)))
        b = P.make_b(W, H, **fw)
        try:
            BY.check_bayer_transform(b, W, H)
        except ValueError:
            continue
        out.append((f"rand{len(out)}", b))
    return out


def check_schedule(W, H, b, L, S, name):
    """[6] for one job; returns (commands, reused rows, max command words, max held words)."""
    cmds = reused = cmd_w = held_w = 0
    for cfg, (ps, blk, sb, bursts) in zip(BA.pass_configs(b, W, H), BA.read_schedule(W, H, b, L, S)):
        tag = f"{name} {W}x{H} L{L} S{S} pass {cfg['plane']}"
        for (_, row, _, _, addr, beats) in bursts:
            check(row % 2 == cfg["o_row"], f"{tag}: burst on memory row {row}, wrong parity")
            check(MM.SRC_ADDR <= addr and addr + 8 * beats <= MM.SRC_ADDR + W * H, f"{tag}: burst outside the source")
        held = {}
        for r in sb:
            if r["nrows"] == 0:
                continue
            s, e = r["s_col"], r["s_col"] + r["span"]
            check(r["span"] <= S and e <= W and s >= 0, f"{tag}: block {r['id']} range [{s}, {e})")
            rows = [(r["row_top"], r["slot_top"], r["fetch_top"])]
            if r["nrows"] == 2:
                rows.append((r["row_bot"], r["slot_bot"], r["fetch_bot"]))
            for row, slot, fetched in rows:
                if fetched:
                    cmds += 1
                    cmd_w = max(cmd_w, r["span"] // 8)
                    held[slot] = (row, s, e)
                else:
                    reused += 1
                    hrow, hs, he = held.get(slot, (None, 0, 0))
                    check(hrow == row and hs <= s and e <= he, f"{tag}: block {r['id']} reuses row {row} "
                          f"[{s}, {e}) but slot {slot} holds row {hrow} [{hs}, {he})")
                    held_w = max(held_w, (he - hs) // 8)
        # every valid pixel's neighbours inside its block's rows and column range
        Wp, Hp = cfg["Wp"], cfg["Hp"]
        X, Y = P.coords(cfg["b"], Wp, Hp)
        X = X.astype(np.int64)
        Y = Y.astype(np.int64)
        valid = (X >= 0) & (X <= (Hp - 1) * P.ONE) & (Y >= 0) & (Y <= (Wp - 1) * P.ONE)
        if not valid.any():
            continue
        x0, y0 = X[valid] >> 16, Y[valid] >> 16
        x1, y1 = np.minimum(x0 + 1, Hp - 1), np.minimum(y0 + 1, Wp - 1)
        bid = blk["bid"][valid]
        top = np.array([r["row_top"] for r in sb])[bid]
        bot = np.array([r["row_bot"] for r in sb])[bid]
        sc = np.array([r["s_col"] for r in sb])[bid]
        sp = np.array([r["span"] for r in sb])[bid]
        r0, r1 = 2 * x0 + cfg["o_row"], 2 * x1 + cfg["o_row"]
        c0, c1 = 2 * y0 + cfg["o_col"], 2 * y1 + cfg["o_col"]
        check(np.all(r0 == top) and np.all(r1 == bot), f"{tag}: a pixel's rows are not its block's rows")
        check(np.all((c0 >= sc) & (c1 < sc + sp)), f"{tag}: a pixel's columns are outside its block's range")
        check(cmd_w <= SLOT_WORDS and held_w <= SLOT_WORDS, f"{tag}: more than {SLOT_WORDS} words in a slot")
    return cmds, reused, cmd_w, held_w


def job_ok(src, W, H, b, tag):
    out, cnt = BA.run_job(src, W, H, b)
    ref = BY.warp_bayer(src, W, H, b)
    diff = int(np.count_nonzero(out != ref))
    check(diff == 0, f"{tag}: {diff} bytes differ from bayer.warp_bayer")
    check(cnt["bytes_wr"] == 2 * W * H, f"{tag}: BYTES_WR {cnt['bytes_wr']} != 2 W H")
    return cnt


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--quick", action="store_true", help="skip the 480x272 group")
    a = ap.parse_args(argv)
    t0 = time.perf_counter()
    tfs = MM.load_transforms()
    try:
        # [1]
        cfgs = BA.pass_configs(MM._b_for(tfs[0], 64, 64), 64, 64)
        T = BY.plane_shifts(MM._b_for(tfs[0], 64, 64))
        check([c["plane"] for c in cfgs] == ["R", "Gr", "Gb", "B"], "[1] pass order")
        check([c["wstrb"] for c in cfgs] == [0x55, 0xAA, 0x55, 0xAA], "[1] strobes")
        check(all(c["b"][2] == T[c["plane"]][0] and c["b"][5] == T[c["plane"]][1] for c in cfgs), "[1] T_p")
        cover = np.zeros((2, 8), dtype=int)
        for c in cfgs:
            for k in range(8):
                cover[c["o_row"], k] += (c["wstrb"] >> k) & 1
        check(np.all(cover == 1), f"[1] byte coverage {cover.tolist()}")
        print("[1] pass order R Gr Gb B, T_p = plane_shifts, WSTRB 55 AA 55 AA, every byte written once")

        # [2] + [5] + [6]
        jobs = sched = 0
        tot = dict(cmds=0, reused=0, cmd_w=0, held_w=0)

        def sched_all(W, H, b, name):
            nonlocal sched
            for L, S in MM.SCHED_CONFIGS:
                c, r, cw, hw = check_schedule(W, H, b, L, S, name)
                tot["cmds"] += c
                tot["reused"] += r
                tot["cmd_w"] = max(tot["cmd_w"], cw)
                tot["held_w"] = max(tot["held_w"], hw)
                sched += 1

        for (W, H) in SIM_SIZES:
            for tf in tfs:
                b = MM._b_for(tf, W, H)
                for k, src in enumerate((mosaic(W, H, 11 + W + H), gradient_mosaic(W, H))):
                    cnt = job_ok(src, W, H, b, f"[2] {tf['name']} {W}x{H} image {k}")
                    jobs += 1
                fs = MM.frame_stats("A", W, H, b, MM.BLOCK_LEN_MAX, "P1")
                ws = MM.write_stats("A", W, H)
                check(cnt["bytes_rd"] == fs["bytes_read"], f"[5] {tf['name']} {W}x{H}: BYTES_RD {cnt['bytes_rd']} "
                      f"!= memmodel {fs['bytes_read']}")
                check(cnt["wr_bursts"] == ws["write_bursts"], f"[5] {tf['name']} {W}x{H}: write bursts")
                sched_all(W, H, b, tf["name"])
        print(f"[2] {jobs} jobs (4 sizes x {len(tfs)} transforms x 2 mosaics) bit-exact with warp_bayer")
        print(f"[5] BYTES_RD = memmodel and BYTES_WR = 2 W H, write bursts = memmodel, {len(SIM_SIZES) * len(tfs)} jobs")

        # [3]
        if not a.quick:
            for (W, H) in BOARD_SIZES:
                for tf in tfs:
                    job_ok(mosaic(W, H, 5), W, H, MM._b_for(tf, W, H), f"[3] {tf['name']} {W}x{H}")
            print(f"[3] 480x272 x {len(tfs)} transforms bit-exact")
        else:
            print("[3] skipped (--quick)")

        # [4]
        n4 = 0
        for (W, H) in SIM_SIZES:
            extremes = [(n, P.make_b(W, H, **fw)) for n, fw in MM.EXTREMES]     # zooms: rule (c) at SPAN_MAX
            for name, b in random_transforms(W, H, 10, seed=W * 7 + H) + extremes:
                job_ok(mosaic(W, H, n4 + 100), W, H, b, f"[4] {name} {W}x{H}")
                sched_all(W, H, b, name)
                n4 += 1
        for (W, H) in WIDE_SIZES:                       # mosaic rows of 1-2 KB: a block can reach SPAN_MAX = 64 words
            for name, fw in MM.EXTREMES:
                b = P.make_b(W, H, **fw)
                job_ok(mosaic(W, H, n4 + 100), W, H, b, f"[4] {name} {W}x{H}")
                sched_all(W, H, b, name)
                n4 += 1
        check(tot["cmd_w"] == SLOT_WORDS, f"[6] the {SLOT_WORDS}-word bound was not reached (max {tot['cmd_w']})")
        print(f"[4] {n4} random + extreme-zoom transforms bit-exact")
        print(f"[6] {sched} schedules: {tot['cmds']} row commands, {tot['reused']} reused rows, max command words "
              f"{tot['cmd_w']}, max held words {tot['held_w']} (limit {SLOT_WORDS}); rows, ranges, parity, bounds OK")

        # [7]
        for (W, H) in SIM_SIZES:
            src = mosaic(W, H, 3)
            out, _ = BA.run_job(src, W, H, (P.ONE, 0, 0, 0, P.ONE, 0))
            check(np.array_equal(out, src), f"[7] identity {W}x{H}")
            out, _ = BA.run_job(src, W, H, (P.ONE, 0, 4 * P.ONE, 0, P.ONE, 2 * P.ONE))   # source = output + (4, 2)
            check(np.array_equal(out[:H - 4, :W - 2], src[4:, 2:]) and not out[H - 4:].any() and
                  not out[:, W - 2:].any(), f"[7] shift (4, 2) {W}x{H}")
        print("[7] identity exact; shift by (4, 2) full pixels moves the mosaic, uncovered border 0")

        # [8]
        W, H = 64, 64
        src, b = mosaic(W, H, 7), MM._b_for(next(t for t in tfs if t["name"] == "rot15"), W, H)
        ref = BY.warp_bayer(src, W, H, b)
        cfgs = BA.pass_configs(b, W, H)
        bad_off = dict(cfgs[1], o_col=0)                     # Gr pass reading the R columns
        mem = np.full(W * H, BA.FILL, dtype=np.uint8)
        for c in cfgs[:1] + [bad_off] + cfgs[2:]:
            w, s = BA.pass_words(BA.pass_pixels(src, W, H, c), W, c)
            BA.apply_pass(mem, W, c, w, s)
        n_off = int(np.count_nonzero(mem.reshape(H, W) != ref))
        mem = np.full(W * H, BA.FILL, dtype=np.uint8)
        for k, c in enumerate(cfgs):
            w, s = BA.pass_words(BA.pass_pixels(src, W, H, c), W, c)
            BA.apply_pass(mem, W, c, w, 0xFF if k == 3 else s)   # last pass (B) with all strobes on
        n_strb = int(np.count_nonzero(mem.reshape(H, W) != ref))
        check(n_off > 0 and n_strb > 0, f"[8] faults not noticed ({n_off}, {n_strb} differing bytes)")
        print(f"[8] wrong Gr column offset -> {n_off} differing bytes; B pass with WSTRB FF -> {n_strb} (both noticed)")
    except Fail as e:
        print(f"TEST FAIL: {e}")
        return 1
    print(f"{time.perf_counter() - t0:.0f} s")
    print("TEST PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
