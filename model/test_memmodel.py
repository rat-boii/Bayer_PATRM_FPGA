"""Step 1.4 and 2.2 checks for model/memmodel.py.

    python -m model.test_memmodel
Prints the numbers for each check, then exactly one final line: TEST PASS or TEST FAIL: <reason>.
"""

import csv
import os
import sys
import unittest

import numpy as np

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from model import bayer as BY  # noqa: E402
from model import memmodel as MM  # noqa: E402
from model import patrm as P  # noqa: E402
from model.gen_transforms import load as load_transforms  # noqa: E402

REPORT = {}
TF = {t["name"]: t for t in load_transforms()}


def report(n, line):
    REPORT.setdefault(n, []).append(line)


def neighbours(b, Wp, Hp):
    """Independent recomputation of r1..r4 locations (plane rows/cols) of every valid pixel (D1 clamp)."""
    X, Y = P.coords(b, Wp, Hp)
    X = X.astype(np.int64)
    Y = Y.astype(np.int64)
    valid = (X >= 0) & (X <= (Hp - 1) * 65536) & (Y >= 0) & (Y <= (Wp - 1) * 65536)
    x0, y0 = X >> 16, Y >> 16
    x1, y1 = np.minimum(x0 + 1, Hp - 1), np.minimum(y0 + 1, Wp - 1)
    return valid, [(x0, y0), (x0, y1), (x1, y0), (x1, y1)]


def build_buffers(detail):
    """Replay a fetch list: buffer content per block id = {mem_row: (s, e)}.
    Returns (buffers, problems). A reused row must be held by the previous block with a covering range;
    fetched rows must be covered exactly by their bursts."""
    bufs, prev, problems, all_bursts = {}, {}, 0, []
    for blk in detail:
        cur = {}
        for (r, s, e, fetched, bursts) in blk["rows"]:
            if fetched:
                a = s
                for (addr, beats) in bursts:
                    if addr != a:
                        problems += 1
                    a = addr + beats * MM.BEAT
                    all_bursts.append((addr, beats))
                if a != e:
                    problems += 1
                cur[r] = (s, e)
            elif r in prev and prev[r][0] <= s and prev[r][1] >= e:
                cur[r] = prev[r]
            else:
                problems += 1
        bufs[blk["id"]] = cur
        prev = cur
    return bufs, problems, all_bursts


ALL_BURSTS = []


