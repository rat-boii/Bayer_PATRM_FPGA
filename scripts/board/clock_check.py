"""Step 7.1: measure the PL clock (FCLK0) against the ARM global timer, and the global timer against the PC clock.

    python scripts/board/clock_check.py                      board already running an application (JTAG or Ethernet)
    python scripts/board/clock_check.py --link jtag
    python scripts/board/clock_check.py --wait 30 --samples 3 --sizes 128x96,480x272,800x480,1920x1080,2448x2095

Three independent checks, all must pass (limit 0.1 %, plan step 7.1):
 1. Configuration: the SLCR clock registers give FCLK0 and the global timer frequency from the 33.333 MHz crystal
    (UG585: PLL = PS_CLK x FDIV; FCLK0 = source PLL / DIVISOR0 / DIVISOR1; CPU_6x4x = ARM_CLK source / DIVISOR;
    global timer = CPU_3x2x = CPU_6x4x / 2). FCLK0 must be 100 MHz and the global timer must equal the frequency the
    application converts with (timer_hz in the result record).
 2. Global timer against the PC clock: scripts/board/clock_regs.tcl samples the 64-bit counter through core 1
    (core 0 keeps running) --samples times, --wait seconds apart; frequency = least-squares slope of count over
    host time. The read window (host time before/after each read) bounds the error.
 3. PL clock against the global timer: identity jobs at several sizes (run_job.py, N frames each). The engine time
    (START written to DONE seen, global timer) is a straight line in CYCLES: time = CYCLES / f_PL + fixed overhead.
    The slope gives f_PL without the overhead; f_PL in PC time = that x (measured timer / nominal timer).
Writes results/board/step7_1/clock_check_<date>_<time>.txt. Last line CLOCK CHECK PASS or CLOCK CHECK FAIL: <reason>.
"""
import argparse
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
from amd_tools import require_tool          # noqa: E402

PS_CLK_HZ = 100e6 / 3                     # ZedBoard PS reference: 33.333... MHz crystal
PL_TARGET_HZ = 100e6                       # D8
LIMIT = 1e-3                               # 0.1 %
DEFAULT_SIZES = "128x96,480x272,800x480,1920x1080,2448x2095"


def bits(v, hi, lo):
    return (v >> lo) & ((1 << (hi - lo + 1)) - 1)


def pll_hz(ctrl):
    """PLL output from its CTRL register; bypass (bit 4 forced, or bit 3 with the bootstrap pin) gives PS_CLK."""
    if bits(ctrl, 4, 4):
        return PS_CLK_HZ
    return PS_CLK_HZ * bits(ctrl, 18, 12)


def decode(regs):
    plls = {"ARM": pll_hz(regs["ARM_PLL_CTRL"]), "DDR": pll_hz(regs["DDR_PLL_CTRL"]), "IO": pll_hz(regs["IO_PLL_CTRL"])}
    arm = regs["ARM_CLK_CTRL"]
    arm_src = {0: "ARM", 1: "ARM", 2: "DDR", 3: "IO"}[bits(arm, 5, 4)]
    cpu_6x4x = plls[arm_src] / bits(arm, 13, 8)
    gt = cpu_6x4x / 2                       # CPU_3x2x in both 6:2:1 and 4:2:1
    f0 = regs["FPGA0_CLK_CTRL"]
    f0_src = {0: "IO", 1: "IO", 2: "ARM", 3: "DDR"}[bits(f0, 5, 4)]
    fclk0 = plls[f0_src] / bits(f0, 13, 8) / bits(f0, 25, 20)
    lines = [f"PLLs (PS_CLK {PS_CLK_HZ / 1e6:.6f} MHz): ARM {plls['ARM'] / 1e6:.3f} MHz (FDIV {bits(regs['ARM_PLL_CTRL'], 18, 12)}), "
             f"DDR {plls['DDR'] / 1e6:.3f} MHz, IO {plls['IO'] / 1e6:.3f} MHz (FDIV {bits(regs['IO_PLL_CTRL'], 18, 12)})",
             f"CPU_6x4x {cpu_6x4x / 1e6:.3f} MHz ({arm_src} PLL / {bits(arm, 13, 8)}), "
             f"ratio {'6:2:1' if regs['CLK_621_TRUE'] & 1 else '4:2:1'}, global timer = CPU_3x2x {gt / 1e6:.3f} MHz "
             f"(enabled: {'yes' if regs['GT_CONTROL'] & 1 else 'NO'})",
             f"FCLK0 {fclk0 / 1e6:.6f} MHz ({f0_src} PLL / {bits(f0, 13, 8)} / {bits(f0, 25, 20)})"]
    return gt, fclk0, lines


