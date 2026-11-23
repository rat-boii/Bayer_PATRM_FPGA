# Bayer Option A - Rev D laptop build, 23 November 2026

Status: **laptop checks passed; board verification pending**. Step 5.3 is not complete,
and no step-5.3 tag has been made. These files have not been loaded on an FPGA.

## Current build (rebuilt 2026-11-23 on main)

Rebuilt from merged `main` (steps 5.3, 6.1, 6.2 and Phase 10, commit 2cf14b0, no uncommitted source changes) with the
project tools: Vivado/Vitis 2026.1, Arm GNU 14.2.Rel1, 100 MHz, no ILA. Explicit Rev D DDR part MT41K128M16 JT-125;
MODES=3, BUILD_TYPE=1; expected BUILD_ID=0x00403101. New in this build: **ENET0 MDIO on MIO 52/53** (vivado/build.tcl),
so Ethernet works without scripts/eth/mdio_mio.tcl. The application is built with `-DFPU_HARD_FLOAT_ABI_ENABLED=1`
(the IRQ entry saves the VFP registers; checked by the build).

- BUILD: all checks passed. Post-route WNS +1.049 ns, WHS +0.051 ns, 0 failing endpoints.
- Whole design: 2,989 LUT, 4,071 FF, 8 RAMB36, 17 DSP48E1 (summary.txt).
- patrm_app.elf: 308,220 bytes, PATRM_APP BUILD OK. Regression on the merged sources: 52 of 52 PASS.
- The .bit / .xsa / .elf are not in git (results/**/*.bit etc. are ignored) until the board has verified them;
  manifest.json holds their sizes and SHA-256.

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
ps7_init.tcl initializes the matching PS/DDR; patrm_app.elf accepts gray and A jobs.
Keep this set together. Other reports use the same scope as summary.txt.

## Next board session

Follow docs/step-5.3-revd-offline.md. Require all Bayer outputs bit-exact with model/bayer.py,
all four-pass read counts correct, BYTES_WR=2*W*H, last rows/guards correct, interrupts and
polling, repeated jobs and the gray regression on this A build. Save UART logs and CSVs.
Only then mark step 5.3 passed. The verified older grayscale bundle is unchanged.
