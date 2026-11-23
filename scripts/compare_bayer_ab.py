"""Option A vs Option B (and gray) on the same jobs in simulation (step 6.3 preparation, added 2026-11-23).

    python scripts/compare_bayer_ab.py                  256x192, the standard transforms, default memory timing
    python scripts/compare_bayer_ab.py --size 128x96 --transforms identity,rot37

Makes one case per (transform, mode) in data/vectors_ab/patrm_top/cases_bayer_b.txt with the generators of steps 3.7,
5.2 and 6.2 (same source mosaic, same integer b, same BLOCK_LEN 64, default AXI memory model timing: latency 20,
no back-pressure), runs tb/tb_patrm_top.v as the combined build (TB_BAYER_B: MODES 7, BUILD_TYPE 2, so gray, A and
B jobs run on one RTL), and tabulates CYCLES, pixels per clock, BYTES_RD and RD_STALL per mode. Every frame is still
checked bit-exact by the testbench (TEST PASS required). The gray row uses the gray image of the same size, for scale.
Result: results/sim/bayer_ab_<W>x<H>.txt. These are simulation cycles at an idealised memory, not board numbers.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "scripts"))
import gen_patrm_top_vectors as GT              # noqa: E402

VEC_DIR = REPO / "data" / "vectors_ab"
GT.OUT_DIR = VEC_DIR / "patrm_top"              # redirect before the B generator copies the name
import gen_bayer_b_vectors as GB                # noqa: E402
GB.OUT_DIR = GT.OUT_DIR

DEFAULT_TFS = "identity,mirror_cols,rot5,rot15,rot37,rot90,scale0p8,scale1p25,combined"
LINE = re.compile(r"^\s+\S\s+(\S+)\s+(\S+)\s+(\d+)x(\d+)\s+L\d+.*?CYCLES (\d+), ([\d.]+) px/clk, BYTES_RD (\d+), "
                  r"RD_STALL (\d+), WR_STALL (\d+)")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--size", default="256x192")
    ap.add_argument("--transforms", default=DEFAULT_TFS)
    a = ap.parse_args(argv)
    W, H = (int(x) for x in a.size.lower().split("x"))
    tfs = a.transforms.split(",")
    GT.OUT_DIR.mkdir(parents=True, exist_ok=True)
    cmd = [sys.executable, str(REPO / "scripts" / "sim.py"), "--top", "tb_patrm_top", "-f", "tb/patrm_top.f",
           "--incdir", "rtl", "--define", "TB_BAYER_B", "--plusarg", "VEC_DIR=data/vectors_ab",
           "--plusarg", "SINGLE_CASE=1"]
    # one simulation per transform: tb/axi_mem.v logs at most LOG_MAX = 65536 bursts per run, and the B trace check
    # compares every logged burst (a longer run reads X from beyond the log)
    rows, fails = [], []
    for tf in tfs:
        g = GB.BayerCases()
        g.add("a", tf, W, H, mode=1)             # Option A: four plane passes (also the B reference)
        g.add_b("a", tf, W, H)                   # Option B: four lanes, one pass
        g.add("a", tf, W, H)                     # gray
        g.cases = [g.cases[1], g.cases[0], g.cases[2]]   # B first: its burst trace must lie inside the log
        (GT.OUT_DIR / "cases_bayer_b.txt").write_text("# " + GT.CASE_HEADER + "\n" + "\n".join(g.cases) + "\n")
        r = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
        text = r.stdout + r.stderr
        got = [m.groups() for m in map(LINE.match, text.splitlines()) if m]
        ok = "TEST PASS" in text and "SIM RESULT: PASS" in text and len(got) == 3
        print(f"compare_bayer_ab: {tf}: {'PASS' if ok else 'FAIL'}", flush=True)
        if not ok:
            fails.append(tf)
            got = (got + [None] * 3)[:3]
        rows += got
    passed = not fails
    table = {}                                   # (transform, mode) from the testbench's own mode label
    for row in rows:
        if row:
            table[(row[1], row[0])] = row
    out = [f"Option A vs Option B, simulation, {W}x{H}, BLOCK_LEN 64, memory latency 20, no back-pressure "
           f"(scripts/compare_bayer_ab.py)", "",
           f"{'transform':<12}{'gray cyc':>10}{'A cyc':>10}{'B cyc':>10}{'B/A':>7}{'A px/clk':>10}{'B px/clk':>10}"
           f"{'A BYTES_RD':>12}{'B BYTES_RD':>12}{'A RD_STALL':>12}{'B RD_STALL':>12}"]
    for tf in tfs:
        gr, ra, rb = (table.get((tf, m)) for m in ("gray", "A", "B"))
        if not (gr and ra and rb):
            out.append(f"{tf:<12} (missing frame lines)")
            continue
        ca, cb = int(ra[4]), int(rb[4])
        out.append(f"{tf:<12}{int(gr[4]):>10}{ca:>10}{cb:>10}{cb / ca:>7.2f}{float(ra[5]):>10.3f}{float(rb[5]):>10.3f}"
                   f"{int(ra[6]):>12}{int(rb[6]):>12}{int(ra[7]):>12}{int(rb[7]):>12}")
    out.append("")
    out.append("B/A < 1: Option B faster. " + ("TEST PASS (every frame bit-exact)" if passed else
                                                f"TEST FAIL in {fails}"))
    report = "\n".join(out)
    print(report)
    dst = REPO / "results" / "sim" / f"bayer_ab_{W}x{H}.txt"
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(report + "\n", encoding="utf-8")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
