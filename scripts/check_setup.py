"""New-laptop setup check. Run it after a fresh clone or on a laptop not used for this project before.

    python scripts/check_setup.py

Prints one PASS/FAIL line per item and, under each FAIL, how to fix it. The steps are in README.md,
"New laptop setup". Exit code 0 only if every item passes. Takes about a minute: it starts Vivado once.

This script only looks. It writes nothing to the repo and installs nothing. Vivado runs inside a temporary
folder that is deleted afterwards, without a journal or log file. Like every Vivado start, this refreshes
Vivado's own cache file %APPDATA%\\Xilinx\\Vivado\\tclapp\\manifest.tcl.

The Digilent cable drivers are not checked here: they can only be tested with the board connected.
"""
import sys

sys.dont_write_bytecode = True  # importing our modules must not leave __pycache__ folders behind

import importlib  # noqa: E402
import importlib.metadata  # noqa: E402
import operator  # noqa: E402
import re  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402
from pathlib import Path  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from amd_tools import REPO_ROOT, WANTED_VERSION, find_tool  # noqa: E402
from check_no_sv import check as check_no_sv  # noqa: E402

sys.path.insert(0, str(REPO_ROOT))
from model import manifest  # noqa: E402

MIN_PYTHON = (3, 11)
PART = "xc7z020clg484-1"
BOARD_PART = "digilentinc.com:zedboard:part0:1.1"
AMD_TOOLS = ("vivado", "xvlog", "xelab", "xsim", "xsdb", "vitis")
QEMU_PLATFORMS = ("a9_linux", "a9_standalone")
VIVADO_TIMEOUT_S = 900

VEC_DIR = Path(manifest.DATA_DIR) / "vectors"
# Generated vectors that data/manifest.json does not list.
UNLISTED_VECTORS = ("axil_regs_spec.hex", "axil_regs_job.hex")
CASE_DIRS = ("coord_gen", "axi_rd", "out_path", "block_planner", "fetch_path", "patrm_top", "system")

IMPORT_NAMES = {"pillow": "PIL"}
COMPARE = {"==": operator.eq, "!=": operator.ne, ">=": operator.ge, "<=": operator.le,
           ">": operator.gt, "<": operator.lt}

VIVADO_PROBE = f"""\
puts "SETUP_VERSION [version -short]"
puts "SETUP_PART [llength [get_parts -quiet {PART}]]"
foreach b [get_board_parts -quiet *zed*] {{ puts "SETUP_BOARD $b" }}
if {{[catch {{
    read_verilog probe.v
    synth_design -top probe -part {PART} -mode out_of_context
}} msg]}} {{
    puts "SETUP_SYNTH_FAILED $msg"
}} else {{
    puts "SETUP_SYNTH_OK"
}}
exit 0
"""
PROBE_VERILOG = """\
module probe(input wire clk, input wire d, output reg q);
always @(posedge clk) q <= d;
endmodule
"""

_probe_result = None


def version_tuple(text, length=4):
    nums = [int(n) for n in re.findall(r"\d+", text)][:length]
    return tuple(nums + [0] * (length - len(nums)))


def install_dir(product_tool):
    """<install>/Vivado or <install>/Vitis for a tool in its bin folder, or None if it was not found."""
    path, _ = find_tool(product_tool)
    return path.parent.parent if path else None


def run_vivado_probe():
    """Start Vivado once in a temporary folder. Returns a dict; 'error' is set if it did not get through."""
    global _probe_result
    if _probe_result is not None:
        return _probe_result
    result = {"error": "", "version": "", "part": False, "boards": [], "synth_ok": False, "synth_error": ""}
    _probe_result = result
    vivado, _ = find_tool("vivado")
    if vivado is None:
        result["error"] = "Vivado was not found"
        return result
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as td:
        (Path(td) / "probe.tcl").write_text(VIVADO_PROBE)
        (Path(td) / "probe.v").write_text(PROBE_VERILOG)
        cmd = [str(vivado), "-mode", "batch", "-nojournal", "-nolog", "-notrace", "-source", "probe.tcl"]
        try:
            r = subprocess.run(cmd, cwd=td, capture_output=True, text=True, errors="replace",
                               timeout=VIVADO_TIMEOUT_S)
        except subprocess.TimeoutExpired:
            result["error"] = f"Vivado did not finish in {VIVADO_TIMEOUT_S} s"
            return result
        except OSError as e:
            result["error"] = f"Vivado could not be started: {e}"
            return result
    out = r.stdout + r.stderr
    errors = []
    for line in out.splitlines():
        if line.startswith("SETUP_VERSION "):
            result["version"] = line.split(None, 1)[1].strip()
        elif line.startswith("SETUP_PART "):
            result["part"] = line.split()[1] != "0"
        elif line.startswith("SETUP_BOARD "):
            result["boards"].append(line.split()[1])
        elif line.startswith("SETUP_SYNTH_OK"):
            result["synth_ok"] = True
        elif line.startswith("ERROR"):
            errors.append(line.strip())
    result["synth_error"] = errors[0] if errors else ""
    if not result["version"]:
        last = [ln.strip() for ln in out.splitlines() if ln.strip()]
        result["error"] = "Vivado did not start: " + (errors[0] if errors else last[-1] if last else f"exit code {r.returncode}")
    return result


