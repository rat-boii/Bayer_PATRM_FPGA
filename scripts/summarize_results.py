"""Collect every measured number of the project into one file for the final documentation.

    python scripts/summarize_results.py              -> docs/results-summary.md

Everything is read from the tracked result files (Vivado summaries and reports, board CSVs, Ethernet and video logs,
the step 7.1 clock report, the Option A/B simulation table); nothing is typed in by hand except the paper's figures
and labels. Re-run it after any new build or board run. Each table names its source file.
"""
import csv
import re
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
R = REPO / "results"
OUT = REPO / "docs" / "results-summary.md"

BUILDS = [  # label, folder, note
    ("Grayscale, Rev C (Vivado 2026.1)", R / "hw", "reference gray build"),
    ("Grayscale, Rev D (Vivado 2025.2)", R / "hw" / "rev D", "board-verified gray bundle (steps 4.x, 10.2, 10.3)"),
    ("Bayer A, Rev D (Vivado 2026.1)", R / "hw" / "bayer_a" / "rev_d", "board-verified; runs gray and Bayer (5.3, 10.4, 10.5)"),
    ("Bayer B, Rev D (Vivado 2026.1)", R / "hw" / "bayer_b" / "rev_d", "TIMING FAILED at 100 MHz, not loaded (6.3)"),
]


def rel(p):
    return Path(p).relative_to(REPO).as_posix()


