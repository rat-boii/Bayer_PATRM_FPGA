"""Build the PATRM test application with the Vitis Python API (step 4.2). No XSCT.

Run from anywhere, after vivado/build.tcl has written results/hw/patrm_gray.xsa:
    vitis -s sw/patrm_app/build_vitis.py

Creates a new workspace in build/vitis/patrm_app (an old one is deleted): a standalone platform for ps7_cortexa9_0 from
the XSA, and the application from sw/patrm_app, sw/patrm_drv and sw/include. Our sources are compiled with
-Wall -Wextra -Werror. Copies the ELF to results/hw/patrm_app.elf.

Checks after the build: every source of ours was compiled with those flags, the build log has no compiler warning, and
the program stays below 0x0F00_0000 (spec/memory_map.md section 1).

Optimisation level (step 4.4, ARM software baseline at -O2 and -O3): environment variable PATRM_APP_OPT = O2 (default)
or O3. O2 builds results/hw/patrm_app.elf in build/vitis/patrm_app; O3 builds results/hw/patrm_app_o3.elf in
build/vitis/patrm_app_o3. The whole application uses that level; the program prints it on the UART at start.
`vitis -s` can exit with 0 after a failure: the build succeeded only if the last line is PATRM_APP BUILD OK.
"""
import json
import io
from contextlib import redirect_stdout, redirect_stderr
import os
import re
import shutil
import stat
import struct
import sys
from pathlib import Path

import vitis

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from amd_tools import irq_saves_vfp          # noqa: E402

# Step 5.3: PATRM_VARIANT=bayer_a, PATRM_REV=c|d selects separate XSA/workspace/ELF.
# The default gray build and its verified ELF location are unchanged.

# Platform creation runs sdtgen, which is in Vivado's bin folder and is not on the PATH that vitis sets up.
os.environ["PATH"] = str(Path(os.environ["XILINX_VIVADO"]) / "bin") + os.pathsep + os.environ["PATH"]

REPO = Path(__file__).resolve().parents[2]
# XSA: environment variable PATRM_XSA if set; else results/hw/patrm_gray.xsa (from vivado/build.tcl); else the
# verified Rev D bundle that is tracked in git (results/hw/rev D/patrm_gray.xsa), so a fresh clone can build.
VARIANT = os.environ.get("PATRM_VARIANT", "gray")
REV = os.environ.get("PATRM_REV", "c").lower()
if VARIANT not in ("gray", "bayer_a") or REV not in ("c", "d"):
    raise ValueError("PATRM_VARIANT must be gray|bayer_a; PATRM_REV must be c|d")
ARTIFACT_DIR = REPO / "results" / "hw"
if VARIANT == "bayer_a":
    ARTIFACT_DIR = ARTIFACT_DIR / VARIANT / f"rev_{REV}"
XSA = Path(os.environ["PATRM_XSA"]) if os.environ.get("PATRM_XSA") else ARTIFACT_DIR / f"patrm_{VARIANT}.xsa"
if VARIANT == "gray" and not os.environ.get("PATRM_XSA") and (REV == "d" or not XSA.is_file()):
    XSA = REPO / "results" / "hw" / "rev D" / "patrm_gray.xsa"


def usable_xsa(xsa):
    """Vitis 2026.1 fails to generate the system device tree from an XSA whose path contains a space
    ("Valid OSes are '[]'", found 2026-11-22 with results/hw/rev D): use a copy in build/xsa/ then."""
    if " " not in str(xsa) or not xsa.is_file():
        return xsa
    dst = REPO / "build" / "xsa" / xsa.name
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(xsa, dst)
    print(f"XSA path contains a space; using a copy: {dst}")
    return dst
OPT = os.environ.get("PATRM_APP_OPT", "O2").upper()
if OPT not in ("O2", "O3"):
    print(f"PATRM_APP BUILD FAILED: PATRM_APP_OPT must be O2 or O3, not {OPT}")
    sys.exit(1)
SUFFIX = "" if OPT == "O2" else "_o3"
BUILD_SUFFIX = "" if VARIANT == "gray" else f"_{VARIANT}_rev{REV}"
WORKSPACE = REPO / "build" / "vitis" / f"patrm_app{SUFFIX}{BUILD_SUFFIX}"
ELF_OUT = ARTIFACT_DIR / f"patrm_app{SUFFIX}.elf"
PLATFORM = f"patrm_{VARIANT}_plat"
DOMAIN = "standalone_a9_0"
APP = "patrm_app"
PROGRAM_END = 0x0F00_0000
SOURCES = [("sw/patrm_app", "main.c"), ("sw/patrm_drv", "patrm_drv.c"), ("sw/patrm_drv", "patrm_drv.h"),
           ("sw/patrm_sw", "patrm_sw.c"), ("sw/patrm_sw", "patrm_sw.h"),
           ("sw/patrm_job", "patrm_jobrun.c"), ("sw/patrm_job", "patrm_jobrun.h"),
           ("sw/include", "patrm_regs.h"), ("sw/include", "patrm_defs.h"), ("sw/include", "patrm_job.h")]
C_FILES = ("main.c", "patrm_drv.c", "patrm_sw.c", "patrm_jobrun.c")
REQUIRED_FLAGS = ("-Wall", "-Wextra", "-Werror", f"-{OPT}")
SETTINGS = {"USER_COMPILE_WARNINGS_ALL": "-Wall", "USER_COMPILE_WARNINGS_EXTRA": "-Wextra",
            "USER_COMPILE_WARNINGS_AS_ERRORS": "-Werror", "USER_COMPILE_OPTIMIZATION_LEVEL": f"-{OPT}",
            "USER_COMPILE_OTHER_FLAGS": f"-std=gnu11 -DPATRM_APP_OPT_LEVEL={OPT[1]}"}


