# Bayer Option A - Rev D laptop build, 23 November 2026

Status: **board-verified on ZedBoard Rev D, 23 November 2026 (step 5.3 passed)**. The .bit, .xsa, .elf and ps7_init.tcl
here are the exact files run on the board (SHA-256 checked against manifest.json before the commit).

## Board results (step 5.3, JTAG link)

- run_all --mode bayer_a --rev d --images chart,photo: **RUN_ALL PASS, 66 of 66** (480x272, 800x480, 2448x2048 x
  chart, photo x 11 transforms): every output bit-exact with model/bayer.py, BYTES_RD = four-pass memmodel prediction,
  BYTES_WR = 2 W H, last row correct, guard bytes untouched, BUILD_ID 0x00403101. results/board/run_all_revd_bayer_a_bayer_a.*
- run_all --variant bayer_a --mode gray --rev d: **RUN_ALL PASS, 33 of 33**; CYCLES within 0.07 % of the gray bitstream
  (inside the run-to-run spread). results/board/run_all_revd_bayer_a_gray.*
- Single jobs: interrupt (--load), N = 10 repetition, polling (interrupt count unchanged), and five gray / Bayer jobs
  alternating without reloading: all JOB PASS. results/board/step53_bayer_a/
- Bayer engine time (N = 1): 2448x2048 identity 50.14 ms (19.9 fps), rot15 73.4 ms, rot37 109.8 ms, rot90 132.9 ms;
  800x480 identity 3.85 ms. UART output was not captured (not needed for the checks; results come from DDR).

## Current build (rebuilt 2026-11-23 on main)

Rebuilt from merged `main` (steps 5.3, 6.1, 6.2 and Phase 10, commit 2cf14b0, no uncommitted source changes) with the
project tools: Vivado/Vitis 2026.1, Arm GNU 14.2.Rel1, 100 MHz, no ILA. Explicit Rev D DDR part MT41K128M16 JT-125;
MODES=3, BUILD_TYPE=1; expected BUILD_ID=0x00403101. New in this build: **ENET0 MDIO on MIO 52/53** (vivado/build.tcl),
so Ethernet works without scripts/eth/mdio_mio.tcl. The application is built with `-DFPU_HARD_FLOAT_ABI_ENABLED=1`
(the IRQ entry saves the VFP registers; checked by the build).

- BUILD: all checks passed. Post-route WNS +1.049 ns, WHS +0.051 ns, 0 failing endpoints.
- Whole design: 2,989 LUT, 4,071 FF, 8 RAMB36, 17 DSP48E1 (summary.txt).
- patrm_app.elf: 308,220 bytes, PATRM_APP BUILD OK. Regression on the merged sources: 52 of 52 PASS.
- The .bit / .xsa / .elf are tracked in git since the board verified them; manifest.json holds their sizes and SHA-256.

## Ethernet (step 10.4)

patrm_eth.elf: the step 10.2 Ethernet job service built from this XSA (PATRM_VARIANT=bayer_a PATRM_REV=d
vitis -s sw/patrm_eth/build_vitis.py; 0 warnings, VFP save checked, 1,010,912 bytes). Board 2026-11-23: Bayer run_all
66 of 66 and gray-on-A 33 of 33 PASS over Ethernet, counters identical to JTAG; MIO 52/53 read 0x280 after ps7_init
(the build.tcl MDIO fix works, no workaround). Logs: results/board/step10_4/.

## Earlier build of the teammate (2025.2, replaced)

Build: Vivado/Vitis 2025.2, Arm GNU 15.3.1, 100 MHz, no ILA. Base source commit 9319cf0, local branch
codex/step-5-3-revd-offline with uncommitted changes (its build.tcl matches no commit; its binaries were not shared).
Its laptop checks, kept as a record:

## Verified on the laptop (2025.2 build)

- Full block-design, bitstream and XSA build: BUILD: all checks passed.
- Post-route WNS +0.938 ns, WHS +0.055 ns, no setup/hold failing endpoints, no latches.
- Whole design: 2,987 LUT, 4,071 FF, 8 RAMB36, 17 DSP48E1 (summary.txt).
- Four known preset PSU-1..4 validation critical warnings remain accepted as documented;
  no additional validation critical warnings; synthesis/implementation report none.
- Vectorless on-chip power estimate: 1.767 W, not measured board power.
- Full regression: REGRESSION PASS, 43 items, including gray/A frame simulations,
  deliberate faults and Zynq VIP system simulation.
- Actual C driver vs model/job.py: 574 cases at -O2 and at -O3; configuration writes and
  validation agree, including negative odd translation sums. BSP accesses are mocked.
- Job/result checker: 10 gray/A cases; incompatible build ID, wrong bus-byte count,
  final-pixel and guard corruption detected. Results are synthetic, not hardware data.
- Application ELF: 309,448 bytes; PATRM_APP BUILD OK; our three C sources
  compile with -Wall -Wextra -Werror -O2 and no warnings; linked below 0x0F000000.
- AMD-generated BSP emits two warnings with this compiler (emacps missing initializer,
  dmaps unused parameter). These are recorded in build/step53_vitis.out; vendor files
  were not modified. Zero-warning application checks exclude the separate BSP build.
- Bayer and gray-on-A run_all dry runs pass; no board connection or measured FPS claim.

## Files

patrm_bayer_a.bit configures the PL; patrm_bayer_a.xsa exports the hardware for Vitis;
ps7_init.tcl initializes the matching PS/DDR; patrm_app.elf (JTAG) and patrm_eth.elf (Ethernet) accept gray and A jobs.
Keep this set together. Other reports use the same scope as summary.txt.

## Board session

Done 2026-11-23, see "Board results" above. Procedure: docs/step-5.3-revd-offline.md.