def fit(xs, ys):
    """Least-squares line y = a + b x; returns (b, a, largest residual)."""
    n = len(xs)
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    b = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    a = my - b * mx
    return b, a, max(abs(y - (a + b * x)) for x, y in zip(xs, ys))


def run_xsdb(args, timeout):
    xsdb = require_tool("xsdb")
    cmd = (["cmd", "/c", str(xsdb)] if xsdb.suffix.lower() in (".bat", ".cmd") else [str(xsdb)])
    cmd += [str(REPO / "scripts" / "board" / "clock_regs.tcl")] + args
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=REPO)
    return p.stdout + p.stderr


def run_job(size, a):
    W, H = (int(t) for t in size.lower().split("x"))
    cmd = [sys.executable, str(REPO / "scripts" / "board" / "run_job.py"), a.image, "identity", str(W), str(H),
           "--rev", a.rev, "--link", a.link, "--n", str(a.n)]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=900, cwd=REPO).stdout
    if "JOB PASS" not in out:
        tail = [l for l in out.splitlines() if l.strip()][-3:]
        raise RuntimeError(f"run_job {size} did not pass: {' | '.join(tail)}")
    cyc = re.search(r"over N = (\d+): min (\d+), avg (\d+), max (\d+)", out)
    eng = re.search(r"engine time\s+min ([\d.]+) us, avg ([\d.]+) us, max ([\d.]+) us", out)
    hz = re.search(r"timer\s+(\d+) Hz", out)
    if not (cyc and eng and hz):
        raise RuntimeError(f"run_job {size}: CYCLES / engine time / timer line not found")
    return dict(size=size, pixels=W * H, n=int(cyc.group(1)), cyc_min=int(cyc.group(2)), cyc_avg=int(cyc.group(3)),
                cyc_max=int(cyc.group(4)), us_min=float(eng.group(1)), us_avg=float(eng.group(2)),
                us_max=float(eng.group(3)), timer_hz=int(hz.group(1)))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rev", choices=("c", "d"), default="d")
    ap.add_argument("--link", choices=("jtag", "eth"), default="eth")
    ap.add_argument("--image", default="photo")
    ap.add_argument("--sizes", default=DEFAULT_SIZES)
    ap.add_argument("--n", type=int, default=10, help="frames per size")
    ap.add_argument("--wait", type=float, default=30.0, help="seconds between global timer samples")
    ap.add_argument("--samples", type=int, default=3, help="global timer samples (>= 2)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)
    sizes = [s for s in a.sizes.split(",") if s]
    if len(sizes) < 2:
        ap.error("at least two sizes are needed for the line fit")

    out_dir = REPO / "results" / "board" / "step7_1"
    report = out_dir / time.strftime("clock_check_%Y-%m-%d_%H%M%S.txt")
    log = []

    def say(s=""):
        print(s)
        log.append(s)

    say(f"step 7.1 clock check, {time.strftime('%Y-%m-%d %H:%M:%S')}: board Rev {a.rev.upper()}, link {a.link}, "
        f"sizes {', '.join(sizes)}, N = {a.n}, global timer {a.samples} samples {a.wait:g} s apart, limit {LIMIT:.1%}")
    if a.dry_run:
        say(f"WOULD RUN: xsdb scripts/board/clock_regs.tcl --wait {a.wait:g} --samples {a.samples}")
        for s in sizes:
            say(f"WOULD RUN: run_job.py {a.image} identity {s.replace('x', ' ')} --rev {a.rev} --link {a.link} --n {a.n}")
        say("CLOCK CHECK DRY RUN OK")
        return 0

    fails = []
    # 1 + 2: registers and global timer samples
    say("\n--- 1. clock configuration (SLCR registers, through core 1)")
    out = run_xsdb(["--wait", f"{a.wait:g}", "--samples", str(a.samples)], timeout=a.wait * a.samples + 180)
    if "CLOCK_REGS DONE" not in out:
        err = [l for l in out.splitlines() if "BOARD ERROR" in l]
        say(f"CLOCK CHECK FAIL: clock_regs.tcl: {err[0] if err else 'no DONE line'}")
        return 1
    regs = {m.group(1): int(m.group(2), 16) for m in re.finditer(r"^REG (\w+) 0x([0-9A-Fa-f]+)", out, re.M)}
    for k, v in regs.items():
        say(f"  {k:<15} 0x{v:08X}")
    gt_nom, fclk0_nom, lines = decode(regs)
    for l in lines:
        say("  " + l)
    if abs(fclk0_nom - PL_TARGET_HZ) / PL_TARGET_HZ > 1e-9:
        fails.append(f"FCLK0 configured {fclk0_nom / 1e6:.6f} MHz, not 100 MHz")
    if not regs["GT_CONTROL"] & 1:
        fails.append("global timer not enabled")

    say("\n--- 2. global timer against the PC clock")
    gts = [tuple(int(t) for t in m.groups()) for m in re.finditer(r"^GT (\d+) (\d+) (\d+)", out, re.M)]
    for t0, t1, c in gts:
        say(f"  host {t0 / 1e6:.6f} s (read window {t1 - t0} us), count {c}")
    xs = [(t0 + t1) / 2e6 for t0, t1, _ in gts]
    ys = [c for _, _, c in gts]
    gt_meas, _, _ = fit(xs, ys)
    span = xs[-1] - xs[0]
    win = max(t1 - t0 for t0, t1, _ in gts) / 1e6
    gt_err = (win / span) if span > 0 else 1.0       # both end reads may be off by a whole window: conservative bound
    gt_dev = (gt_meas - gt_nom) / gt_nom
    say(f"  measured {gt_meas / 1e6:.6f} MHz over {span:.1f} s, nominal {gt_nom / 1e6:.6f} MHz: "
        f"{gt_dev:+.5%} (read-window bound +-{gt_err:.5%}; the PC clock itself is typically within 0.01 %)")
    if abs(gt_dev) > LIMIT:
        fails.append(f"global timer {gt_dev:+.4%} from its configured frequency")

    # 3: PL clock against the global timer
    say(f"\n--- 3. PL clock against the global timer (identity jobs, {a.image}, N = {a.n})")
    rows = []
    for s in sizes:
        try:
            r = run_job(s, a)
        except Exception as e:                      # noqa: BLE001
            say(f"CLOCK CHECK FAIL: {e}")
            return 1
        rows.append(r)
        say(f"  {s:<10} CYCLES avg {r['cyc_avg']:>9} (min {r['cyc_min']}, max {r['cyc_max']}), engine avg "
            f"{r['us_avg']:>11.3f} us, ratio {r['cyc_avg'] / r['us_avg']:.4f} cycles/us")
    timer_hz = {r["timer_hz"] for r in rows}
    if len(timer_hz) != 1:
        fails.append(f"application timer_hz differs between jobs: {sorted(timer_hz)}")
    app_hz = rows[0]["timer_hz"]
    if abs(app_hz - gt_nom) / gt_nom > 1e-6:
        fails.append(f"the application converts with {app_hz} Hz but the global timer is configured to {gt_nom:.0f} Hz")
    slope, icpt, resid = fit([r["cyc_avg"] for r in rows], [r["us_avg"] for r in rows])
    pl_gt = 1e6 / slope                              # PL cycles per second of global-timer time
    pl_abs = pl_gt * gt_meas / app_hz                # the same in PC time
    dev_gt = (pl_gt - PL_TARGET_HZ) / PL_TARGET_HZ
    dev_abs = (pl_abs - PL_TARGET_HZ) / PL_TARGET_HZ
    say(f"  line fit: engine time = CYCLES / {pl_gt / 1e6:.6f} MHz + {icpt:.3f} us (fixed START/poll overhead), "
        f"largest residual {resid:.3f} us")
    say(f"  PL clock in global-timer time: {pl_gt / 1e6:.6f} MHz ({dev_gt:+.5%} from 100 MHz)")
    say(f"  PL clock in PC time:           {pl_abs / 1e6:.6f} MHz ({dev_abs:+.5%} from 100 MHz)")
    if abs(dev_gt) > LIMIT:
        fails.append(f"PL clock {dev_gt:+.4%} from 100 MHz against the global timer")
    if abs(dev_abs) > LIMIT:
        fails.append(f"PL clock {dev_abs:+.4%} from 100 MHz against the PC clock")

    say("")
    say("CLOCK CHECK PASS" if not fails else "CLOCK CHECK FAIL: " + "; ".join(fails))
    out_dir.mkdir(parents=True, exist_ok=True)
    report.write_text("\n".join(log) + "\n", encoding="utf-8")
    print(f"report: {report.relative_to(REPO)}")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
