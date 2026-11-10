"""Step 2.2 checks for spec/interface.md.

    python -m model.test_interface
Prints one line per check, then exactly one final line: TEST PASS or TEST FAIL: <reason>.

1. every module section has purpose, ports table, handshake, latency, reset and stall behaviour
2. the bilinear width table equals the ranges of model/patrm.py interp_d10 (brute force over xf, yf, r)
3. build parameters equal model/memmodel.py and model/regs.py
4. counter definitions present; even/odd line_buf addressing always yields words w0 and w1
"""

import os
import re
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if __package__ in (None, ""):
    sys.path.insert(0, ROOT)

from model import memmodel as MM   # noqa: E402
from model import regs as R        # noqa: E402
from model.patrm import ONE, interp_d10   # noqa: E402

SPEC = os.path.join(ROOT, "spec", "interface.md")
MODULES = ["axil_regs", "ctrl_fsm", "block_planner", "coord_gen", "prefetch_ctrl", "line_buf", "pixel_fetch",
           "bilinear_interp", "out_fifo", "axi_rd_master", "axi_wr_master", "patrm_top"]
NEEDED = {"purpose": r"\*\*Purpose\.\*\*", "ports": r"\*\*Ports", "port table": r"\| port \| dir \| width \|",
          "handshake": r"Handshake", "latency": r"Latency", "reset": r"Reset", "stall": r"Stall"}


class Fail(Exception):
    pass


def check(cond, msg):
    if not cond:
        raise Fail(msg)


def sections(text):
    out = {}
    parts = re.split(r"^## ", text, flags=re.M)
    for p in parts[1:]:
        title = p.splitlines()[0]
        m = re.match(r"\d+\.\s+(\w+)", title)
        if m:
            out[m.group(1)] = p
    return out


def t1_modules(text):
    secs = sections(text)
    for m in MODULES:
        check(m in secs, f"no section for module {m}")
        for what, pat in NEEDED.items():
            check(re.search(pat, secs[m], flags=re.I), f"module {m}: no {what}")
    print(f"[1] {len(MODULES)} module sections, each with purpose, ports table (name, dir, width), handshake, "
          f"latency, reset, stall: {', '.join(MODULES)}")


def model_ranges():
    """Exact min/max of every interp_d10 intermediate. All maxima and minima are reached on lines xf = const or
    yf = const through the corners, so every xf (0..65535) is combined with edge and random yf values and
    vice versa; pixels at 0 and 255."""
    full = np.arange(65536, dtype=np.int64)
    edges = np.array([0, 1, 2, 255, 256, 32767, 32768, 65279, 65534, 65535], dtype=np.int64)
    ys = np.r_[edges, np.random.default_rng(22).integers(0, 65536, 120)]
    lo, hi = {}, {}

    def upd(k, a):
        a = np.asarray(a)
        lo[k] = min(lo.get(k, 1 << 62), int(a.min()))
        hi[k] = max(hi.get(k, -(1 << 62)), int(a.max()))
    for swap in (False, True):
        for y in ys:
            c = np.full(65536, y, dtype=np.int64)
            xf, yf = (c, full) if swap else (full, c)
            for r in (0, 255):
                w1, w2, w3, w4, D = interp_d10(xf, yf, r, r, r, r)
                vals = dict(xf=xf, yf=yf, nxf=ONE - xf, nyf=ONE - yf, p2=(ONE - xf) * yf, p3=xf * (ONE - yf),
                            p4=xf * yf, w2=w2, w3=w3, w4=w4, s234=w2 + w3 + w4, w1=w1,
                            r1=np.full(1, r), r2=np.full(1, r), r3=np.full(1, r), r4=np.full(1, r),
                            q1=w1 * r, q2=w2 * r, q3=w3 * r, q4=w4 * r, acc=(w1 + w2 + w3 + w4) * r, D=D)
                for k, v in vals.items():
                    upd(k, v)
    return lo, hi


