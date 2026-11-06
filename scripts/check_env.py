"""Toolchain check for the Bayer-PATRM project (step 0.1).

Prints version, path and PASS/FAIL for each tool. A tool that is not on PATH
but is found in an AMD install folder still passes (our scripts find it the same
way), and the folder to add to PATH is printed. This script never changes PATH.

Usage: python scripts/check_env.py      (exit code 0 only if every item passes)
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from amd_tools import find_tool  # noqa: E402

TIMEOUT_S = 180
results = []  # (name, ok)


def report(name, ok, version, where, note=""):
    results.append((name, ok))
    status = "PASS" if ok else "FAIL"
    print(f"[{status}] {name:<7} {version}")
    if where:
        print(f"          path: {where}")
    if note:
        print(f"          note: {note}")


def run(cmd, **kw):
    """Run a command and return its combined output (stripped), or an error text."""
    try:
        r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True,
                           timeout=TIMEOUT_S, **kw)
        return r.returncode, (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return -1, f"timed out after {TIMEOUT_S} s"
    except OSError as e:
        return -1, str(e)


def first_line_with(text, words):
    for line in text.splitlines():
        if line.lstrip().startswith("# "):  # Vivado echoes sourced Tcl lines with '# '
            continue
        if any(w.lower() in line.lower() for w in words):
            return line.strip()
    return text.splitlines()[0].strip() if text else "(no output)"


def check_python():
    v = sys.version_info
    ok = v >= (3, 10)
    note = ""
    on_path = shutil.which("python")
    if on_path and "WindowsApps" in on_path:
        note = ("'python' on PATH is the Microsoft Store stub (" + on_path + "). Disable the python.exe/"
                "python3.exe App execution aliases, or move " + str(Path(sys.executable).parent) +
                " before WindowsApps in PATH, or use 'py -3'.")
    report("python", ok, f"{v.major}.{v.minor}.{v.micro} (need >= 3.10)", sys.executable, note)


def check_module(name, import_name):
    try:
        mod = __import__(import_name)
        report(name, True, getattr(mod, "__version__", "?"), getattr(mod, "__file__", ""))
    except ImportError as e:
        report(name, False, f"not importable ({e})", "",
               "run: python -m pip install --user -r requirements.txt")


def check_tool(name, args, version_words, script=None, script_name="v.tcl", must_contain=None):
    """Run the tool (optionally on a small script written to a temp dir) and expect exit code 0.

    {script} in args is replaced by the script path. The temp dir is the working
    directory, so .jou/.log files never land in the repo.
    """
    path, on_path = find_tool(name)
    if path is None:
        report(name, False, "not found", "",
               "not on PATH and not in C:/D:/E: \\AMD, \\AMDDesignTools or \\Xilinx")
        return
    with tempfile.TemporaryDirectory() as td:
        cmd = [path]
        if script is not None:
            sp = Path(td) / script_name
            sp.write_text(script)
            cmd += [str(sp) if a == "{script}" else a for a in args]
        else:
            cmd += args
        rc, out = run(cmd, cwd=td)
    ok = rc == 0 and (must_contain is None or must_contain in out)
    version = first_line_with(out, version_words) if ok else f"run failed (rc={rc}): {out[-400:]}"
    if on_path:
        note = ""
    elif name == "git":
        note = f"not on PATH in this shell (open a new terminal after installing Git); add to PATH: {path.parent}"
    else:
        note = f"not on PATH; found in an AMD folder. To use it directly, add to PATH: {path.parent}"
    report(name, ok, version, path, note)


def main():
    print("Bayer-PATRM toolchain check")
    print("=" * 60)
    check_python()
    check_module("numpy", "numpy")
    check_module("Pillow", "PIL")
    check_tool("git", ["--version"], ["git version"])
    # 'vivado -version' and 'vitis --version' print the banner but exit 1 in 2026.1,
    # so both are checked with a real batch run instead (this also proves the license works).
    check_tool("vivado", ["-mode", "batch", "-nojournal", "-nolog", "-source", "{script}"],
               ["vivado version"], script='puts "VIVADO VERSION [version -short]"\nexit 0\n',
               must_contain="VIVADO VERSION")
    check_tool("xvlog", ["--version"], ["vivado simulator", "xvlog"])
    check_tool("xelab", ["--version"], ["vivado simulator", "xelab"])
    check_tool("xsim", ["--version"], ["vivado simulator", "xsim"])
    check_tool("xsdb", ["{script}"], ["xsdb"], script='puts "xsdb Tcl [info patchlevel] OK"\nexit\n',
               must_contain="OK")
    check_tool("vitis", ["-s", "{script}"], ["vitis v"], script_name="v.py",
               script="import vitis\nprint('vitis python API OK')\n", must_contain="vitis python API OK")
    print("=" * 60)
    failed = [n for n, ok in results if not ok]
    if failed:
        print("RESULT: FAIL (" + ", ".join(failed) + ")")
        return 1
    print("RESULT: PASS (all items)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
