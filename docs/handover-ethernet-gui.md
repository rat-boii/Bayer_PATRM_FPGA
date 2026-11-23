# Handover: Ethernet link and GUI (plan Phase 10, grayscale)

For the teammate (and the coding agent he uses: Claude Code or Codex) who builds the PC GUI and the Ethernet link.

**Status 2026-11-23:** not handed over after all; we do Phase 10 ourselves on `main`. This file stays as the Phase 10 brief. The branch advice in section 2 applies only if someone else takes it later.
Written 2026-11-22, at commit `step-5.2`. **Read `CLAUDE.md` first**: its rules apply to this work too (model is the
reference, bit-exact checks, one step at a time, label estimates, never change a fixed decision without asking).

## 1. Goal and scope

Replace USB-JTAG as the **image path** between the PC and the board with Gigabit Ethernet, and build a Python GUI on
top of it. Grayscale only (MODE 0). The engine, its registers and the speedup claim do not change. Plan steps
(`docs/implementation-plan.md`, Phase 10; each needs its Verify check before the next):

| step | what | Verify |
|---|---|---|
| 10.0 | feasibility: Vitis 2026.1 Python API offers lwIP (bare metal) and a TCP/UDP template; Ethernet port on the laptop | lwIP echo app builds with -Wall -Wextra -Werror; Ethernet enabled in the design (already confirmed, section 3) |
| 10.1 | echo throughput | PC sends 1 MB and 5 MB, board echoes: identical 10 of 10; MB/s measured both ways, next to the JTAG figure |
| 10.2 | jobs over Ethernet | the step 4.3 grayscale set bit-exact over Ethernet, counters = predictions, same CYCLES as over JTAG |
| 10.3 | live GUI | GUI output == model for every frame shown (0 differing bytes); updates/s measured |

JTAG stays for programming the FPGA and loading the ARM program.

## 2. Files: what this work may change

Work on a **branch** (for example `eth-gui`) and merge through a pull request. The Bayer work continues on `main` at
the same time and changes `rtl/`, `tb/`, `spec/interface.md`, and in step 5.3 `sw/patrm_drv`, `sw/patrm_app`,
`sw/include`, `model/job.py` and `scripts/board/`.

- **New files only, where possible:** `sw/patrm_eth/` (the lwIP application + its `build_vitis.py`), `scripts/eth/`
  (PC client, throughput test, `run_all`-style runner), the GUI (`model/warp_gui.py` board mode, or a new file such as
  `scripts/eth/gui.py`), and `docs/` notes.
- **Reuse, do not edit:** `sw/patrm_drv/` (engine driver), `sw/include/` (register map, job layout), `model/`
  (reference model, job encoding), `spec/`. If one of these really needs a change, stop and agree it with the team
  first: they are shared with the Bayer work.
- **Never touch:** `rtl/`, `tb/`, `vivado/`, `spec/regs.json`, fixed decisions D1-D20 in `CLAUDE.md`.
- Commits: `step 10.x: <summary>`, tag `step-10.x` after the Verify check passes; add a dated line to the Progress
  section of `docs/implementation-plan.md` with the measured numbers.

## 3. Hardware facts (verified)

- Board: ZedBoard. The **verified** bitstream bundle is `results/hw/rev D/` (patrm_gray.bit, patrm_gray.xsa,
  ps7_init.tcl, bringup.elf; Rev D board, all step 4.2-4.4 hardware tests). Read `results/hw/rev D/README.md`.