def check_repo_path():
    if " " in str(REPO_ROOT):
        return False, f"path contains a space: {REPO_ROOT}", \
            "clone the repo again into a folder with no spaces in its path, for example C:\\work\\Bayer_PATRM_FPGA"
    return True, str(REPO_ROOT), ""


def read_requirements():
    """[(name, [(op, version), ...]), ...] from requirements.txt."""
    reqs = []
    for line in (REPO_ROOT / "requirements.txt").read_text().splitlines():
        line = line.split("#")[0].strip()
        if line:
            name = re.match(r"[A-Za-z0-9_.-]+", line).group(0)
            reqs.append((name, re.findall(r"(==|!=|>=|<=|>|<)\s*([0-9][0-9.]*)", line[len(name):])))
    return reqs


def check_python_packages():
    py = ".".join(str(n) for n in sys.version_info[:3])
    parts, problems = [f"Python {py}"], []
    if sys.version_info < MIN_PYTHON:
        problems.append(f"Python {py} is older than {MIN_PYTHON[0]}.{MIN_PYTHON[1]}")
    for name, specs in read_requirements():
        wanted = ",".join(op + v for op, v in specs)
        try:
            have = importlib.metadata.version(name)
            importlib.import_module(IMPORT_NAMES.get(name.lower(), name.lower()))
        except (importlib.metadata.PackageNotFoundError, ImportError) as e:
            problems.append(f"{name} not usable ({e})")
            continue
        parts.append(f"{name} {have}")
        if not all(COMPARE[op](version_tuple(have), version_tuple(v)) for op, v in specs):
            problems.append(f"{name} {have} does not meet {wanted}")
    if problems:
        return False, "; ".join(problems), \
            "python -m pip install --user -r requirements.txt  (if pip finds no matching version, " \
            "this Python is too old for it: install a newer Python from python.org)"
    return True, ", ".join(parts), ""


def check_amd_tools():
    missing, wrong = [], []
    for tool in AMD_TOOLS:
        path, _ = find_tool(tool)
        if path is None:
            missing.append(tool)
        elif WANTED_VERSION not in path.parts:
            wrong.append(f"{tool} ({path})")
    if missing or wrong:
        detail = "; ".join(filter(None, [
            "not found: " + ", ".join(missing) if missing else "",
            f"not version {WANTED_VERSION}: " + ", ".join(wrong) if wrong else ""]))
        return False, detail, f"install Vivado and Vitis {WANTED_VERSION} under \\AMD, \\AMDDesignTools or " \
            "\\Xilinx on C:, D: or E: (README, New laptop setup, step 3)"
    return True, f"{WANTED_VERSION} at {install_dir('vivado').parent}", ""


def check_licence():
    p = run_vivado_probe()
    fix = "run vlm (Vivado License Manager, in <install>\\Vivado\\bin), load a valid licence file, " \
          "and check again (README, New laptop setup, step 4)"
    if p["error"]:
        return False, p["error"], fix
    if not p["part"]:
        return False, f"Vivado {p['version']} started but has no device {PART}", \
            "add Zynq-7000 device support with the AMD installer (Add Design Tools or Devices)"
    if not p["synth_ok"]:
        return False, f"test synthesis for {PART} failed: {p['synth_error'] or 'no error text'}", fix
    return True, f"Vivado {p['version']} started and synthesised a test module for {PART}", ""


