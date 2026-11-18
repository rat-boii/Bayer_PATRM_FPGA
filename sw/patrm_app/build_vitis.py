"""Build the PATRM test application with the Vitis Python API (step 4.2). No XSCT.

Run from anywhere, after vivado/build.tcl has written results/hw/patrm_gray.xsa:
    vitis -s sw/patrm_app/build_vitis.py

Creates a new workspace in build/vitis/patrm_app (an old one is deleted): a standalone platform for ps7_cortexa9_0 from
the XSA, and the application from sw/patrm_app, sw/patrm_drv and sw/include. Our sources are compiled with
-Wall -Wextra -Werror. Copies the ELF to results/hw/patrm_app.elf.

Checks after the build: every source of ours was compiled with those flags, the build log has no compiler warning, and
the program stays below 0x0F00_0000 (spec/memory_map.md section 1).
`vitis -s` can exit with 0 after a failure: the build succeeded only if the last line is PATRM_APP BUILD OK.
"""
import json
import os
import re
import shutil
import stat
import struct
import sys
from pathlib import Path

import vitis

# Platform creation runs sdtgen, which is in Vivado's bin folder and is not on the PATH that vitis sets up.
os.environ["PATH"] = str(Path(os.environ["XILINX_VIVADO"]) / "bin") + os.pathsep + os.environ["PATH"]

REPO = Path(__file__).resolve().parents[2]
XSA = REPO / "results" / "hw" / "patrm_gray.xsa"
WORKSPACE = REPO / "build" / "vitis" / "patrm_app"
ELF_OUT = REPO / "results" / "hw" / "patrm_app.elf"
PLATFORM = "patrm_gray_plat"
DOMAIN = "standalone_a9_0"
APP = "patrm_app"
PROGRAM_END = 0x0F00_0000
SOURCES = [("sw/patrm_app", "main.c"), ("sw/patrm_drv", "patrm_drv.c"), ("sw/patrm_drv", "patrm_drv.h"),
           ("sw/include", "patrm_regs.h"), ("sw/include", "patrm_defs.h"), ("sw/include", "patrm_job.h")]
C_FILES = ("main.c", "patrm_drv.c")
REQUIRED_FLAGS = ("-Wall", "-Wextra", "-Werror")
SETTINGS = {"USER_COMPILE_WARNINGS_ALL": "-Wall", "USER_COMPILE_WARNINGS_EXTRA": "-Wextra",
            "USER_COMPILE_WARNINGS_AS_ERRORS": "-Werror", "USER_COMPILE_OPTIMIZATION_LEVEL": "-O2",
            "USER_COMPILE_OTHER_FLAGS": "-std=gnu11"}


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
    warnings = [ln for ln in log.read_text(errors="replace").splitlines() if re.search(r"\bwarning\b", ln, re.I)]
    if warnings:
        return f"{len(warnings)} warning lines in {log}, first: {warnings[0][:160]}"
    return ""


def main():
    if not XSA.is_file():
        return fail(f"{XSA} not found; run vivado/build.tcl first")
    ELF_OUT.unlink(missing_ok=True)                 # a failed build must not leave an old ELF behind
    if WORKSPACE.exists():
        shutil.rmtree(WORKSPACE, onexc=remove_read_only)
    WORKSPACE.mkdir(parents=True)

    client = vitis.create_client()
    try:
        client.set_workspace(path=str(WORKSPACE))
        platform = client.create_platform_component(
            name=PLATFORM, hw_design=str(XSA), os="standalone", cpu="ps7_cortexa9_0",
            domain_name=DOMAIN, no_boot_bsp=True)
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
        app.build()
    finally:
        vitis.dispose()

    elfs = sorted((WORKSPACE / APP).rglob(f"{APP}.elf"))
    if not elfs:
        return fail(f"no {APP}.elf under {WORKSPACE / APP}")
    problem = check_build()
    if problem:
        return fail(problem)
    end = load_end(elfs[0])
    if not 0 < end <= PROGRAM_END:
        return fail(f"program ends at 0x{end:08X}, it must stay below 0x{PROGRAM_END:08X}")
    shutil.copyfile(elfs[0], ELF_OUT)
    print(f"flags: {' '.join(REQUIRED_FLAGS)} on {', '.join(C_FILES)}; 0 warnings; program ends at 0x{end:08X}")
    print(f"PATRM_APP BUILD OK: {ELF_OUT} ({ELF_OUT.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