class Step14(unittest.TestCase):

    def test_1_coverage(self):
        W, H = 128, 96
        total_checked = 0
        lines = []
        for name in ("rot37", "scale0p8", "combined"):
            b = tuple(TF[name]["b"][f"{W}x{H}"])
            for mode in ("gray", "A", "B"):
                passes = MM.build_passes(mode, W, H, b)
                for L in (16, 64):
                    for pol in ("P0", "P1"):
                        misses = probs = checked = 0
                        for ps in passes:
                            blk = MM.make_blocks(ps, L)
                            det = MM.pass_detail(ps, blk, W, pol)
                            bufs, pr, bl = build_buffers(det)
                            probs += pr
                            ALL_BURSTS.extend(bl)
                            bid = blk["bid"]
                            if mode == "gray":
                                lanes = [((1, 0), (1, 0), neighbours(b, W, H))]
                            else:
                                bp = BY.plane_b(b)
                                names = [ps.name[2:]] if mode == "A" else list(BY.PLANES)
                                lanes = [((2, BY.OFFSETS[p][0]), (2, BY.OFFSETS[p][1]),
                                          neighbours(bp[p], W // 2, H // 2)) for p in names]
                            for (rm, ra), (cm, ca), (valid, nbs) in lanes:
                                us, vs = np.nonzero(valid)
                                for (xr, yc) in nbs:
                                    rows = rm * xr[us, vs] + ra
                                    cols = cm * yc[us, vs] + ca
                                    addr = MM.SRC_ADDR + rows * W + cols
                                    for k in range(len(us)):
                                        buf = bufs.get(int(bid[us[k], vs[k]]), {})
                                        rng = buf.get(int(rows[k]))
                                        checked += 1
                                        if rng is None or not (rng[0] <= addr[k] < rng[1]):
                                            misses += 1
                        self.assertEqual(probs, 0, f"{name} {mode} L={L} {pol}: fetch-list problems")
                        self.assertEqual(misses, 0, f"{name} {mode} L={L} {pol}: {misses} misses")
                        total_checked += checked
                lines.append(f"{name}/{mode}")
        report(1, f"{total_checked} neighbour-byte reads (r1..r4 of every valid pixel) checked against the "
                  f"block's fetched/held bytes for rot37, scale0p8, combined at 128x96, gray + Bayer A + B, "
                  f"Lmax 16 and 64, P0 and P1: 0 misses; every reused row was held by the previous block")

    def test_2_axi_rules(self):
        rng = np.random.default_rng(14)
        fuzz = []
        for _ in range(20000):
            s = int(rng.integers(0, 1 << 20)) * 8
            e = s + int(rng.integers(1, 1200)) * 8
            fuzz.append((s, e))
        fuzz += [(4096 - 8, 4096 + 8), (4096 - 128, 4096 + 128), (0, 4096 * 3), (8, 4096 * 2 - 8)]
        n_count_bad = 0
        bursts = list(ALL_BURSTS)
        for s, e in fuzz:
            bl = MM.split_bursts(s, e)
            bursts += bl
            if len(bl) != int(MM.burst_count(np.array([s]), np.array([e]))[0]):
                n_count_bad += 1
        # write side, explicit vs counted, at a size whose rows cross 4 KB
        W, H = 2448, 2095
        expl = sum(len(MM.split_bursts(MM.DST_ADDR + u * W, MM.DST_ADDR + (u + 1) * W)) for u in range(H))
        bursts += [x for u in range(0, H, 97) for x in MM.split_bursts(MM.DST_ADDR + u * W, MM.DST_ADDR + (u + 1) * W)]
        self.assertEqual(MM.write_stats("gray", W, H)["write_bursts"], expl)
        bad_len = sum(1 for a, n in bursts if not 1 <= n <= MM.MAX_BEATS)
        bad_align = sum(1 for a, n in bursts if a % MM.BEAT)
        bad_4k = sum(1 for a, n in bursts if a // MM.PAGE != (a + n * MM.BEAT - 1) // MM.PAGE)
        self.assertEqual(bad_len + bad_align + bad_4k + n_count_bad, 0)
        report(2, f"{len(bursts)} bursts checked (all from test 1 + 20004 fuzzed ranges + write rows): "
                  f"{bad_len} longer than 16 beats, {bad_align} not 8-byte aligned, {bad_4k} crossing 4 KB; "
                  f"burst_count == len(split_bursts) on all fuzzed ranges ({n_count_bad} differ); "
                  f"write bursts at 2448x2095 counted = explicit = {expl}")

    def test_3_identity_scale(self):
        W, H = 128, 96
        b = tuple(TF["identity"]["b"][f"{W}x{H}"])
        r0 = MM.frame_stats("gray", W, H, b, None, "P0")
        r1 = MM.frame_stats("gray", W, H, b, None, "P1")
        self.assertAlmostEqual(r0["read_amp"], (2 * H - 1) / H, places=9)
        self.assertAlmostEqual(r1["read_amp"], 1.0, places=9)   # rows 0,1 once, then one new row per output row, last row: none
        info = []
        for L in (16, 32, 64):
            a = MM.frame_stats("gray", W, H, b, L, "P0")
            c = MM.frame_stats("gray", W, H, b, L, "P1")
            info.append(f"Lmax {L}: P0 {a['read_amp']:.3f}, P1 {c['read_amp']:.3f}")
        report(3, f"identity {W}x{H}, one block per row (Lmax >= W): amp P0 = {r0['read_amp']:.4f} "
                  f"(= (2H-1)/H, the last row has no row below), P1 = {r1['read_amp']:.4f} (exactly H rows read: rows 0 and 1 "
                  f"for u = 0, one new row per later output row, nothing new for the last row)")
        report(3, "identity with capped blocks (info): " + "; ".join(info)
               + "  -> the +1 column and 8-byte alignment cost a lot for short blocks, and P1 cannot reuse "
                 "anything because the previous block holds other columns")
        for name in ("scale0p8", "scale1p25"):
            bs = tuple(TF[name]["b"][f"{W}x{H}"])
            self.assertEqual(bs[1], 0)
            r = MM.frame_stats("gray", W, H, bs, None, "P0")
            self.assertEqual(r["blocks"], H)
            rL = MM.frame_stats("gray", W, H, bs, 32, "P0")
            self.assertEqual(rL["blocks"], H * (W // 32))
            report(3, f"{name} (b12 = 0): {r['blocks']} blocks = H with Lmax >= W; {rL['blocks']} = H x W/32 "
                      f"with Lmax 32")

    def test_4_hand_example(self):
        W = H = 16
        u, L = 8, 16
        b = P.make_b(W, H, rot_deg=37.0)
        b11, b12, b13, b21, b22, b23 = b

        def s32(n):
            n &= 0xFFFFFFFF
            return n - (1 << 32) if n & 0x80000000 else n
        # brute force: per pixel
        px = []
        for v in range(W):
            X, Y = s32(b11 * u + b12 * v + b13), s32(b21 * u + b22 * v + b23)
            ok = 0 <= X <= (H - 1) * 65536 and 0 <= Y <= (W - 1) * 65536
            px.append((v, ok, X >> 16, Y >> 16, X, Y))
        valid_x0 = [(v, x0) for v, ok, x0, _, _, _ in px if ok]
        keys = []
        for v in range(W):
            before = [x0 for vv, x0 in valid_x0 if vv <= v]
            after = [x0 for vv, x0 in valid_x0 if vv > v]
            keys.append(before[-1] if before else (after[0] if after else None))
        blocks, cur = [], None
        for v in range(W):
            if cur is None or len(cur) == L or keys[v] != keys[v - 1]:
                cur = []
                blocks.append(cur)
            cur.append(v)
        brute = []
        for bl in blocks:
            vals = [p for p in px if p[0] in bl and p[1]]
            if not vals:
                brute.append((bl[0], bl[-1], []))
                continue
            x0 = vals[0][2]
            rows = sorted({x0, min(x0 + 1, H - 1)})
            c0 = min(p[3] for p in vals)
            c1 = max(min(p[3] + 1, W - 1) for p in vals)
            s_col, e_col = (c0 // 8) * 8, -(-(c1 + 1) // 8) * 8
            fetch = []
            for r in rows:
                s, e = MM.SRC_ADDR + r * W + s_col, MM.SRC_ADDR + r * W + e_col
                bursts, a, start, n = [], s, s, 0          # byte-walk splitter
                while a < e:
                    if n == 16 or (a % 4096 == 0 and n):
                        bursts.append((start, n))
                        start, n = a, 0
                    n += 1
                    a += 8
                bursts.append((start, n))
                fetch.append((r, s, e, bursts))
            brute.append((bl[0], bl[-1], fetch))
        # model
        ps = MM.build_passes("gray", W, H, b)[0]
        blk = MM.make_blocks(ps, L)
        det = {d["id"]: d for d in MM.pass_detail(ps, blk, W, "P0")}
        bid_row = blk["bid"][u]
        model = []
        for i in sorted(set(bid_row.tolist())):
            vs = np.flatnonzero(bid_row == i)
            rows = [(r, s, e, bl) for (r, s, e, f, bl) in det[i]["rows"]] if i in det else []
            model.append((int(vs[0]), int(vs[-1]), rows))
        self.assertEqual(model, brute)
        report(4, f"rot37 at 16x16, b = {b}, output row u = {u}, Lmax {L}, P0 (addresses as SRC_ADDR + offset):")
        for v0, v1, rows in model:
            pix = " ".join(f"v{p[0]}:(x0={p[2]},y0={p[3]})" if p[1] else f"v{p[0]}:invalid"
                           for p in px if v0 <= p[0] <= v1)
            fr = "; ".join(f"row {r}: bytes +{s - MM.SRC_ADDR}..+{e - MM.SRC_ADDR - 1}, bursts "
                           + ",".join(f"(+{a - MM.SRC_ADDR},{n} beats)" for a, n in bl) for r, s, e, bl in rows)
            report(4, f"  block v{v0}-v{v1}: [{pix}] -> {fr if fr else 'no fetch (all invalid)'}")
        report(4, f"{len(model)} blocks; identical to the brute-force recomputation (per-pixel loop + byte-walk "
                  f"burst splitter)")

    def test_5_bayer_a_vs_b(self):
        W, H = 640, 480
        ratios = []
        for name, tf in TF.items():
            b = tuple(tf["b"][f"{W}x{H}"])
            for L in (16, 32, 64):
                for pol in ("P0", "P1"):
                    a = MM.frame_stats("A", W, H, b, L, pol)
                    bb = MM.frame_stats("B", W, H, b, L, pol)
                    self.assertLessEqual(bb["bytes_read"], a["bytes_read"], f"{name} L={L} {pol}")
                    ratios.append((a["bytes_read"] / bb["bytes_read"], name, L, pol))
        report(5, f"{W}x{H}, {len(TF)} transforms x Lmax 16/32/64 x P0/P1: B <= A in all {len(ratios)} cases; "
                  f"A/B bytes read min {min(ratios)[0]:.2f} ({min(ratios)[1]} L{min(ratios)[2]} {min(ratios)[3]}), "
                  f"max {max(ratios)[0]:.2f} ({max(ratios)[1]} L{max(ratios)[2]} {max(ratios)[3]})")
        path = MM.DEFAULT_OUT + ".csv"
        if os.path.exists(path):
            with open(path) as f:
                rows = [r for r in csv.DictReader(f) if r["size"] == "2448x2048"]
            idx = {(r["mode"], r["transform"], r["lmax"], r["policy"]): int(r["bytes_read"]) for r in rows}
            rr = []
            for (m, t, L, pol), v in idx.items():
                if m == "A":
                    bv = idx[("B", t, L, pol)]
                    self.assertLessEqual(bv, v, f"2448x2048 {t} L={L} {pol}")
                    rr.append(v / bv)
            report(5, f"2448x2048 (report CSV): B <= A in all {len(rr)} cases; A/B min {min(rr):.2f}, "
                      f"max {max(rr):.2f}, median {float(np.median(rr)):.2f}")

    def test_6_determinism(self):
        cfg = [("gray", 640, 480), ("A", 256, 192), ("B", 256, 192)]
        tfs = [TF["rot37"], TF["combined"], TF["identity"]]
        a = MM.rows_to_csv(MM.run_configs(cfg, tfs), MM.COLUMNS)
        b = MM.rows_to_csv(MM.run_configs(cfg, tfs), MM.COLUMNS)
        self.assertEqual(a, b)
        report(6, f"two runs of a reduced configuration give identical CSV text ({len(a.splitlines())} lines)")


def ref_plan_row(anyv, key, mc0, mc1, L, span_max):
    """Independent streaming planner for one output row (D16 as written in the spec), plain Python.
    Returns [(v_start, n, reason)] with reason 0 row, 1 x0, 2 len, 3 span."""
    def span(lo, hi):
        return -(-(hi + 1) // 8) * 8 - (lo // 8) * 8
    out, cur, last_key = [], None, None
    for v in range(len(anyv)):
        k = int(key[v]) if anyv[v] else None
        if cur is not None:
            reason = None
            if k is not None and last_key is not None and k != last_key:
                reason = 1
            elif cur[1] == L:
                reason = 2
            elif k is not None and span_max is not None and cur[2] is not None and \
                    span(min(cur[2], int(mc0[v])), max(cur[3], int(mc1[v]))) > span_max:
                reason = 3
            if reason is not None:
                out.append((cur[0], cur[1], reason))
                cur = None
        if cur is None:
            cur = [v, 0, None, None]
        cur[1] += 1
        if k is not None:
            cur[2] = int(mc0[v]) if cur[2] is None else min(cur[2], int(mc0[v]))
            cur[3] = int(mc1[v]) if cur[3] is None else max(cur[3], int(mc1[v]))
            last_key = k
    out.append((cur[0], cur[1], 0))
    return out


def model_rows(blk):
    """make_blocks result as {u: [(v_start, n, reason)]}."""
    Wo = blk["Wo"]
    rows = {}
    for st, n, r in zip(blk["start"], blk["n"], blk["reason"]):
        rows.setdefault(int(st) // Wo, []).append((int(st) % Wo, int(n), int(r)))
    return rows


class Step22(unittest.TestCase):

    def test_7_reference_planner(self):
        """make_blocks (vectorised + rule (c) re-plan) == independent streaming planner, row by row."""
        cases = rows = 0
        fired = {k: 0 for k in MM.REASONS.values()}
        W, H = 128, 96
        tfs = [(n, tuple(t["b"][f"{W}x{H}"])) for n, t in TF.items()]
        tfs.append(("scale0p1", P.make_b(W, H, sx=0.1, sy=0.1)))
        for name, b in tfs:
            for mode in ("gray", "A", "B"):
                for L, S in ((64, 512), (32, 32), (16, 16), (64, None)):
                    for ps in MM.build_passes(mode, W, H, b):
                        blk = MM.make_blocks(ps, L, S)
                        nd = MM.pixel_needs(ps)
                        got = model_rows(blk)
                        for u in range(nd["anyv"].shape[0]):
                            ref = ref_plan_row(nd["anyv"][u], nd["key"][u], nd["mc0"][u], nd["mc1"][u], L, S)
                            self.assertEqual(got[u], ref, f"{name} {mode} L{L} S{S} {ps.name} row {u}")
                            rows += 1
                            for _, _, r in ref:
                                fired[MM.REASONS[r]] += 1
                    cases += 1
        # large image, rule (c) firing: zoom-out at the paper size, rows around the centre
        W, H = 2448, 2095
        for fw in (dict(sx=0.1, sy=0.1), dict(sy=0.1)):
            b = P.make_b(W, H, **fw)
            ps = MM.build_passes("gray", W, H, b)[0]
            blk = MM.make_blocks(ps, 64)
            nd = MM.pixel_needs(ps)
            got = model_rows(blk)
            for u in range(H // 2 - 40, H // 2 + 40):
                ref = ref_plan_row(nd["anyv"][u], nd["key"][u], nd["mc0"][u], nd["mc1"][u], 64, MM.SPAN_MAX)
                self.assertEqual(got[u], ref, f"2448x2095 {fw} row {u}")
                rows += 1
                for _, _, r in ref:
                    fired[MM.REASONS[r]] += 1
        self.assertTrue(all(v > 0 for v in fired.values()), f"every end reason must occur: {fired}")
        report(7, f"block list == independent streaming planner (D16 a/b/c as written) on {rows} output rows "
                  f"({cases} configs at 128x96: 10 transforms incl. scale 0.1 x gray/A/B x (L,S) = (64,512), "
                  f"(32,32), (16,16), (64,none); plus 160 rows of 2448x2095 zoom-out with rule (c)); "
                  f"end reasons seen: {fired}")

    def test_8_span_max(self):
        """No gray / Bayer A block needs more than 2 x SPAN_MAX bytes, for every transform incl. scale 0.1."""
        lines = []
        worst = 0
        for (mode, W, H) in (("gray", 2448, 2095), ("A", 2448, 2048)):
            tfs = [(n, MM._b_for(t, W, H)) for n, t in TF.items()]
            tfs += [(n, P.make_b(W, H, **fw)) for n, fw in MM.EXTREMES]
            for name, b in tfs:
                for L in (64, 4096):
                    cnt, mspan, mfp = MM.block_reasons(mode, W, H, b, L)
                    self.assertLessEqual(mspan, MM.SPAN_MAX, f"{mode} {name} L{L}")
                    self.assertLessEqual(mfp, 2 * MM.SPAN_MAX, f"{mode} {name} L{L}")
                    worst = max(worst, mfp)
                    if name in ("scale0p1", "cols0p1") and L == 64:
                        lines.append(f"{mode} {name} L64: max span {mspan} B, max footprint {mfp} B, "
                                     f"{cnt['span']} blocks ended by rule (c)")
                    if name == "scale0p1" and L == 4096:
                        lines.append(f"{mode} {name} L4096 (no length cap): max footprint {mfp} B, "
                                     f"{cnt['span']} blocks ended by rule (c)")
        # without rule (c) the same zoom-out would overflow the buffer
        b = P.make_b(2448, 2095, sx=0.1, sy=0.1)
        ps = MM.build_passes("gray", 2448, 2095, b)[0]
        s_col, e_col, nr = MM._block_geometry(ps, MM.make_blocks(ps, 64, None))
        nofc = int((nr * (e_col - s_col)).max())
        self.assertGreater(nofc, 2 * MM.SPAN_MAX)
        report(8, f"gray 2448x2095 and Bayer A 2448x2048, {len(TF)} test transforms + {len(MM.EXTREMES)} extremes "
                  f"(scale 0.1, 0.25, columns x0.1, rot30 + scale 0.2), BLOCK_LEN 64 and 4096: largest footprint "
                  f"{worst} B <= 2 x SPAN_MAX = {2 * MM.SPAN_MAX} B in every block")
        for ln in lines:
            report(8, "  " + ln)
        report(8, f"  control: scale 0.1 without rule (c) would need {nofc} B for one block")
        report(8, "  Gray/A slot bound checked here. For B, test_bayer_b_design checks the bounded windows "
                  "and the per-tile fallback for oversized rectangles.")

    def test_9_schedule(self):
        """schedule(): totals match pass_reads, every neighbour byte is in the block's slots, ring rule holds."""
        W, H = 128, 96
        tfs = [(n, tuple(t["b"][f"{W}x{H}"])) for n, t in TF.items()]
        tfs.append(("scale0p1", P.make_b(W, H, sx=0.1, sy=0.1)))
        checked = nsched = 0
        min_gap = None
        for name, b in tfs:
            for mode in ("gray", "A"):
                for L, S in MM.SCHED_CONFIGS:
                    for ps in MM.build_passes(mode, W, H, b):
                        blk = MM.make_blocks(ps, L, S)
                        bl, br = MM.schedule(ps, blk, W)
                        st = MM.pass_reads(ps, blk, W, "P1")
                        self.assertEqual((len(br), sum(x[5] for x in br)), (st["bursts"], st["beats"]))
                        self.assertEqual((bl, br), MM.schedule(ps, blk, W))
                        by_block = {}
                        for x in br:
                            by_block.setdefault((x[0], x[1]), []).append(x)
                        slot, users, held = {}, {}, {}
                        for rec in bl:
                            if rec["nrows"] == 0:
                                continue
                            rws = [(rec["row_top"], rec["slot_top"], rec["fetch_top"])]
                            if rec["nrows"] == 2:
                                rws.append((rec["row_bot"], rec["slot_bot"], rec["fetch_bot"]))
                            for r, sl, f in rws:
                                s0 = MM.SRC_ADDR + r * W + rec["s_col"]
                                if f:
                                    got = by_block[(rec["id"], r)]
                                    self.assertEqual(sum(x[5] for x in got) * 8, rec["span"])
                                    self.assertTrue(all(x[2] == sl for x in got))
                                    if sl in users:
                                        gap = rec["id"] - users[sl]
                                        min_gap = gap if min_gap is None else min(min_gap, gap)
                                    slot[sl] = (r, s0, s0 + rec["span"])
                                else:
                                    self.assertIn(sl, slot)
                                    hr, hs, he = slot[sl]
                                    self.assertEqual(hr, r)
                                    self.assertTrue(hs <= s0 and s0 + rec["span"] <= he)
                                users[sl] = rec["id"]
                            held[rec["id"]] = {sl: slot[sl] for _, sl, _ in rws}
                        bid = blk["bid"]
                        if mode == "gray":
                            lanes = [((1, 0), (1, 0), neighbours(b, W, H))]
                        else:
                            pl = ps.name[2:]
                            lanes = [((2, BY.OFFSETS[pl][0]), (2, BY.OFFSETS[pl][1]),
                                      neighbours(BY.plane_b(b)[pl], W // 2, H // 2))]
                        for (rm, ra), (cm, ca), (valid, nbs) in lanes:
                            us, vs = np.nonzero(valid)
                            for k, (xr, yc) in enumerate(nbs):
                                rows_ = rm * xr[us, vs] + ra
                                addr = MM.SRC_ADDR + rows_ * W + cm * yc[us, vs] + ca
                                for t in range(len(us)):
                                    j = int(bid[us[t], vs[t]])
                                    rec = bl[j]
                                    sl = rec["slot_top"] if k < 2 else rec["slot_bot"]
                                    hr, hs, he = held[j][sl]
                                    self.assertEqual(hr, int(rows_[t]))
                                    self.assertTrue(hs <= addr[t] < he)
                                    checked += 1
                        nsched += 1
        report(9, f"{nsched} schedules (128x96, 10 transforms, gray + 4 Bayer A passes, (L,S) = "
                  f"{list(MM.SCHED_CONFIGS)}): burst/beat totals = pass_reads; deterministic; {checked} neighbour "
                  f"bytes read from the block's slots: 0 misses; reused rows found in their slot with a covering "
                  f"range; a slot is refilled at the earliest {min_gap} blocks after its previous user "
                  f"(NSLOT {MM.NSLOT})")

def main():
    suite = unittest.TestSuite([unittest.defaultTestLoader.loadTestsFromTestCase(c) for c in (Step14, Step22)])
    res = unittest.TextTestRunner(stream=sys.stderr, verbosity=2).run(suite)
    for n in sorted(REPORT):
        for line in REPORT[n]:
            print(f"[{n}] {line}")
    sys.stdout.flush()
    if res.wasSuccessful():
        print("TEST PASS")
        return 0
    first = (res.failures + res.errors)[0]
    print(f"TEST FAIL: {first[0].id().split('.')[-1]}: {first[1].strip().splitlines()[-1]}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
