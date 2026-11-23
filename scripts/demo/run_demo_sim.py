"""Demo in the Vivado simulator: one real image through the whole PATRM engine RTL, with waveforms (for the review).

    python scripts/demo/run_demo_sim.py                 make the demo case (rot15, 256x192) and open the xsim GUI
    python scripts/demo/run_demo_sim.py --transform rot37
    python scripts/demo/run_demo_sim.py --batch         same case without the GUI (prints SIM RESULT: PASS / FAIL)

What runs: tb/tb_patrm_top.v with the engine rtl/patrm_top.v and an AXI memory model. The testbench writes the
registers over AXI-Lite like the ARM driver, starts the engine, serves its HP0 reads and HP1 writes from the memory
model, then compares every output byte with the Python model (model/patrm.py) and the counters with the memory
model's predictions. The GUI opens with five wave groups (scripts/demo/demo_wave.tcl) and runs to the end; the Tcl
console shows "TEST PASS". data/vectors_demo/source.png and expected.png show the image before and after.
"""
import argparse
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--transform", default="rot15")
    ap.add_argument("--batch", action="store_true", help="no GUI, just the pass/fail result")
    a = ap.parse_args(argv)
    r = subprocess.run([sys.executable, str(REPO / "scripts" / "demo" / "make_demo_case.py"), "--transform",
                        a.transform], cwd=REPO)
    if r.returncode:
        return r.returncode
    cmd = [sys.executable, str(REPO / "scripts" / "sim.py"), "--top", "tb_patrm_top", "-f", "tb/patrm_top.f",
           "--incdir", "rtl", "--plusarg", "VEC_DIR=data/vectors_demo", "--plusarg", "SINGLE_CASE=1"]
    if not a.batch:
        cmd += ["--gui", "--tclbatch", "scripts/demo/demo_wave.tcl"]
    return subprocess.run(cmd, cwd=REPO).returncode


if __name__ == "__main__":
    sys.exit(main())
