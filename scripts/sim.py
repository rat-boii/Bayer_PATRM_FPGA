"""Reusable xsim runner: xvlog -> xelab -> xsim, batch mode by default.

Works inside build/sim/<top>/ (wiped at the start of each run). Logs are saved
there (xvlog.log, xelab.log, xsim.log). Exit code 0 only if the simulation log
contains a line starting with "TEST PASS" and no "TEST FAIL" line.

Examples:
  python scripts/sim.py --top tb_counter4 tb/smoke/counter4.v tb/smoke/tb_counter4.v
  python scripts/sim.py --top tb_counter4 -f tb/smoke/files.f --define BREAK_EXPECTED
  python scripts/sim.py --top tb_counter4 <sources> --gui
File lists: one path per line, relative to the list file; '#' and '//' start comments.
"""
import argparse
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from amd_tools import REPO_ROOT, require_tool  # noqa: E402

EXIT_PASS, EXIT_FAIL, EXIT_TOOL_ERROR = 0, 1, 2


def read_filelist(path):
    path = Path(path).resolve()
    files = []
    for line in path.read_text().splitlines():
        line = line.split("//")[0].split("#")[0].strip()
        if line:
            files.append((path.parent / line).resolve())
    return files


def run_step(name, cmd, cwd):
    print(f"--- {name}: {' '.join(str(c) for c in cmd)}", flush=True)
    r = subprocess.run([str(c) for c in cmd], cwd=cwd)
    if r.returncode != 0:
        print(f"SIM ERROR: {name} failed (exit {r.returncode}); see {cwd / (name + '.log')}")
        sys.exit(EXIT_TOOL_ERROR)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--top", required=True, help="top-level testbench module")
    ap.add_argument("sources", nargs="*", help="Verilog source files")
    ap.add_argument("-f", "--filelist", action="append", default=[], help="file with one source per line")
    ap.add_argument("--define", action="append", default=[], help="NAME or NAME=VALUE (repeatable)")
    ap.add_argument("--incdir", action="append", default=[], help="include directory (repeatable)")
    ap.add_argument("--gui", action="store_true", help="open the xsim GUI instead of batch mode")
    args = ap.parse_args()

    sources = [Path(s).resolve() for s in args.sources]
    for fl in args.filelist:
        sources += read_filelist(fl)
    if not sources:
        ap.error("no source files given")
    missing = [s for s in sources if not s.is_file()]
    if missing:
        print("SIM ERROR: missing source files: " + ", ".join(map(str, missing)))
        return EXIT_TOOL_ERROR

    xvlog, xelab, xsim = (require_tool(t) for t in ("xvlog", "xelab", "xsim"))
    work = REPO_ROOT / "build" / "sim" / args.top
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)

    cmd = [xvlog, "--log", "xvlog.log"]
    for d in args.define:
        cmd += ["-d", d]
    for i in args.incdir:
        cmd += ["-i", Path(i).resolve()]
    run_step("xvlog", cmd + sources, work)

    snap = args.top + "_snap"
    debug = "typical" if args.gui else "off"
    run_step("xelab", [xelab, "--log", "xelab.log", "--debug", debug, "--timescale", "1ns/1ps",
                       "-s", snap, "work." + args.top], work)

    if args.gui:
        subprocess.run([str(xsim), snap, "--gui", "--log", "xsim.log"], cwd=work)
    else:
        subprocess.run([str(xsim), snap, "--runall", "--log", "xsim.log"], cwd=work)

    log = work / "xsim.log"
    text = log.read_text(errors="replace") if log.is_file() else ""
    lines = [l.strip() for l in text.splitlines()]
    passed = any(l.startswith("TEST PASS") for l in lines)
    failed = [l for l in lines if l.startswith("TEST FAIL")]
    print(f"--- log: {log}")
    if passed and not failed:
        print(f"SIM RESULT: PASS ({args.top})")
        return EXIT_PASS
    reason = failed[0] if failed else "no 'TEST PASS' line in the log"
    print(f"SIM RESULT: FAIL ({args.top}): {reason}")
    return EXIT_FAIL


if __name__ == "__main__":
    sys.exit(main())