def check_board_files():
    p = run_vivado_probe()
    if p["error"]:
        return False, f"not checked: {p['error']}", "fix the items above, then check again"
    if BOARD_PART in p["boards"]:
        return True, f"get_board_parts finds {BOARD_PART}", ""
    target = install_dir("vivado") / "data" / "boards" / "board_files" / "zedboard" / "1.3"
    found = ", ".join(p["boards"]) or "no *zed* board parts"
    return False, f"{BOARD_PART} not found ({found})", \
        f"copy the Digilent zedboard 1.3 files to {target} (README, New laptop setup, step 5)"


def check_qemu_folders():
    vitis = install_dir("vitis")
    if vitis is None:
        return False, "not checked: Vitis was not found", "fix the vivado/vitis item first"
    base = vitis / "data" / "emulation" / "platforms" / "zynq" / "sw"
    folders = [base / name / "qemu" for name in QEMU_PLATFORMS]
    missing = [f for f in folders if not f.is_dir()]
    if not missing:
        return True, f"both exist under {base}", ""
    quoted = ",".join(f'"{f}"' for f in missing)
    return False, "missing: " + ", ".join(str(f) for f in missing), \
        f"in an Administrator PowerShell: New-Item -ItemType Directory -Force {quoted}"


def referenced_files(cases):
    """File names on the non-comment lines of a cases.txt."""
    for line in cases.read_text().splitlines():
        if not line.startswith("#"):
            yield from (t for t in line.split() if t.endswith((".txt", ".hex")))


def check_vectors():
    fix = "run the generator commands of README, New laptop setup, step 8, in order"
    m = manifest.load()
    entries = m.get("images", []) + m.get("vectors", [])
    if not entries:
        return False, "data/manifest.json is missing or empty", "restore it: git checkout -- data/manifest.json"
    missing, differ = [], []
    for e in entries:
        p = Path(manifest.DATA_DIR) / e["file"]
        if not p.is_file():
            missing.append(e["file"])
        elif manifest.sha256_file(p) != e["sha256"]:
            differ.append(e["file"])
    extra = 0
    for name in UNLISTED_VECTORS:
        extra += 1
        if not (VEC_DIR / name).is_file():
            missing.append(f"vectors/{name}")
    for sub in CASE_DIRS:
        cases = VEC_DIR / sub / "cases.txt"
        extra += 1
        if not cases.is_file():
            missing.append(f"vectors/{sub}/cases.txt")
            continue
        for name in set(referenced_files(cases)):
            extra += 1
            if not ((VEC_DIR / name).is_file() or (VEC_DIR / sub / name).is_file()):
                missing.append(f"vectors/{sub}: {name}")
    if missing or differ:
        first = (missing + differ)[0]
        return False, f"{len(missing)} missing, {len(differ)} differ from the manifest (first: {first})", fix
    return True, f"{len(entries)} files match data/manifest.json, {extra} other generated files present", ""


def check_systemverilog():
    problems = check_no_sv()
    if problems:
        return False, f"{len(problems)} problem(s), first: {problems[0]}", \
            "remove the file or flag (D17); python scripts/check_no_sv.py lists every problem"
    return True, "check_no_sv passes", ""


ITEMS = [
    ("repo path", check_repo_path),
    ("python packages", check_python_packages),
    ("vivado/vitis", check_amd_tools),
    ("licence", check_licence),
    ("board files", check_board_files),
    ("vitis qemu folders", check_qemu_folders),
    ("vectors", check_vectors),
    ("no systemverilog", check_systemverilog),
]


def main():
    print("Bayer-PATRM new-laptop setup check")
    failed = []
    for name, check in ITEMS:
        try:
            ok, detail, fix = check()
        except Exception as e:  # a broken item must show up as a FAIL and not hide the items after it
            ok, detail, fix = False, f"check crashed: {type(e).__name__}: {e}", "see README, New laptop setup"
        print(f"[{'PASS' if ok else 'FAIL'}] {name:<18} {detail}", flush=True)
        if not ok:
            failed.append(name)
            print(f"       fix: {fix}", flush=True)
    if failed:
        print(f"RESULT: FAIL ({len(failed)} of {len(ITEMS)}: {', '.join(failed)})")
        return 1
    print(f"RESULT: PASS (all {len(ITEMS)} items)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
