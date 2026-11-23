"""Whole regression: vectors, model tests, D17 check, every testbench, required fault runs, full-system simulation.

    python scripts/regress.py               everything
    python scripts/regress.py --no-system   without the Zynq VIP simulation (step 4.1b, a few minutes)

Prints one result line per item. A fault run passes only if its testbench reports TEST FAIL. The logs are in
build/regress/. The last line is REGRESSION PASS or REGRESSION FAIL; the exit code is 0 only for REGRESSION PASS.
"""
import argparse
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOG_DIR = ROOT / "build" / "regress"
PY = sys.executable
VEC = ["--plusarg", "VEC_DIR=data/vectors"]

GENERATORS = [("gen_images", ["-m", "model.gen_images"]),
              ("gen_vectors", ["-m", "model.gen_vectors"])] + [
    (f"gen_{n}", [f"scripts/gen_{n}_vectors.py"])
    for n in ("axil", "coord_gen", "axi_rd", "out_path", "block_planner", "fetch_path", "patrm_top", "bayer_b", "system")]
MODEL_TESTS = ("test_patrm", "test_step1_2", "test_bayer", "test_memmodel", "test_interface", "test_regs",
               "test_job_layout", "test_patrm_sw", "test_bayer_a", "test_patrm_drv", "test_bayer_jobs")
# board runners without a board: arguments, model data and the XSDB scripts up to "nothing was done"
DRY_RUNS = [("dry_run_frame", ["scripts/board/run_frame.py", "mixed", "identity", "64", "64", "--dry-run"]),
            ("dry_run_job", ["scripts/board/run_job.py", "mixed", "identity", "64", "64", "--dry-run"]),
            ("dry_run_job_sw", ["scripts/board/run_job.py", "mixed", "identity", "64", "64", "--sw", "--dry-run"])]
AXIL = ["--top", "tb_axil_regs", "-f", "tb/axil_regs.f", "--incdir", "rtl"]
TOP = ["--top", "tb_patrm_top", "-f", "tb/patrm_top.f", "--incdir", "rtl"] + VEC
TOP_A = TOP + ["--define", "TB_BAYER_A"]               # Option A build of the same bench (step 5.2)
TOP_B = TOP + ["--define", "TB_BAYER_B"]
BENCHES = [("tb_axil_regs", AXIL),
           ("tb_axil_regs_alt_seed", AXIL + ["--define", "ALT_SEED"]),
           ("tb_coord_gen", ["--top", "tb_coord_gen", "-f", "tb/coord_gen.f"] + VEC),
           ("tb_bilinear_interp", ["--top", "tb_bilinear_interp", "-f", "tb/bilinear_interp.f"] + VEC),
           ("tb_axi_rd_master", ["--top", "tb_axi_rd_master", "-f", "tb/axi_rd_master.f",
                                 "--plusarg", "VEC_DIR=data/vectors/axi_rd"]),
           ("tb_out_path", ["--top", "tb_out_path", "-f", "tb/out_path.f"] + VEC),
           ("tb_block_planner", ["--top", "tb_block_planner", "-f", "tb/block_planner.f"] + VEC),
           ("tb_fetch_path", ["--top", "tb_fetch_path", "-f", "tb/fetch_path.f"] + VEC),
           ("tb_bayer_seq", ["--top", "tb_bayer_seq", "-f", "tb/bayer_seq.f"]),
           ("tb_patrm_top", TOP),
           ("tb_patrm_top_bayer_a", TOP_A), ("tb_patrm_top_bayer_b", TOP_B),
           ("tb_patrm_top_b_rect", TOP_B + ["--define", "TB_RECT_ONLY"])]
FAULTS = [("fault_done_early", TOP + ["--define", "PATRM_FAULT_DONE_EARLY"]),
          ("fault_busy_gap", TOP + ["--define", "PATRM_FAULT_BUSY_GAP"]),
          ("fault_busy_gap_regs", AXIL + ["--define", "PATRM_FAULT_BUSY_GAP"]),
          ("fault_a_ocol", TOP_A + ["--define", "PATRM_FAULT_A_OCOL"]),          # step 5.2
          ("fault_a_wstrb", TOP_A + ["--define", "PATRM_FAULT_A_WSTRB"]),
          ("fault_a_rowstep", TOP_A + ["--define", "PATRM_FAULT_A_ROWSTEP"])]


FAULTS += [(fault.lower(), TOP_B + ["--define", fault])
           for fault in ("PATRM_FAULT_B_OFFSET", "PATRM_FAULT_B_GREENS", "PATRM_FAULT_B_OVERWRITE", "PATRM_FAULT_DONE_EARLY")]


def run(name, args, must_fail=False):
    start = time.time()
    log = LOG_DIR / f"{name}.log"
    with open(log, "w") as f:
        rc = subprocess.run([PY] + args, cwd=ROOT, stdout=f, stderr=subprocess.STDOUT).returncode
    text = log.read_text(errors="replace")
    verdicts = [ln for ln in text.splitlines() if ln.startswith(("TEST PASS", "TEST FAIL", "SIM ERROR"))]
    last = verdicts[-1][:120] if verdicts else ""
    ok = (rc == 1 and "TEST FAIL" in last) if must_fail else rc == 0
    note = "fails as required: " if must_fail and ok else ""
    print(f"{'PASS' if ok else 'FAIL'}  {name}  exit {rc}, {time.time() - start:.0f} s  {note}{last}", flush=True)
    return ok


def compare_b_cycles():
    """Paired simulations. Keep raw cycles for team review at the next timing milestone."""
    pattern = re.compile(r"^\s+([a-h] B .+?): CYCLES (\d+),", re.MULTILINE)
    def rows(name):
        return pattern.findall((LOG_DIR / f"{name}.log").read_text(errors="replace"))
    full, baseline = rows("tb_patrm_top_bayer_b"), rows("tb_patrm_top_b_rect")
    if not baseline or [key for key, _ in baseline] != [key for key, _ in full[:len(baseline)]]:
        print("FAIL  paired Option B cycle comparison: missing or mismatched cases")
        return False
    differences = [int(current) - int(prior) for (_, current), (_, prior) in zip(full, baseline)]
    print(f"Option B paired frame cycles: {len(baseline)} ordinary jobs; "
          f"fallback-enabled minus rectangular-only range {min(differences):+d}..{max(differences):+d}")
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--no-system", action="store_true", help="skip the full-system simulation with the Zynq VIP")
    args = ap.parse_args()
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    start = time.time()
    results = [run(n, a) for n, a in GENERATORS]
    results += [run(f"model_{t}", ["-m", f"model.{t}"]) for t in MODEL_TESTS]
    results += [run("model_test_bayer_b_design", ["-m", "model.test_bayer_b_design"])]
    results += [run(n, a) for n, a in DRY_RUNS]
    results.append(run("check_no_sv", ["scripts/check_no_sv.py", "--syntax"]))
    results += [run(n, ["scripts/sim.py"] + a) for n, a in BENCHES]
    results.append(compare_b_cycles())
    results += [run(n, ["scripts/sim.py"] + a, must_fail=True) for n, a in FAULTS]
    if not args.no_system:
        results.append(run("tb_system", ["scripts/sim_system.py"]))
    failed = results.count(False)
    print(f"--- {len(results)} items, {time.time() - start:.0f} s")
    print("REGRESSION PASS" if not failed else f"REGRESSION FAIL: {failed} item(s)")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
