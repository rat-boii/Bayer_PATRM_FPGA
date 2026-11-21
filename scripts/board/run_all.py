"""Full grayscale test set on the ZedBoard through the ARM job application (step 4.3).

    python scripts/board/run_all.py --rev d                      the Rev D board (results/hw/rev D files)
    python scripts/board/run_all.py --rev c                      the Rev C board, the team reference (results/hw, D18)
    python scripts/board/run_all.py --rev d --dry-run            every XSDB command of every case, no board
    python scripts/board/run_all.py --rev d --sizes 480x272 --transforms identity,rot15     a subset

Default set: every transform in model/transforms.json at 480x272, 800x480 and the paper size 2448x2095 (W x H, D7),
image "photo" (the test photo scaled to the size). Each case is one run of scripts/board/run_job.py: the first one with
--load (program the bitstream, initialise the PS, start patrm_app), the others reuse the running application.
run_job_xsdb.tcl is the per-test XSDB script (the plan's "run_test.tcl"). A case passes when run_job.py ends with
JOB PASS: output bit-exact with the model (all rows, last row included), guard bytes untouched, result code OK,
BYTES_RD / BYTES_WR equal to the model's predictions.

Output: results/board/run_all_rev<r>.csv (one row per case) and results/board/run_all_rev<r>.txt (the summary),
per-case logs in build/board/run_all_rev<r>/. The last line is RUN_ALL PASS or RUN_ALL FAIL: <cases>; exit code 0 / 1.
"""
import argparse
import csv
import datetime
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "scripts"))

import run_frame as RF                       # noqa: E402
from model import job as J                   # noqa: E402
from model.gen_transforms import load as load_transforms   # noqa: E402

DEFAULT_SIZES = "480x272,800x480,2448x2095"
HW = {"c": ROOT / "results" / "hw", "d": ROOT / "results" / "hw" / "rev D"}
CSV_FIELDS = ["case", "image", "transform", "W", "H", "result", "exit_code", "rc", "cycles", "pl_ms", "pl_fps",
              "engine_us", "total_us", "engine_fps", "total_fps", "mpix_s_engine", "bytes_rd", "bytes_wr",
              "rd_stall", "wr_stall", "rd_stall_pct", "seconds"]


def parse_sizes(text):
    sizes = []
    for s in text.split(","):
        w, h = s.lower().strip().split("x")
        sizes.append((int(w), int(h)))
    return sizes


