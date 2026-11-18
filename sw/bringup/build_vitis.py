"""Build the bring-up application with the Vitis Python API (step 4.1). No XSCT.

Run from anywhere, after vivado/build.tcl has written results/hw/patrm_gray.xsa:
    vitis -s sw/bringup/build_vitis.py

Creates a new workspace in build/vitis/bringup (an old one is deleted): a standalone platform for ps7_cortexa9_0 from
the XSA and the application from sw/bringup/main.c + sw/include/patrm_regs.h. Copies the ELF to results/hw/bringup.elf.
No FSBL is built: the board is started over JTAG (scripts/board/load_run.tcl uses ps7_init.tcl).
`vitis -s` can exit with 0 after a failure: the build succeeded only if the last line is BRINGUP BUILD OK.
"""
import os
import shutil
import stat
import sys
from pathlib import Path

import vitis

# Platform creation runs sdtgen, which is in Vivado's bin folder and is not on the PATH that vitis sets up.
os.environ["PATH"] = str(Path(os.environ["XILINX_VIVADO"]) / "bin") + os.pathsep + os.environ["PATH"]

REPO = Path(__file__).resolve().parents[2]
XSA = REPO / "results" / "hw" / "patrm_gray.xsa"
WORKSPACE = REPO / "build" / "vitis" / "bringup"
ELF_OUT = REPO / "results" / "hw" / "bringup.elf"
PLATFORM = "patrm_gray_plat"
DOMAIN = "standalone_a9_0"
APP = "bringup"


def remove_read_only(func, path, _exc):
    """Vitis marks some workspace files read-only; Windows then refuses to delete them."""
    os.chmod(path, stat.S_IWRITE)
    func(path)


def main():
    if not XSA.is_file():
        print(f"BRINGUP BUILD FAILED: {XSA} not found; run vivado/build.tcl first")
        return 1
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
        app.import_files(from_loc=str(REPO / "sw" / "bringup"), files=["main.c"], dest_dir_in_cmp="src")
        app.import_files(from_loc=str(REPO / "sw" / "include"), files=["patrm_regs.h"], dest_dir_in_cmp="src")
        app.build()
    finally:
        vitis.dispose()

    elfs = sorted((WORKSPACE / APP).rglob(f"{APP}.elf"))
    if not elfs:
        print(f"BRINGUP BUILD FAILED: no {APP}.elf under {WORKSPACE / APP}")
        return 1
    shutil.copyfile(elfs[0], ELF_OUT)
    print(f"BRINGUP BUILD OK: {ELF_OUT} ({ELF_OUT.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