def remove_read_only(func, path, _exc):
    """Vitis marks some workspace files read-only; Windows then refuses to delete them."""
    os.chmod(path, stat.S_IWRITE)
    func(path)


def fail(msg):
    print(f"PATRM_APP BUILD FAILED: {msg}")
    return 1


def load_end(elf):
    """Highest address used by the loadable segments of a 32-bit little-endian ELF."""
    data = elf.read_bytes()
    phoff, = struct.unpack_from("<I", data, 28)
    phentsize, phnum = struct.unpack_from("<HH", data, 42)
    end = 0
    for i in range(phnum):
        p_type, _off, _vaddr, paddr, _filesz, memsz = struct.unpack_from("<6I", data, phoff + i * phentsize)
        if p_type == 1 and memsz:
            end = max(end, paddr + memsz)
    return end


def check_build():
    build_dir = WORKSPACE / APP / "build"
    commands = json.loads((build_dir / "compile_commands.json").read_text())
    for name in C_FILES:
        entry = [c for c in commands if Path(c["file"]).name == name]
        if not entry:
            return f"{name} is not in compile_commands.json"
        words = entry[0].get("command", "").split()
        missing = [flag for flag in REQUIRED_FLAGS if flag not in words]
        if missing:
            return f"{name} was compiled without {' '.join(missing)}"
    log = build_dir / "build.log"
    if not log.is_file():
        return f"{log} not found"
    build_text = log.read_text(errors="replace")
    if not build_text.strip():
        return f"{log} is empty"
    warnings = [ln for ln in build_text.splitlines() if re.search(r"\bwarning\b", ln, re.I)]
    if warnings:
        return f"{len(warnings)} warning lines in {log}, first: {warnings[0][:160]}"
    return ""


def main():
    if not XSA.is_file():
        return fail(f"{XSA} not found; run vivado/build.tcl or set PATRM_XSA")
    ELF_OUT.parent.mkdir(parents=True, exist_ok=True)
    ELF_OUT.unlink(missing_ok=True)                 # a failed build must not leave an old ELF behind
    if WORKSPACE.exists():
        # Verify the exact generated workspace before recursive removal on Windows.
        if WORKSPACE.resolve().parent != (REPO / "build" / "vitis").resolve():
            return fail(f"refusing to remove workspace outside build/vitis: {WORKSPACE}")
        shutil.rmtree(WORKSPACE, onexc=remove_read_only)
    WORKSPACE.mkdir(parents=True)

    client = vitis.create_client()
    try:
        client.set_workspace(path=str(WORKSPACE))
        platform = client.create_platform_component(
            name=PLATFORM, hw_design=str(usable_xsa(XSA)), os="standalone", cpu="ps7_cortexa9_0",
            domain_name=DOMAIN, no_boot_bsp=True)
        # Step 10.2: the IRQ entry must save the VFP registers (amd_tools.irq_saves_vfp; Vitis 2026.1's CMake BSP does
        # not define FPU_HARD_FLOAT_ABI_ENABLED). Our engine interrupt handler uses no VFP register, so the step 4.x
        # results were not affected, but any handler that does (memcpy) would corrupt the interrupted code.
        domain = platform.get_domain(DOMAIN)
        flags = domain.get_config(option="proc", param="proc_extra_compiler_flags")["value"]
        if "-DFPU_HARD_FLOAT_ABI_ENABLED=1" not in flags:
            domain.set_config(option="proc", param="proc_extra_compiler_flags",
                              value=f"{flags} -DFPU_HARD_FLOAT_ABI_ENABLED=1")
        platform.build()

        xpfm = client.find_platform_in_repos(PLATFORM)
        app = client.create_app_component(name=APP, platform=xpfm, domain=DOMAIN, template="empty_application")
        for folder, name in SOURCES:
            app.import_files(from_loc=str(REPO / folder), files=[name], dest_dir_in_cmp="src")
        for key, value in SETTINGS.items():
            app.set_app_config(key=key, values=value)
        # AMD's linker script puts code and data in one load segment. Bare metal has no loader that uses segment
        # permissions (boot.S and the translation table set them), so only this one linker warning is switched off.
        app.set_app_config(key="USER_LINK_OTHER_FLAGS", values="-Wl,--no-warn-rwx-segments")
        # 2025.2 streams the application log over the Python API but creates no build.log.
        # Save that exact stream ourselves on every version; keep BSP diagnostics separate.
        captured = io.StringIO()
        try:
            with redirect_stdout(captured), redirect_stderr(captured):
                app.build()
        finally:
            log = WORKSPACE / APP / "build" / "build.log"
            log.parent.mkdir(parents=True, exist_ok=True)
            log.write_text(captured.getvalue(), encoding="utf-8")
            print(captured.getvalue(), end="")
    finally:
        vitis.dispose()

    elfs = sorted((WORKSPACE / APP).rglob(f"{APP}.elf"))
    if not elfs:
        return fail(f"no {APP}.elf under {WORKSPACE / APP}")
    problem = check_build()
    if problem:
        return fail(problem)
    ok, text = irq_saves_vfp(elfs[0])
    print(text)
    if not ok:
        return fail(text)
    end = load_end(elfs[0])
    if not 0 < end <= PROGRAM_END:
        return fail(f"program ends at 0x{end:08X}, it must stay below 0x{PROGRAM_END:08X}")
    shutil.copyfile(elfs[0], ELF_OUT)
    print(f"flags: {' '.join(REQUIRED_FLAGS)} -DPATRM_APP_OPT_LEVEL={OPT[1]} on {', '.join(C_FILES)}; 0 warnings; "
          f"program ends at 0x{end:08X}")
    print(f"PATRM_APP BUILD OK: {ELF_OUT} ({ELF_OUT.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
