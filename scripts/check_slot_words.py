"""Step 3.6b: proof that a line-buffer slot never needs more than 64 words (spec section 6.2, option A).

Option A stores word w of a source row at slot word (column >> 3) mod 64. That is alias-free only if every row
range ever held in a slot covers at most 64 consecutive 8-byte words, and every block that reuses a row (D14 P1)
needs a sub-range of what the slot holds. This script recomputes, from model/memmodel.py only, for every
schedule asked for in step 3.6b:
  cmd_words   words per fetched row command (= aligned span / 8 of the fetching block)
  (also memmodel.EXTREMES, the zooms where rule (c) cuts blocks at SPAN_MAX, so the bound is actually reached)
  held_words  words held by the slot a reused row is read from (the range of the block that fetched it)
  not_inside  reused rows whose needed range is NOT inside the held range (must be 0)
and fails (exit 1) if any maximum exceeds SLOT_WORDS = 64 or not_inside > 0.

    python scripts/check_slot_words.py            # all checks of step 3.6b
    python scripts/check_slot_words.py --quick    # without the 4096x4096 runs
"""
import argparse
import os
import sys
import time

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from model import memmodel as M          # noqa: E402

SLOT_WORDS = 64
SIM_SIZES = [(64, 64), (128, 96), (256, 192), (208, 120)]


def check(W, H, b, L, S):
    """Max command words, max held words of reused rows, count of reused rows not inside the held range."""
    ps = M.build_passes("gray", W, H, b)[0]
    blk = M.make_blocks(ps, L, S)
    s_col, e_col, nr = M._block_geometry(ps, blk)
    nfb = len(blk["ids"])
    if nfb == 0:
        return dict(fetch_blocks=0, cmds=0, reused=0, cmd_words=0, held_words=0, not_inside=0)
    reuse = [M._reuse_mask(blk, s_col, e_col, blk["rlo"] + k, "P1") & (k < nr) for k in range(2)]
    rlo, nr_l = blk["rlo"].tolist(), nr.tolist()
    s_l, e_l = s_col.tolist(), e_col.tolist()
    re0, re1 = reuse[0].tolist(), reuse[1].tolist()
    held_prev = {}
    cmds = reused = not_inside = 0
    cmd_words = held_words = 0
    for i in range(nfb):
        s, e = s_l[i], e_l[i]
        held = {}
        for k in range(nr_l[i]):
            row = rlo[i] + k
            if (re0[i] if k == 0 else re1[i]):
                hs, he = held_prev[row]
                reused += 1
                held_words = max(held_words, (he - hs) // 8)
                if not (hs <= s and e <= he):
                    not_inside += 1
                held[row] = (hs, he)
            else:
                cmds += 1
                cmd_words = max(cmd_words, (e - s) // 8)
                held[row] = (s, e)
        held_prev = held
    return dict(fetch_blocks=nfb, cmds=cmds, reused=reused, cmd_words=cmd_words, held_words=held_words,
                not_inside=not_inside)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--quick", action="store_true", help="skip the 4096x4096 runs")
    args = ap.parse_args(argv)
    tfs = {t["name"]: t for t in M.load_transforms()}
    runs = []
    for (W, H) in SIM_SIZES:                                   # every transform x both (L, S) configs
        for name, tf in tfs.items():
            for L, S in M.SCHED_CONFIGS:
                runs.append(("std", name, W, H, L, S))
    for (W, H) in SIM_SIZES:                                   # BLOCK_LEN 1..64 on rot15 / rot37 / rot90
        for name in ("rot15", "rot37", "rot90"):
            for L in range(1, 65):
                for S in sorted({s for _, s in M.SCHED_CONFIGS}):
                    runs.append(("len", name, W, H, L, S))
    for (W, H) in SIM_SIZES + [(640, 480), (2048, 64)]:                    # extreme zooms (memmodel.EXTREMES): rule (c) fires
        for name, _ in M.EXTREMES:
            for L, S in M.SCHED_CONFIGS:
                runs.append(("ext", name, W, H, L, S))
    if not args.quick:
        for name in ("rot37", "scale0p8"):                     # largest board size
            for L, S in M.SCHED_CONFIGS:
                runs.append(("big", name, 4096, 4096, L, S))

    worst = dict(cmd_words=0, held_words=0, not_inside=0)
    where = {}
    groups = {}
    t0 = time.perf_counter()
    for grp, name, W, H, L, S in runs:
        t1 = time.perf_counter()
        b = M._b_for(tfs[name], W, H) if name in tfs else M.P.make_b(W, H, **dict(M.EXTREMES)[name])
        r = check(W, H, b, L, S)
        g = groups.setdefault(grp, dict(runs=0, cmds=0, reused=0, cmd_words=0, held_words=0, not_inside=0))
        g["runs"] += 1
        for k in ("cmds", "reused", "not_inside"):
            g[k] += r[k]
        for k in ("cmd_words", "held_words"):
            g[k] = max(g[k], r[k])
            if r[k] > worst[k]:
                worst[k], where[k] = r[k], f"{name} {W}x{H} L{L} S{S}"
        worst["not_inside"] += r["not_inside"]
        if grp == "big":
            print(f"  {name} {W}x{H} L{L} S{S}: {r['fetch_blocks']} fetching blocks, {r['cmds']} commands, "
                  f"{r['reused']} reused rows, max cmd words {r['cmd_words']}, max held words {r['held_words']}, "
                  f"not inside {r['not_inside']} ({time.perf_counter() - t1:.1f} s)", flush=True)
    labels = dict(std="sim sizes x all transforms x (L,S) in {(64,512),(32,32)}",
                  len="sim sizes x rot15/rot37/rot90 x BLOCK_LEN 1..64 x SPAN_MAX {32,512}",
                  ext="sim sizes + 640x480 + 2048x64 x memmodel.EXTREMES (scale0p1, scale0p25, cols0p1, rot30_scale0p2)",
                  big="4096x4096 x rot37/scale0p8 x (L,S) in {(64,512),(32,32)}")
    print(f"{'group':<6} {'runs':>5} {'commands':>11} {'reused rows':>12} {'max cmd w':>10} {'max held w':>11} "
          f"{'not inside':>11}  meaning")
    for grp, g in groups.items():
        print(f"{grp:<6} {g['runs']:>5} {g['cmds']:>11} {g['reused']:>12} {g['cmd_words']:>10} "
              f"{g['held_words']:>11} {g['not_inside']:>11}  {labels[grp]}")
    print(f"max cmd words {worst['cmd_words']} ({where.get('cmd_words')}); max held words {worst['held_words']} "
          f"({where.get('held_words')}); reused rows not inside held range: {worst['not_inside']}; "
          f"{time.perf_counter() - t0:.0f} s")
    ok = worst["cmd_words"] <= SLOT_WORDS and worst["held_words"] <= SLOT_WORDS and worst["not_inside"] == 0
    print("CHECK PASS" if ok else "CHECK FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
