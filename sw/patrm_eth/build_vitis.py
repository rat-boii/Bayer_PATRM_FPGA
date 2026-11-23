"""Step 10.0: build AMD's lwIP echo server for the ZedBoard with the Vitis Python API (no XSCT).

    vitis -s sw/patrm_eth/build_vitis.py

Step 10.0 showed that Vitis 2026.1 ships lwIP (lwip220, raw API, bare metal) and the lwip_echo_server template, and
that they build for ps7_cortexa9_0 from our XSA with -Wall -Wextra -Werror (as sw/patrm_app/build_vitis.py).
Step 10.1: the template's echo.c is replaced by sw/patrm_eth/echo.c (flow-controlled echo, nothing dropped), lwIP gets
the buffer sizes of AMD's TCP perf template; after a DHCP timeout (about 12 s) the board is 192.168.1.10.
Step 10.2: PATRM jobs over Ethernet (sw/patrm_eth/eth_job.c, port 5003) with the driver, software baseline and job
runner of sw/patrm_app. The ELF is now results/hw/patrm_eth.elf.

Creates a new workspace in build/vitis/patrm_eth (an old one is deleted): a standalone platform from the XSA with
lwip220 added to the BSP (settings from the template's own lwip_echo_server.yaml), then the app from the template.
Checks: every template .c file compiled with the required flags, no compiler warning in the build log, program below
0x0F00_0000 (spec/memory_map.md section 1). Copies the ELF to results/hw/patrm_eth.elf (not tracked). `vitis -s` can exit 0 after a failure: the build succeeded only if the last line is PATRM_ETH BUILD OK.

XSA: environment variable PATRM_XSA if set; else results/hw/patrm_gray.xsa; else the tracked Rev D bundle.
Step 10.4: PATRM_VARIANT=bayer_a PATRM_REV=d builds from results/hw/bayer_a/rev_d/patrm_bayer_a.xsa and writes
results/hw/bayer_a/rev_d/patrm_eth.elf (gray and Bayer A jobs; MDIO already on MIO 52/53 in that XSA).
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

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from amd_tools import irq_saves_vfp          # noqa: E402

os.environ["PATH"] = str(Path(os.environ["XILINX_VIVADO"]) / "bin") + os.pathsep + os.environ["PATH"]

REPO = Path(__file__).resolve().parents[2]
# Step 10.4: PATRM_VARIANT=bayer_a (PATRM_REV=d) builds the same application from the Bayer A XSA into its own
# workspace, and writes results/hw/bayer_a/rev_<rev>/patrm_eth.elf next to that bundle. The gray default is unchanged.
VARIANT = os.environ.get("PATRM_VARIANT", "gray")
REV = os.environ.get("PATRM_REV", "d").lower()
if VARIANT not in ("gray", "bayer_a", "bayer_b") or REV not in ("c", "d"):
    raise ValueError("PATRM_VARIANT must be gray|bayer_a|bayer_b; PATRM_REV must be c|d")
if VARIANT != "gray":                          # bayer_a (step 10.4) or bayer_b (step 6.4)
    A_DIR = REPO / "results" / "hw" / VARIANT / f"rev_{REV}"
    XSA = Path(os.environ["PATRM_XSA"]) if os.environ.get("PATRM_XSA") else A_DIR / f"patrm_{VARIANT}.xsa"
    WORKSPACE = REPO / "build" / "vitis" / f"patrm_eth_{VARIANT}_rev{REV}"
    ELF_OUT = A_DIR / "patrm_eth.elf"
    PLATFORM = f"patrm_eth_{VARIANT}_rev{REV}_plat"
else:
    XSA = Path(os.environ["PATRM_XSA"]) if os.environ.get("PATRM_XSA") else REPO / "results" / "hw" / "patrm_gray.xsa"
    if not os.environ.get("PATRM_XSA") and not XSA.is_file():
        XSA = REPO / "results" / "hw" / "rev D" / "patrm_gray.xsa"
    WORKSPACE = REPO / "build" / "vitis" / "patrm_eth"
    ELF_OUT = REPO / "results" / "hw" / "patrm_eth.elf"
    PLATFORM = "patrm_eth_plat"
DOMAIN = "standalone_a9_0"
APP = "patrm_eth"
TEMPLATE = "lwip_echo_server"
PROGRAM_END = 0x0F00_0000
REQUIRED_FLAGS = ("-Wall", "-Wextra", "-Werror", "-O2")
SETTINGS = {"USER_COMPILE_WARNINGS_ALL": "-Wall", "USER_COMPILE_WARNINGS_EXTRA": "-Wextra",
            "USER_COMPILE_WARNINGS_AS_ERRORS": "-Werror", "USER_COMPILE_OPTIMIZATION_LEVEL": "-O2",
            "USER_COMPILE_OTHER_FLAGS": "-std=gnu11"}
# Step 10.2: added to the app (import_files puts them in USER_COMPILE_SOURCES). The driver, the software baseline and
# the job runner are the same files as in sw/patrm_app, so a job runs with the same code over JTAG and Ethernet.
IMPORTS = [("sw/patrm_eth", "eth_job.c"), ("sw/patrm_eth", "patrm_eth.h"),
           ("sw/patrm_drv", "patrm_drv.c"), ("sw/patrm_drv", "patrm_drv.h"),
           ("sw/patrm_sw", "patrm_sw.c"), ("sw/patrm_sw", "patrm_sw.h"),
           ("sw/patrm_job", "patrm_jobrun.c"), ("sw/patrm_job", "patrm_jobrun.h"),
           ("sw/include", "patrm_regs.h"), ("sw/include", "patrm_defs.h"), ("sw/include", "patrm_job.h")]
# BSP library settings (step 10.1): the buffer sizes of AMD's lwip_tcp_perf_server template
# (data/lwip_tcp_perf_server.yaml, depends_libs, Vitis 2026.1). DHCP must stay on: create_app_component refuses the
# template otherwise ("lwip220_dhcp: True expected"). On a direct cable there is no DHCP server, so the template's
# main.c times out (240 ticks of 50 ms, about 12 s) and uses 192.168.1.10 / 255.255.255.0.
# create_app_component also insists on the echo template's exact values (pbuf_pool_size 2048), so the platform is first
# built with those (LIBS), the app is created, and then the BSP gets the perf sizes (PERF) and is built again.
LIBS = {"lwip220": {"lwip220_api_mode": "RAW_API", "lwip220_dhcp": "true",
                    "lwip220_lwip_dhcp_does_acd_check": "true", "lwip220_ipv6_enable": "false",
                    "lwip220_pbuf_pool_size": "2048"},
        # The template asks only for the interval timer, but XILTIMER_tick_timer defaults to None
        # (XTIMER_NO_TICK_TIMER): then no 50 ms tick ever fires, lwIP timers never run and the template's DHCP wait
        # never ends (found on the board in step 10.1). The A9 private timer needs nothing from the PL.
        "xiltimer": {"XILTIMER_en_interval_timer": "true", "XILTIMER_tick_timer": "ps7_scutimer_0"}}
PERF = {"lwip220_mem_size": "524288", "lwip220_memp_n_pbuf": "1024", "lwip220_memp_n_tcp_seg": "1024",
        "lwip220_n_rx_descriptors": "512", "lwip220_n_tx_descriptors": "512",
        "lwip220_pbuf_pool_size": "16384", "lwip220_tcp_snd_buf": "65535", "lwip220_tcp_wnd": "65535"}
# Our sources that replace template files of the same name (the template's main.c and platform code stay).
OUR_FILES = ["echo.c"]


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
        # Step 10.2: FPU_HARD_FLOAT_ABI_ENABLED, see amd_tools.irq_saves_vfp. Without it the IRQ entry does not save
        # the VFP registers; the GEM interrupt handler runs memcpy (XEmacPs_GetQxOffset) and its d0/d1 values landed in
        # the middle of our own memcpy of a received image: 16 bytes of a register-offset table in the source.
        flags = domain.get_config(option="proc", param="proc_extra_compiler_flags")["value"]
        for extra in ("-Wno-error=int-conversion", "-DFPU_HARD_FLOAT_ABI_ENABLED=1"):
            if extra not in flags:
                flags = f"{flags} {extra}"
        domain.set_config(option="proc", param="proc_extra_compiler_flags", value=flags)
        print(f"BSP libraries: {domain.get_libs()}")
        platform.build()

        xpfm = client.find_platform_in_repos(PLATFORM)
        app = client.create_app_component(name=APP, platform=xpfm, domain=DOMAIN, template=TEMPLATE)
        for name in OUR_FILES:
            target = WORKSPACE / APP / "src" / name
            if not target.is_file():
                raise RuntimeError(f"template file {target} not found; the template layout changed")
            shutil.copyfile(REPO / "sw" / "patrm_eth" / name, target)
            print(f"replaced template {name} with sw/patrm_eth/{name}")
        for folder, name in IMPORTS:
            app.import_files(from_loc=str(REPO / folder), files=[name], dest_dir_in_cmp="src")
        for key, value in PERF.items():
            domain.set_config(option="lib", param=key, value=value, lib_name="lwip220")
        got = {k: domain.get_config(option="lib", param=k, lib_name="lwip220")["value"] for k in PERF}
        if got != PERF:
            raise RuntimeError(f"lwIP perf settings not applied: {got}")
        print(f"lwIP perf settings: {got}")
        platform.build()
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
    ok, text = irq_saves_vfp(elfs[0])
    print(text)
    if not ok:
        return fail(text)
    end = load_end(elfs[0])
    if not 0 < end <= PROGRAM_END:
        return fail(f"program ends at 0x{end:08X}, it must stay below 0x{PROGRAM_END:08X}")
    shutil.copyfile(elfs[0], ELF_OUT)
    print(f"template {TEMPLATE}, lwip220 RAW_API; 0 warnings; program ends at 0x{end:08X}")
    print(f"PATRM_ETH BUILD OK: {ELF_OUT} ({ELF_OUT.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
