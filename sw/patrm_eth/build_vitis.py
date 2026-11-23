"""Step 10.0: build AMD's lwIP echo server for the ZedBoard with the Vitis Python API (no XSCT).

    vitis -s sw/patrm_eth/build_vitis.py

Feasibility only: shows that Vitis 2026.1 ships lwIP (lwip220, raw API, bare metal) and the lwip_echo_server template,
and that they build for ps7_cortexa9_0 from our XSA with -Wall -Wextra -Werror (as sw/patrm_app/build_vitis.py).
Our own Ethernet application (steps 10.1/10.2) will replace the template sources later.

Creates a new workspace in build/vitis/patrm_eth (an old one is deleted): a standalone platform from the XSA with
lwip220 added to the BSP (settings from the template's own lwip_echo_server.yaml), then the app from the template.
Checks: every template .c file compiled with the required flags, no compiler warning in the build log, program below
0x0F00_0000 (spec/memory_map.md section 1). Copies the ELF to results/hw/patrm_eth_echo.elf (not tracked: not yet run
on a board). `vitis -s` can exit 0 after a failure: the build succeeded only if the last line is PATRM_ETH BUILD OK.

XSA: environment variable PATRM_XSA if set; else results/hw/patrm_gray.xsa; else the tracked Rev D bundle.
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

os.environ["PATH"] = str(Path(os.environ["XILINX_VIVADO"]) / "bin") + os.pathsep + os.environ["PATH"]

REPO = Path(__file__).resolve().parents[2]
XSA = Path(os.environ["PATRM_XSA"]) if os.environ.get("PATRM_XSA") else REPO / "results" / "hw" / "patrm_gray.xsa"
if not os.environ.get("PATRM_XSA") and not XSA.is_file():
    XSA = REPO / "results" / "hw" / "rev D" / "patrm_gray.xsa"
WORKSPACE = REPO / "build" / "vitis" / "patrm_eth"
ELF_OUT = REPO / "results" / "hw" / "patrm_eth_echo.elf"
PLATFORM = "patrm_eth_plat"
DOMAIN = "standalone_a9_0"
APP = "patrm_eth_echo"
TEMPLATE = "lwip_echo_server"
PROGRAM_END = 0x0F00_0000
REQUIRED_FLAGS = ("-Wall", "-Wextra", "-Werror", "-O2")
SETTINGS = {"USER_COMPILE_WARNINGS_ALL": "-Wall", "USER_COMPILE_WARNINGS_EXTRA": "-Wextra",
            "USER_COMPILE_WARNINGS_AS_ERRORS": "-Werror", "USER_COMPILE_OPTIMIZATION_LEVEL": "-O2"}
# BSP library settings, copied from the template's data/lwip_echo_server.yaml (depends_libs) in Vitis 2026.1.
LIBS = {"lwip220": {"lwip220_api_mode": "RAW_API", "lwip220_dhcp": "true",
                    "lwip220_lwip_dhcp_does_acd_check": "true", "lwip220_ipv6_enable": "false",
                    "lwip220_pbuf_pool_size": "2048"},
        "xiltimer": {"XILTIMER_en_interval_timer": "true"}}


def remove_read_only(func, path, _exc):
    os.chmod(path, stat.S_IWRITE)
    func(path)


def fail(msg):
    print(f"PATRM_ETH BUILD FAILED: {msg}")
    return 1


def usable_xsa(xsa):
    """Vitis 2026.1 cannot read an XSA whose path contains a space (see sw/patrm_app/build_vitis.py)."""
    if " " not in str(xsa):
        return xsa
    dst = REPO / "build" / "xsa" / xsa.name
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(xsa, dst)
    print(f"XSA path contains a space; using a copy: {dst}")
    return dst


def fixed_lwip_repo():
    """Vitis 2026.1 workaround (found in step 10.0, 2026-11-23). The installed
    data/embeddedsw/ThirdParty/sw_services/lwip220_v1_4/data/lwip220.yaml starts with two comment lines BEFORE the
    '%YAML 1.2' / '---' header, so PyYAML reads two documents, the repository scan (scripts/pyesw/repo.py) drops the
    file without an error, and domain.set_lib('lwip220') fails with "lwip220 Library is not valid for the given
    processor: ps7_cortexa9_0". The install is read-only, so we copy the library to build/esw_repo/ with the header
    first and add that folder as a LOCAL (this workspace only) embedded SW repository. The library sources are
    unchanged; only the order of those lines differs."""
    src = Path(os.environ["XILINX_VITIS"]) / "data" / "embeddedsw" / "ThirdParty" / "sw_services" / "lwip220_v1_4"
    repo = REPO / "build" / "esw_repo"
    dst = repo / "ThirdParty" / "sw_services" / src.name
    if repo.exists():
        shutil.rmtree(repo, onexc=remove_read_only)
    shutil.copytree(src, dst)
    for path in dst.rglob("*"):
        os.chmod(path, stat.S_IWRITE | stat.S_IREAD)
    meta = dst / "data" / "lwip220.yaml"
    # The file also starts with a UTF-8 byte order mark: read with utf-8-sig, write back without it.
    lines = meta.read_text(encoding="utf-8-sig").splitlines(keepends=True)
    head = [i for i, ln in enumerate(lines) if ln.startswith("%YAML")]
    if not head or head[0] + 1 >= len(lines) or not lines[head[0] + 1].startswith("---") \
            or not all(ln.startswith("#") for ln in lines[:head[0]]):
        raise RuntimeError(f"{meta}: layout not as expected (comments, %YAML, ---); recheck the workaround")
    h = head[0]
    lines = lines[h:h + 2] + lines[:h] + lines[h + 2:]
    meta.write_text("".join(lines), encoding="utf-8")
    print(f"lwip220.yaml: byte order mark removed, {h} comment lines moved below the YAML header ({meta})")

    # Second problem in the same library: with the raw API, AMD's lwipopts.h sets NO_SYS_NO_TIMERS 1, so lwIP has no
    # sys_timeout(), but src/Filelists.cmake still compiles the bridge interface (netif/bridgeif*.c), which calls it.
    # GCC 14 (our Arm GNU 14.2 toolchain) treats that implicit declaration as an error and the BSP build stops.
    # Nothing here uses an Ethernet bridge, so those two files are left out of the library.
    lists = dst / "src" / "Filelists.cmake"
    text = lists.read_text(encoding="utf-8")
    drop = ("    ${LWIP_DIR}/src/netif/bridgeif.c\n", "    ${LWIP_DIR}/src/netif/bridgeif_fdb.c\n")
    for line in drop:
        if text.count(line) != 1:
            raise RuntimeError(f"{lists}: expected one line {line.strip()!r}; recheck the workaround")
        text = text.replace(line, "")
    lists.write_text(text, encoding="utf-8")
    print(f"Filelists.cmake: netif/bridgeif.c and bridgeif_fdb.c left out ({lists})")
    return repo


def load_end(elf):
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
    ours = [c for c in commands if Path(c["file"]).suffix == ".c" and APP in c["file"].replace("\\", "/")]
    if not ours:
        return "no application .c file in compile_commands.json"
    for entry in ours:
        words = entry.get("command", "").split()
        missing = [flag for flag in REQUIRED_FLAGS if flag not in words]
        if missing:
            return f"{Path(entry['file']).name} was compiled without {' '.join(missing)}"
    log = build_dir / "build.log"
    if not log.is_file():
        return f"{log} not found"
    warnings = [ln for ln in log.read_text(errors="replace").splitlines() if re.search(r"\bwarning\b", ln, re.I)]
    if warnings:
        return f"{len(warnings)} warning lines in {log}, first: {warnings[0][:160]}"
    print(f"compiled with {' '.join(REQUIRED_FLAGS)}: {', '.join(sorted(Path(c['file']).name for c in ours))}")
    return ""


def main():
    if not XSA.is_file():
        return fail(f"{XSA} not found; run vivado/build.tcl or set PATRM_XSA")
    ELF_OUT.unlink(missing_ok=True)
    if WORKSPACE.exists():
        shutil.rmtree(WORKSPACE, onexc=remove_read_only)
    WORKSPACE.mkdir(parents=True)

    client = vitis.create_client()
    try:
        client.set_workspace(path=str(WORKSPACE))
        client.add_embedded_sw_repo(level="LOCAL", path=str(fixed_lwip_repo()))
        platform = client.create_platform_component(
            name=PLATFORM, hw_design=str(usable_xsa(XSA)), os="standalone", cpu="ps7_cortexa9_0",
            domain_name=DOMAIN, no_boot_bsp=True)
        domain = platform.get_domain(DOMAIN)
        for lib, params in LIBS.items():
            if lib not in str(domain.get_libs()):
                domain.set_lib(lib_name=lib)
            for key, value in params.items():
                domain.set_config(option="lib", param=key, value=value, lib_name=lib)
        # BSP only (AMD code, not ours): lopper (Vivado/bin/.../assists/bmcmake_metadata_xlnx.py, lwip_topolgy) writes
        # the end marker of the lwIP topology table in xtopology_g.c as `{ NULL }` into an integer field. GCC 14 made
        # int-conversion an error; NULL is 0 here, so only that check goes back to a warning, as before GCC 14. Our
        # own sources keep -Wall -Wextra -Werror (checked below).
        flags = domain.get_config(option="proc", param="proc_extra_compiler_flags")["value"]
        if "-Wno-error=int-conversion" not in flags:
            domain.set_config(option="proc", param="proc_extra_compiler_flags",
                              value=f"{flags} -Wno-error=int-conversion")
        print(f"BSP libraries: {domain.get_libs()}")
        platform.build()

        xpfm = client.find_platform_in_repos(PLATFORM)
        app = client.create_app_component(name=APP, platform=xpfm, domain=DOMAIN, template=TEMPLATE)
        for key, value in SETTINGS.items():
            app.set_app_config(key=key, values=value)
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
    print(f"template {TEMPLATE}, lwip220 RAW_API; 0 warnings; program ends at 0x{end:08X}")
    print(f"PATRM_ETH BUILD OK: {ELF_OUT} ({ELF_OUT.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