def t2_widths(text):
    m = re.search(r"<!-- widths:begin -->(.*?)<!-- widths:end -->", text, flags=re.S)
    check(m, "width table markers not found")
    rows = [ln for ln in m.group(1).strip().splitlines() if ln.startswith("|") and not ln.startswith("|---")][1:]
    lo, hi = model_ranges()
    table = {}
    for ln in rows:
        c = [x.strip() for x in ln.strip("|").split("|")]
        table[c[0]] = (int(c[2]), int(c[3]), int(c[4]))
    check(set(table) == set(hi), f"table signals {sorted(table)} != model signals {sorted(hi)}")
    for k, (tmin, tmax, bits) in table.items():
        check(tmin == lo[k] and tmax == hi[k], f"{k}: table {tmin}..{tmax}, model {lo[k]}..{hi[k]}")
        check(bits == hi[k].bit_length(), f"{k}: table {bits} bits, model needs {hi[k].bit_length()}")
    nmul = sum(1 for ln in rows if "DSP48E1 #" in ln)
    check(nmul == 7, f"{nmul} multipliers in the table, D10 says 7")
    print(f"[2] bilinear width table: {len(table)} signals, min/max/bits equal the interp_d10 ranges "
          f"(brute force: every xf with 130 yf values and vice versa, "
          f"pixels 0 and 255); 7 DSP multipliers")
    print("    signal   min          max  bits")
    for k, (tmin, tmax, bits) in table.items():
        print(f"    {k:<6} {tmin:>5} {tmax:>12} {bits:>5}")


def t3_params(text):
    m = re.search(r"### Build parameters.*?\n\n(\|.*?)\n\n", text, flags=re.S)
    check(m, "build parameter table not found")
    p = {}
    for ln in m.group(1).splitlines()[2:]:
        c = [x.strip() for x in ln.strip("|").split("|")]
        p[c[0]] = c[1]
    want = {"VERSION": R.VERSION, "BLOCK_LEN_MAX": MM.BLOCK_LEN_MAX, "SPAN_MAX": MM.SPAN_MAX, "NSLOT": MM.NSLOT,
            "SIZE_BITS": R.SIZE_BITS, "BUILD_TYPE": R.BUILD_TYPE["GRAY"]}
    for k, v in want.items():
        check(k in p and int(p[k]) == v, f"parameter {k}: spec {p.get(k)} != model {v}")
    check(int(p["RD_OUTSTANDING"]) >= 2, "RD_OUTSTANDING must be >= 2")
    print(f"[3] build parameters match the model and regs.py: " + ", ".join(f"{k} {v}" for k, v in want.items())
          + f"; RD_OUTSTANDING {p['RD_OUTSTANDING']} >= 2")


def t4_counters_and_banks(text):
    secs = sections(text)
    c = next(v for k, v in secs.items() if k == "Counters")
    for name in ("CYCLES", "BYTES_RD", "BYTES_WR", "RD_STALL", "WR_STALL"):
        check(f"**{name}**" in c, f"no definition of {name}")
    words = MM.SPAN_MAX // MM.BEAT
    n = 0
    for slot in range(MM.NSLOT):
        for w0 in range(words):
            for w1 in {w0, min(w0 + 1, words - 1)}:
                even = slot * (words // 2) + ((w0 + 1) >> 1)
                odd = slot * (words // 2) + (w0 >> 1)
                got = {}
                for w in (w0, w1):
                    entry = even if w % 2 == 0 else odd
                    check(entry == slot * (words // 2) + (w >> 1), f"slot {slot} w0 {w0} w {w}: wrong entry")
                    got[w] = entry
                n += 1
    print(f"[4] counter definitions present (CYCLES, BYTES_RD, BYTES_WR, RD_STALL, WR_STALL); even/odd addressing "
          f"gives words w0 and w1 in one read per bank for all {n} (slot, w0, w1) cases")


def main():
    with open(SPEC, encoding="utf-8") as f:
        text = f.read()
    try:
        t1_modules(text)
        t2_widths(text)
        t3_params(text)
        t4_counters_and_banks(text)
    except Fail as e:
        print(f"TEST FAIL: {e}")
        return 1
    print("TEST PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
