"""Find AMD (Vivado/Vitis) and other command-line tools.

Shared by check_env.py and sim.py. A tool is first looked up on PATH; if it is
not there, the usual AMD install folders are searched. Nothing here changes PATH.
"""
import os
import re
import shutil
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
WANTED_VERSION = "2026.1"

# Install roots AMD uses by default, plus the one used on our machine (D:\AMD).
_BASES = ["AMD", "AMDDesignTools", "Xilinx"]
_DRIVES = ["C:\\", "D:\\", "E:\\"]


def _version_key(name):
    nums = re.findall(r"\d+", name)
    return tuple(int(n) for n in nums)


def _candidate_bin_dirs(product):
    """Yield <...>/<product>/bin folders, preferred version first."""
    env = {"Vivado": "XILINX_VIVADO", "Vitis": "XILINX_VITIS"}.get(product)
    if env and os.environ.get(env):
        yield Path(os.environ[env]) / "bin"
    for drive in _DRIVES:
        for base in _BASES:
            root = Path(drive) / base
            if not root.is_dir():
                continue
            try:
                subdirs = [d for d in root.iterdir() if d.is_dir()]
            except OSError:
                continue
            # Layout 2025+: <root>/<version>/<product>/bin
            versions = sorted((d for d in subdirs if re.match(r"^\d{4}\.\d", d.name)),
                              key=lambda d: (d.name != WANTED_VERSION, [-x for x in _version_key(d.name)]))
            for v in versions:
                yield v / product / "bin"
            # Older layout: <root>/<product>/<version>/bin
            pdir = root / product
            if pdir.is_dir():
                for v in sorted(pdir.iterdir(), key=lambda d: (d.name != WANTED_VERSION,
                                                               [-x for x in _version_key(d.name)])):
                    yield v / "bin"


# Which AMD product folders hold each tool.
_PRODUCTS = {
    "vivado": ["Vivado"],
    "xvlog": ["Vivado"],
    "xelab": ["Vivado"],
    "xsim": ["Vivado"],
    "xsdb": ["Vivado", "Vitis"],
    "vitis": ["Vitis"],
}


def find_tool(name):
    """Return (path, on_path). path is None if the tool was not found anywhere."""
    p = shutil.which(name)
    if p and "WindowsApps" not in p:
        return Path(p), True
    if name == "git":
        for c in [r"C:\Program Files\Git\cmd\git.exe", r"C:\Program Files (x86)\Git\cmd\git.exe"]:
            if Path(c).is_file():
                return Path(c), False
        return None, False
    for product in _PRODUCTS.get(name, []):
        for bindir in _candidate_bin_dirs(product):
            for ext in (".bat", ".exe", ""):
                c = bindir / (name + ext)
                if c.is_file():
                    return c, False
    return None, False


def require_tool(name):
    """Like find_tool, but raise a clear error if the tool is missing."""
    path, _ = find_tool(name)
    if path is None:
        raise FileNotFoundError(
            f"'{name}' not found on PATH or in the usual AMD install folders. "
            f"Run scripts/check_env.py for details.")
    return path


def find_arm_gcc():
    """The bare-metal ARM compiler that Vitis uses for the Cortex-A9. It is not inside the Vitis folder: PATH first,
    then the default folders of the Arm GNU Toolchain installer. Returns a Path or None."""
    found = shutil.which("arm-none-eabi-gcc")
    if found:
        return Path(found)
    for variable in ("ProgramFiles(x86)", "ProgramFiles"):
        base = os.environ.get(variable)
        if base:
            hits = sorted(Path(base).glob("Arm GNU Toolchain arm-none-eabi/*/bin/arm-none-eabi-gcc.exe"))
            if hits:
                return hits[-1]
    return None
