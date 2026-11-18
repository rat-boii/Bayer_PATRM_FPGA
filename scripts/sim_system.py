"""Full-system simulation of the block design with the Zynq-7000 VIP as the PS model (step 4.1b). No board.

    python scripts/gen_system_vectors.py     (first; vectors in data/vectors/system/)
    python scripts/sim_system.py             generate the sources from the block design, compile, elaborate, run
    python scripts/sim_system.py --reuse     keep the generated project; compile, elaborate and run again
    python scripts/sim_system.py --run-only  only run the last elaborated simulation
    python scripts/sim_system.py --reuse --define PATRM_FAULT_W1   must FAIL (fault injection, never in a build)

vivado/sim_system.tcl makes the project build/vivado/patrm_gray_sim (same block design as vivado/build.tcl, no ILA) and
the xsim scripts. The logs stay in the xsim folder of that project. Each CASE line of the testbench gets the host
seconds it took. Exit code 0 only if the simulation prints TEST PASS, no TEST FAIL and no VIP error.
"""
import argparse
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from amd_tools import REPO_ROOT, require_tool  # noqa: E402
from check_no_sv import check as check_no_sv  # noqa: E402

EXIT_PASS, EXIT_FAIL, EXIT_TOOL_ERROR = 0, 1, 2
TOP = "tb_system"
VIVADO_DIR = REPO_ROOT / "build" / "vivado"
SIM_DIR = VIVADO_DIR / "patrm_gray_sim" / "patrm_gray_sim.sim" / "sim_1" / "behav" / "xsim"
VEC_DIR = REPO_ROOT / "data" / "vectors" / "system"
VIP_ERROR = "*ZYNQ_VIP_ERROR"


def tool_env():
    env = dict(os.environ)
    env["PATH"] = str(require_tool("vivado").parent) + os.pathsep + env["PATH"]
    return env


def step(name, cmd, cwd, env):
    """Run one tool step with its output in <cwd>/<name>.out; stop the script if it fails."""
    start = time.time()
    out = Path(cwd) / f"{name}.out"
    with open(out, "w") as f:
        r = subprocess.run(cmd, cwd=cwd, env=env, stdout=f, stderr=subprocess.STDOUT)
    print(f"--- {name}: exit {r.returncode}, {time.time() - start:.0f} s", flush=True)
    if r.returncode != 0:
        print(f"SIM ERROR: {name} failed; see {out}")
        sys.exit(EXIT_TOOL_ERROR)


def check_plain_verilog():
    """D17: every file of ours must be on a plain Verilog compile line of the generated project file."""
    text = (SIM_DIR / f"{TOP}_vlog.prj").read_text()
    section, ours = None, 0
    for line in text.splitlines():
        words = line.split()
        if words and words[0] in ("verilog", "sv"):
            section = words[0]
        for name in re.findall(r'"([^"]+\.v)"', line):
            if Path(name).parts[:7].count("..") == 7 and Path(name).parts[7] in ("rtl", "tb"):
                ours += 1
                if section != "verilog":
                    return f"{name} is compiled as {section}", ours
    return "" if ours else "no file of ours found in the project file", ours


def run_bat(name, env, defines=()):
    """Run a generated script without incremental compile, so that a change of --define always takes effect."""
    text = (SIM_DIR / f"{name}.bat").read_text().replace("--incr ", "")
    for d in defines:
        text = text.replace("call xvlog ", f"call xvlog -d {d} ")
    copy = SIM_DIR / f"{name}_run.bat"
    copy.write_text(text)
    step(name, ["cmd", "/c", str(copy)], SIM_DIR, env)


def run_xsim(env, timeout_s):
    plus = ["VEC_DIR=" + Path(os.path.relpath(VEC_DIR, SIM_DIR)).as_posix()]
    cmd = subprocess.list2cmdline([str(require_tool("xsim")), f"{TOP}_behav", "--runall", "--log", "xsim.log"])
    cmd += "".join(f' --testplusarg "{p}"' for p in plus)
    start = last = time.time()
    verdicts, vip_errors = [], []
    p = subprocess.Popen(cmd, cwd=SIM_DIR, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                         errors="replace")
    for line in p.stdout:
        line = line.rstrip()
        now = time.time()
        if line.startswith("CASE "):
            line += f" host_s={now - last:.0f}"
            last = now
        if line.startswith("TEST PASS") or line.startswith("TEST FAIL"):
            verdicts.append(line)
        if VIP_ERROR in line:
            vip_errors.append(line)
        print(line, flush=True)
        if now - start > timeout_s:
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(p.pid)], capture_output=True)   # xsim and its kernel
            print(f"SIM RESULT: FAIL ({TOP}): no result after {timeout_s} s")
            return EXIT_FAIL
    p.wait()
    print(f"--- simulation: {time.time() - start:.0f} s, log {SIM_DIR / 'xsim.log'}")
    if vip_errors:
        print(f"SIM RESULT: FAIL ({TOP}): {len(vip_errors)} VIP errors, first: {vip_errors[0]}")
        return EXIT_FAIL
    if verdicts == ["TEST PASS"]:
        print(f"SIM RESULT: PASS ({TOP})")
        return EXIT_PASS
    print(f"SIM RESULT: FAIL ({TOP}): {verdicts[0] if verdicts else 'no TEST PASS / TEST FAIL line'}")
    return EXIT_FAIL


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reuse", action="store_true", help="keep the generated project (after a testbench change)")
    ap.add_argument("--run-only", action="store_true", help="only run the last elaborated simulation")
    ap.add_argument("--define", action="append", default=[], help="Verilog define, e.g. a PATRM_FAULT_* (repeatable)")
    ap.add_argument("--timeout", type=int, default=3600, help="seconds allowed for the simulation")
    args = ap.parse_args()

    bad = check_no_sv()                                  # D17
    if bad:
        print("SIM ERROR: D17 (no SystemVerilog): " + "; ".join(bad))
        return EXIT_TOOL_ERROR
    start = time.time()
    env = tool_env()
    if not (args.reuse or args.run_only):
        VIVADO_DIR.mkdir(parents=True, exist_ok=True)
        tcl = os.path.relpath(REPO_ROOT / "vivado" / "sim_system.tcl", VIVADO_DIR)
        step("sim_system_vivado", ["cmd", "/c", "vivado.bat", "-mode", "batch", "-nojournal", "-nolog",
                                   "-source", tcl], VIVADO_DIR, env)
    if not args.run_only:
        if not (SIM_DIR / "compile.bat").is_file():
            print(f"SIM ERROR: {SIM_DIR / 'compile.bat'} not found; run without --reuse")
            return EXIT_TOOL_ERROR
        problem, ours = check_plain_verilog()
        if problem:
            print("SIM ERROR: D17: " + problem)
            return EXIT_TOOL_ERROR
        print(f"--- D17: {ours} files of ours are compiled as plain Verilog", flush=True)
        run_bat("compile", env, args.define)
        run_bat("elaborate", env)
    rc = run_xsim(env, args.timeout)
    print(f"--- total: {time.time() - start:.0f} s")
    return rc


if __name__ == "__main__":
    sys.exit(main())