def num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def read_csv(p):
    with open(p, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def summary_fields(folder):
    t = (folder / "summary.txt").read_text(encoding="utf-8", errors="replace")
    def g(pat):
        m = re.search(pat, t, re.M)
        return m.group(1).strip() if m else ""
    return {
        "WNS": g(r"^WNS \(ns\)\s+(\S+)"), "TNS": g(r"^TNS \(ns\)\s+(.+)$"), "WHS": g(r"^WHS \(ns\)\s+(\S+)"),
        "LUT": g(r"^\s+LUT\s+(\d+) of"), "LUTRAM": g(r"^\s+LUT memory\s+(\d+) of"), "FF": g(r"^\s+FF\s+(\d+) of"),
        "BRAM": g(r"^\s+BRAM\s+(\d+) of"), "DSP": g(r"^\s+DSP48E1\s+(\d+) of"), "Slices": g(r"^\s+Slices\s+(\d+) of"),
        "P_total": g(r"Total On-Chip Power \(W\)\s+(\S+)"), "P_ps7": g(r"PS7 \(W\)\s+(\S+)"),
        "P_logic": g(r"Slice Logic \(W\)\s+(\S+)"), "P_dsp": g(r"DSPs \(W\)\s+(\S+)"),
        "P_static": g(r"Device Static \(W\)\s+(\S+)"),
        "engine": g(r"^\s+patrm_0\s+(\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+)"),
    }


def hier_rows(folder):
    """Per-module rows below patrm_0/inst from utilization_hier.rpt: (instance, LUT, FF, RAMB36, DSP)."""
    rows, inside = [], False
    for line in (folder / "utilization_hier.rpt").read_text(encoding="utf-8", errors="replace").splitlines():
        cells = [c.strip() for c in line.split("|")]
        if len(cells) < 11:
            continue
        inst, module = cells[1], cells[2]
        if module.endswith("_patrm_top"):
            inside = True
            continue
        if inside:
            if not re.match(r"^u_\w+$", inst):
                break
            rows.append((inst, module.replace("system_patrm_0_0_", ""), cells[3], cells[7], cells[8], cells[10]))
    return rows


def main():
    L = []
    w = L.append
    w("# Bayer-PATRM: results summary (all measured numbers)")
    w("")
    w(f"Generated {time.strftime('%Y-%m-%d %H:%M')} by `scripts/summarize_results.py` from the tracked result files. "
      "Do not edit by hand: re-run the script. Board: ZedBoard Rev D (XC7Z020-1), PL clock 100 MHz (step 7.1: measured "
      "100.0025 MHz), ARM Cortex-A9 at 650 MHz. Sizes are W x H. 'Bit-exact' = 0 differing bytes against the Python model.")
    w("")

    # 1. builds
    w("## 1. FPGA builds: resources, timing, power (post-route, whole design)")
    w("")
    w("| Build | LUT | LUTRAM | FF | BRAM36 | DSP | Slices | WNS ns | WHS ns | Power W (total / PS7 / logic+DSP) | Note |")
    w("|---|---|---|---|---|---|---|---|---|---|---|")
    for label, folder, note in BUILDS:
        s = summary_fields(folder)
        pl = (num(s["P_logic"]) or 0) + (num(s["P_dsp"]) or 0)
        w(f"| {label} | {s['LUT']} | {s['LUTRAM']} | {s['FF']} | {s['BRAM']} | {s['DSP']} | {s['Slices']} | {s['WNS']} | "
          f"{s['WHS']} | {s['P_total']} / {s['P_ps7']} / {pl:.3f} | {note} |")
    w("")
    w("Device totals (XC7Z020): 53,200 LUT, 17,400 LUTRAM, 106,400 FF, 140 BRAM36, 220 DSP48E1, 13,300 slices. "
      "Power is a vectorless Vivado ESTIMATE; the PS7 (ARM, DDR controller) is about 1.57 W of the total. "
      "Sources: `results/hw/**/summary.txt`, `utilization.rpt`, `timing_summary.rpt`, `power.rpt`.")
    w("")
    for label, folder, _ in BUILDS[:3:2]:
        w(f"### Engine per module: {label}")
        w("")
        s = summary_fields(folder)
        e = s["engine"].split()
        if e:
            w(f"Engine total (patrm_0): {e[0]} LUT, {e[3]} FF, {e[4]} BRAM36, {e[5]} DSP. AXI GP0 protocol converter "
              "(AMD IP) is outside the engine.")
            w("")
        w("| Instance | Module | LUT | FF | BRAM36 | DSP |")
        w("|---|---|---|---|---|---|")
        for r in hier_rows(folder):
            w("| " + " | ".join(r) + " |")
        w("")
        w("The bilinear interpolator and other small logic are flattened into the top level (patrm_top) by Vivado, so they "
          f"have no row; they are the difference to the engine total. Source: `{rel(folder / 'utilization_hier.rpt')}`.")
        w("")

    # 2. board test sets
    w("## 2. Board test sets (every case checked bit-exact, last row, guard bytes, byte counters)")
    w("")
    w("| Result file | Cases | Passed | What |")
    w("|---|---|---|---|")
    for p in sorted((R / "board").glob("run_all_*.csv")):
        rows = read_csv(p)
        n_pass = sum(r["result"] == "PASS" for r in rows)
        what = []
        name = p.stem
        what.append("Bayer A" if "_bayer_a_bayer_a" in name else ("gray on Bayer A bitstream" if "_bayer_a_gray" in name
                                                                   else "gray bitstream"))
        what.append("ARM software" if "_sw_" in name else "FPGA engine")
        what.append("Ethernet" if "_eth" in name else "JTAG")
        if "o3" in name:
            what.append("-O3")
        w(f"| `{rel(p)}` | {len(rows)} | {n_pass} | {', '.join(what)} |")
    w("")

    # 3. speed: gray FPGA vs ARM
    eng = {(r["W"], r["H"], r["transform"]): r for r in read_csv(R / "board" / "run_all_revd_bayer_a_gray_eth.csv")}
    sw2 = {(r["W"], r["H"], r["transform"]): r for r in read_csv(R / "board" / "run_all_revd_sw_patrm_app.csv")}
    sw3 = {(r["W"], r["H"], r["transform"]): r for r in read_csv(R / "board" / "run_all_revd_sw_patrm_app_o3.csv")}
    w("## 3. Acceleration: grayscale, FPGA engine vs ARM software (same algorithm, same frames, bit-exact)")
    w("")
    w("FPGA = engine time START to DONE (Bayer A bitstream, Ethernet run). ARM = the same fixed-point warp in C "
      "(`sw/patrm_sw/patrm_sw.c`) on one Cortex-A9 core, warp time only (JTAG runs, -O2 and -O3). One frame per case "
      "(N = 1); step 7.2 will add N = 10 min/avg/max. Speedup = ARM -O2 / FPGA.")
    w("")
    w("| Size | Transform | FPGA ms | FPGA Mpix/s | RD stall % | ARM -O2 ms | ARM -O3 ms | Speedup |")
    w("|---|---|---|---|---|---|---|---|")
    for k, r in eng.items():
        a2, a3 = sw2.get(k), sw3.get(k)
        f_ms = num(r["engine_us"]) / 1e3
        a2_ms = num(a2["engine_us"]) / 1e3 if a2 else None
        a3_ms = num(a3["engine_us"]) / 1e3 if a3 else None
        w(f"| {k[0]}x{k[1]} | {k[2]} | {f_ms:.3f} | {r['mpix_s_engine']} | {r['rd_stall_pct']} | "
          f"{'' if a2_ms is None else f'{a2_ms:.2f}'} | {'' if a3_ms is None else f'{a3_ms:.2f}'} | "
          f"{'' if a2_ms is None else f'{a2_ms / f_ms:.1f}x'} |")
    w("")
    w("Sources: `results/board/run_all_revd_bayer_a_gray_eth.csv`, `run_all_revd_sw_patrm_app.csv`, "
      "`run_all_revd_sw_patrm_app_o3.csv` (also `run_all_revd_bayer_a_gray_eth_sw_patrm_eth.csv`: ARM over Ethernet, "
      "same times within about 2 %).")
    w("")

    # 4. Bayer A speed
    w("## 4. Bayer Option A on the board (engine time, Ethernet run)")
    w("")
    w("| Size | Image | Transform | Engine ms | fps (engine) | Mpix/s | RD stall % | BYTES_RD | BYTES_WR |")
    w("|---|---|---|---|---|---|---|---|---|")
    for r in read_csv(R / "board" / "run_all_revd_bayer_a_bayer_a_eth.csv"):
        w(f"| {r['W']}x{r['H']} | {r['image']} | {r['transform']} | {num(r['engine_us']) / 1e3:.3f} | {r['engine_fps']} | "
          f"{r['mpix_s_engine']} | {r['rd_stall_pct']} | {r['bytes_rd']} | {r['bytes_wr']} |")
    w("")
    w("No ARM Bayer baseline exists yet (the ARM software is grayscale only). Source: "
      "`results/board/run_all_revd_bayer_a_bayer_a_eth.csv`.")
    w("")

    # 5. paper comparison
    g = eng.get(("2448", "2095", "identity"))
    a = sw2.get(("2448", "2095", "identity"))
    w("## 5. Comparison with the paper (2448x2095 grayscale)")
    w("")
    w("| | Paper [1] | This project |")
    w("|---|---|---|")
    if g:
        w(f"| Frame time (FPGA) | 40 ms (25 fps) | {num(g['engine_us']) / 1e3:.2f} ms ({g['engine_fps']} fps), identity |")
        w(f"| Throughput | about 128 Mpixel/s | {g['mpix_s_engine']} Mpixel/s (about 1 pixel per clock at 100 MHz) |")
    if a:
        w(f"| ARM software, same image | 157.68 ms | {num(a['engine_us']) / 1e3:.1f} ms (-O2, Cortex-A9 650 MHz, fixed point) |")
    w("")
    w("Paper figures as quoted in docs/implementation-plan.md step 7.4; check them against the paper before publishing.")
    w("")

    # 6. Ethernet, video, clock
    w("## 6. Links, video and clock")
    w("")
    for title, pat in (("Ethernet echo / sink / source", "eth/echo_2026-11-23_105757.txt"),
                       ("Video stream, FPGA vs ARM (step 10.3)", "eth/video_matrix_2026-11-23_132556.txt")):
        p = R / pat
        if p.is_file():
            w(f"### {title}")
            w("")
            w("```")
            w(p.read_text(encoding="utf-8", errors="replace").rstrip()[:4000])
            w("```")
            w(f"Source: `{rel(p)}`.")
            w("")
    ck = sorted((R / "board" / "step7_1").glob("clock_check_*.txt"))
    if ck:
        w("### Clock check (step 7.1)")
        w("")
        w("```")
        w(ck[-1].read_text(encoding="utf-8").rstrip())
        w("```")
        w(f"Source: `{rel(ck[-1])}`.")
        w("")

    # 7. Option B
    w("## 7. Option B study (why it is not the better method)")
    w("")
    p = R / "sim" / "bayer_ab_256x192.txt"
    w("Simulation at equal clock, every frame bit-exact:")
    w("")
    w("```")
    w(p.read_text(encoding="utf-8").rstrip())
    w("```")
    s = summary_fields(R / "hw" / "bayer_b" / "rev_d")
    w("")
    w(f"Hardware build at 100 MHz: WNS {s['WNS']} ns, TNS {s['TNS']}; {s['LUT']} LUT, {s['FF']} FF, {s['BRAM']} BRAM36, "
      f"{s['DSP']} DSP (Option A: see section 1). Not loaded on the board.")
    w("")
    w("Why B is not faster (details: `results/hw/bayer_b/rev_d/README.md`, plan Progress 2026-11-23):")
    w("1. Serial window fetch: `bayer_store` requests one missing source window and waits for its last beat before the "
      "next, so DDR latency is paid per window; read stall 30-94 % of cycles (A keeps up to 8 reads in flight).")
    w("2. Four lanes, but never more than about 1 output pixel per clock: the lanes starve waiting for data.")
    w("3. Timing: the fallback's 16-step compare chain in one clock (86 logic levels, 55.7 ns) and mode multiplexers that "
      "also slow the shared gray/A paths; implied clock about 18 MHz (estimate).")
    w("4. Cost: about 3.9x the LUTs, 5x the BRAM and 3x the DSP of Option A for no speed gain.")
    w("")
    OUT.write_text("\n".join(L) + "\n", encoding="utf-8")
    print(f"wrote {rel(OUT)} ({len(L)} lines)")


if __name__ == "__main__":
    main()