- **Ethernet is already enabled** in that XSA: `PCW_ENET0_PERIPHERAL_ENABLE = 1`, ENET0 on MIO 16..27,
  MDIO enabled, 1000 Mbps (read from the XSA's .hwh on 2026-11-22). No FPGA rebuild is needed for Phase 10.
- PL clock 100 MHz. Engine registers at 0x43C0_0000 (AXI-Lite, GP0). Done interrupt: GIC ID 61, level, active high.
- DDR map (`spec/memory_map.md` section 1): ARM program 0x0010_0000 .. below 0x0F00_0000 (lwIP buffers and heap
  must stay there too); source image 0x1000_0000 (16 MB); output 0x1800_0000 (16 MB); job descriptor 0x1F00_0000;
  result record 0x1F00_1000. Image buffers 4 KB aligned, W x H bytes, GRAY8 row-major, no header.
- The HP ports do not see the ARM caches. When the ARM writes the source (received over Ethernet) it must flush it
  before the engine runs; the job flag `JOB_FLAG_SRC_CPU` (bit 1) does exactly that in `patrm_app`. After DONE,
  invalidate the output before the ARM reads it to send it back (`spec/memory_map.md` section 4).

## 4. What already exists and works (reuse it)

| piece | where | status |
|---|---|---|
| reference model, bit-exact | `model/patrm.py` (`warp_gray`), transforms `model/transforms.json`, forward params -> b: `patrm.make_b` (D5) | the reference |
| job descriptor / result record | `model/job.py` (`encode_job`, `decode_result`), `sw/include/patrm_job.h`, `spec/memory_map.md` section 5 | checked by `model/test_job_layout.py` |
| engine driver | `sw/patrm_drv/` (`patrm_init`, `patrm_irq_init`, `patrm_validate`, `patrm_run`, timer helpers) | on hardware, steps 4.2-4.4 |
| ARM job app (JTAG mailbox) | `sw/patrm_app/main.c`; ELFs `results/hw/patrm_app.elf` (-O2), `patrm_app_o3.elf` | 33 of 33 bit-exact on Rev D |
| PC runners over JTAG | `scripts/board/run_job.py`, `run_all.py`, `png_transform.py` | the flow 10.2 must reproduce |
| model-only GUI | `model/warp_gui.py` (Tkinter: image, size, transform, run, side by side) | no board yet |

**Suggested design for 10.2** (a proposal, not a decision): keep the job descriptor and result record of section 5
unchanged and carry them over TCP. The lwIP app receives `descriptor + source image`, writes the image to
0x1000_0000, runs the job with the same code path as `patrm_app` (flag `SRC_CPU`), and sends back
`result record + output image`. Then `run_all`-style checks and the step 4.3 numbers compare one to one.

## 5. First session checklist (before writing any code)

1. Clone, then `python scripts/check_setup.py` and follow its fixes (README "New laptop setup": Python packages,
   Vivado/Vitis 2026.1 + licence, Arm GNU toolchain, Digilent cable drivers, ZedBoard board files).
2. Generate the test images that are not in git: `python -m model.gen_images` (writes `data/gen/`; the board
   runners read their images from there). The simulation vectors (`model.gen_vectors`, `scripts/gen_*_vectors.py`)
   are not needed for Phase 10.
3. Prove the board with the existing JTAG path first (board connected: PROG and UART):
   `python scripts/board/run_job.py mixed identity 64 64 --load --bit "results/hw/rev D/patrm_gray.bit" --init "results/hw/rev D/ps7_init.tcl"`
   -> last line `JOB PASS`. Then `python scripts/board/run_all.py --rev d --sizes 480x272` -> `RUN_ALL PASS`.
4. Only then start 10.0.

## 6. Known pitfalls (all hit before on this project)

- `xil_printf` in the 2026.1 standalone BSP reads `%l` as 64-bit: print 32-bit values with `%u` / `%x` and an
  `(unsigned int)` cast (step 4.2 data abort).
- `vitis -s` and `xsdb` can exit 0 after a failure: read the last printed line (`... BUILD OK`, `JOB PASS`).
- `vivado.bat` / `xvlog.bat` split command-line arguments at `=` (scripts already handle it).
- Build the ARM code with `-Wall -Wextra -Werror` like `sw/patrm_app/build_vitis.py`. Fresh clone: that script now
  falls back to `results/hw/rev D/patrm_gray.xsa` (or set `PATRM_XSA`). Tested 2026-11-22 on a fresh clone:
  PATRM_APP BUILD OK, 0 warnings. That ELF (302,996 bytes, BSP from the Rev D XSA) has NOT been run on a board; for
  board tests use the tracked, hardware-verified `results/hw/patrm_app.elf` (302,364 bytes) until yours is verified.
- Vitis 2026.1 cannot read an XSA whose path contains a space (`'standalone' is an invalid os. Valid OSes are
  '[]'`); the build scripts copy such an XSA to `build/xsa/` first. Keep the clone itself in a short path without
  spaces (a long temporary path also failed: "Invalid project location").
- Images must follow D3 (grayscale W multiple of 8) and D11 (at most 4096 x 4096); transforms D4. Use `model/job.py`
  checks on the PC side, and never do floating-point transform maths on the ARM (b comes from the PC, D5).
- The laptop and board need static IPs on a direct cable. AMD's echo template uses board 192.168.1.10 (after a
  DHCP timeout), so give the laptop another address, for example 192.168.1.100 / 255.255.255.0.
- lwIP build: `vitis -s sw/patrm_eth/build_vitis.py` (step 10.0) holds three Vitis 2026.1 / GCC 14
  workarounds (README step 10.0). After a failed `vitis -s` run, a leftover Vitis server (java, RigelApp)
  can lock the workspace; stop it before the next run.
- The Rev D XSA routes ENET0 MDIO to EMIO, not MIO 52/53: load with `scripts/eth/echo_test.py --load` (or run
  `scripts/eth/mdio_mio.tcl` after ps7_init) until vivado/build.tcl is fixed. The board needs about 27 s to boot.

## 7. Unknown until measured

- ~~Whether Vitis 2026.1 ships lwIP~~: yes, lwip220 + templates; it builds (step 10.0, 2026-11-23).
- Real Ethernet throughput: measured in step 10.1b, about 107 MB/s PC -> board and 99 MB/s board -> PC (one direction at a time; full-rate both ways at once causes receive overruns).
- Real Ethernet throughput of a bare-metal lwIP app on the Cortex-A9 (step 10.1). The JTAG figure to compare with is
  only a rough estimate (about 0.2 MB/s from the step 4.3 run time); measure both.
- Which ZedBoard is used for the tests: everything above is verified on the Rev D board only.