def case_row(k, image, tf, W, H, code, seconds, a):
    """One CSV row; the numbers come from the result record run_job.py saved (none in a dry run)."""
    row = dict(case=k, image=image, transform=tf, W=W, H=H, exit_code=code, seconds=f"{seconds:.1f}",
               result="PASS" if code == RF.EXIT_PASS else ("FAIL" if code == RF.EXIT_FAIL else "ERROR"))
    if a.dry_run:
        row["result"] = "DRY" if code == RF.EXIT_PASS else row["result"]
        return row
    _, image_name = RF.find_image(image, W, H)
    path = RF.RUN_ROOT / f"job_{image_name}_{tf}_{W}x{H}" / "result.bin"
    if not path.is_file():
        return row
    r = J.decode_result(path.read_bytes())
    cyc = r["cycles_avg"] or r["cycles"]
    row.update(rc=r["rc_name"], cycles=cyc, bytes_rd=r["bytes_rd"], bytes_wr=r["bytes_wr"],
               rd_stall=r["rd_stall"], wr_stall=r["wr_stall"])
    if cyc:
        row.update(pl_ms=f"{1e3 * cyc / RF.PL_CLOCK_HZ:.3f}", pl_fps=f"{RF.PL_CLOCK_HZ / cyc:.1f}",
                   rd_stall_pct=f"{100 * r['rd_stall'] / r['cycles']:.1f}" if r["cycles"] else "")
    if r["engine_ns_avg"]:
        row.update(engine_us=f"{r['engine_ns_avg'] / 1e3:.3f}", engine_fps=f"{1e9 / r['engine_ns_avg']:.1f}",
                   mpix_s_engine=f"{W * H / (r['engine_ns_avg'] / 1e9) / 1e6:.2f}")
    if r["total_ns_avg"]:
        row.update(total_us=f"{r['total_ns_avg'] / 1e3:.3f}", total_fps=f"{1e9 / r['total_ns_avg']:.1f}")
    return row


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rev", choices=("c", "d"), required=True, help="board revision: selects the bitstream and ps7_init")
    ap.add_argument("--sizes", default=DEFAULT_SIZES, help=f"W x H list (default {DEFAULT_SIZES})")
    ap.add_argument("--transforms", default="", help="comma list (default: all of model/transforms.json)")
    ap.add_argument("--images", default="photo", help="comma list of image names from data/gen (default photo)")
    ap.add_argument("--n", type=int, default=1, help="frames per case (run_job --n)")
    ap.add_argument("--elf", default=str(ROOT / "results" / "hw" / "patrm_app.elf"), help="ARM application")
    ap.add_argument("--dry-run", action="store_true", help="print every XSDB command, touch no board")
    a = ap.parse_args(argv)

    hw = HW[a.rev]
    bit, init = hw / "patrm_gray.bit", hw / "ps7_init.tcl"
    for p in (bit, init, Path(a.elf)):
        if not p.is_file():
            print(f"RUN_ALL FAIL: missing {p}")
            return RF.EXIT_ERROR
    sizes = parse_sizes(a.sizes)
    names = [t["name"] for t in load_transforms()]
    tfs = [t.strip() for t in a.transforms.split(",") if t.strip()] or names
    bad = [t for t in tfs if t not in names]
    if bad:
        print(f"RUN_ALL FAIL: unknown transform(s) {', '.join(bad)}")
        return RF.EXIT_ERROR
    images = [i.strip() for i in a.images.split(",") if i.strip()]
    cases = [(img, tf, W, H) for (W, H) in sizes for img in images for tf in tfs]

    tag = f"rev{a.rev}" + ("_dry" if a.dry_run else "")
    log_dir = RF.RUN_ROOT / f"run_all_{tag}"
    log_dir.mkdir(parents=True, exist_ok=True)
    out_dir = ROOT / "results" / "board"
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"run_all: {len(cases)} cases ({len(sizes)} sizes x {len(images)} image(s) x {len(tfs)} transforms), "
          f"board Rev {a.rev.upper()}, bit {bit}, init {init}, elf {a.elf}, N = {a.n}{', DRY RUN' if a.dry_run else ''}")

    rows, start = [], time.time()
    for k, (img, tf, W, H) in enumerate(cases, 1):
        args = [img, tf, str(W), str(H), "--n", str(a.n), "--elf", a.elf]
        if k == 1:
            args += ["--load", "--bit", str(bit), "--init", str(init)]
        if a.dry_run:
            args.append("--dry-run")
        t0 = time.time()
        p = subprocess.run([sys.executable, str(HERE / "run_job.py")] + args, cwd=ROOT, capture_output=True,
                           text=True, errors="replace")
        secs = time.time() - t0
        (log_dir / f"{k:02d}_{img}_{tf}_{W}x{H}.log").write_text(p.stdout + p.stderr, encoding="utf-8")
        last = (p.stdout.strip().splitlines() or ["(no output)"])[-1]
        row = case_row(k, img, tf, W, H, p.returncode, secs, a)
        rows.append(row)
        extra = f"  cycles {row.get('cycles', '')}  engine {row.get('engine_us', '')} us" if row.get("cycles") else ""
        print(f"[{k:2d}/{len(cases)}] {W}x{H} {img} {tf:<11} {row['result']:<5} {secs:5.1f} s{extra}   ({last})")
        if k == 1 and p.returncode != RF.EXIT_PASS:
            print("run_all: the first case (with --load) did not pass; stopping. Log:", log_dir / f"01_{img}_{tf}_{W}x{H}.log")
            break

    csv_path = out_dir / f"run_all_{tag}.csv"
    with open(csv_path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=CSV_FIELDS)
        w.writeheader()
        w.writerows(rows)
    failed = [f"{r['W']}x{r['H']} {r['image']} {r['transform']} ({r['result']})" for r in rows
              if r["result"] not in ("PASS", "DRY")]
    if len(rows) < len(cases):
        failed.append(f"{len(cases) - len(rows)} cases not run")
    lines = [f"run_all (step 4.3), {datetime.datetime.now():%Y-%m-%d %H:%M}, board Rev {a.rev.upper()}, "
             f"bitstream {bit.relative_to(ROOT).as_posix()}, ps7_init {init.relative_to(ROOT).as_posix()}, N = {a.n}",
             f"cases {len(rows)} of {len(cases)} run, {sum(r['result'] in ('PASS', 'DRY') for r in rows)} passed, "
             f"{time.time() - start:.0f} s; CSV {csv_path.relative_to(ROOT).as_posix()}; logs {log_dir.relative_to(ROOT).as_posix()}",
             ""]
    lines.append(f"{'size':<10} {'transform':<11} {'result':<6} {'cycles':>9} {'PL ms':>8} {'PL fps':>8} "
                 f"{'engine us':>10} {'end-to-end us':>13} {'Mpix/s':>7} {'RD stall %':>10}")
    for r in rows:
        lines.append(f"{str(r['W']) + 'x' + str(r['H']):<10} {r['transform']:<11} {r['result']:<6} "
                     f"{str(r.get('cycles', '')):>9} {str(r.get('pl_ms', '')):>8} {str(r.get('pl_fps', '')):>8} "
                     f"{str(r.get('engine_us', '')):>10} {str(r.get('total_us', '')):>13} "
                     f"{str(r.get('mpix_s_engine', '')):>7} {str(r.get('rd_stall_pct', '')):>10}")
    lines.append("")
    lines.append("RUN_ALL PASS" if not failed else "RUN_ALL FAIL: " + "; ".join(failed))
    (out_dir / f"run_all_{tag}.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n" + "\n".join(lines))
    return RF.EXIT_PASS if not failed else RF.EXIT_FAIL


if __name__ == "__main__":
    sys.exit(main())
