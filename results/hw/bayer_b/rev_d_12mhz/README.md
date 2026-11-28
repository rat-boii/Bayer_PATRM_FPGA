# Bayer Option B, Rev D, reduced clock 11.9 MHz (board-tested 2026-11-28)

Status: **timing met at 11.904762 MHz, board-tested, every frame bit-exact.** Reduced-clock experiment build (team
request 2026-11-27, one board test of Option B; exception to D8 for B only). Not a 100 MHz result.

Build: `vivado -mode batch -source ../../vivado/build.tcl -tclargs variant=bayer_b rev=d fclk=12` from build/vivado,
Vivado 2026.1, RTL with Option B stage 1 (commit f27d25d: windows issued back to back), MODES 7 (gray + A + B),
BUILD_TYPE 2, BUILD_ID 0x00407201. FCLK0 = IO PLL 1000 MHz / 84 = 11.904762 MHz. build.tcl sets FREQ_HZ of patrm_0's
clock and AXI interfaces to that value (rtl/patrm_top.v declares 100 MHz). Ethernet application: `PATRM_VARIANT=bayer_b
PATRM_REV=d PATRM_XSA=<this folder>/patrm_bayer_b.xsa vitis -s sw/patrm_eth/build_vitis.py`, ELF copied here.

## Timing (post-route)

WNS +8.391 ns, TNS 0 (0 failing of 22,514 endpoints), WHS +0.024 ns. Worst path 74.0 ns, 98 logic levels:
option_b.engine pos -> state (the fallback's chained "smallest word" search, rtl/bayer_lanes.v). A first build at
fclk=15 (15.15 MHz, 66.0 ns) failed timing by 1.465 ns on the same path (66.4 ns, 97 levels); it was not loaded.
At 100 MHz the same design fails by 46.1 ns (results/hw/bayer_b/rev_d).

## Resources (post-route, whole design)

11,199 LUT (21.1 %), 457 LUTRAM, 6,390 FF, 42 RAMB36 (30 %), 54 DSP48E1 (24.6 %).

## Board results (Rev D, Ethernet, 2026-11-28)

| Mode on this bitstream | Cases | Result | File |
|---|---|---|---|
| Bayer B | 66 | RUN_ALL PASS, bit-exact | results/board/run_all_revd_bayer_b_bayer_b_eth_rev_d_12mhz.* |
| Bayer A | 66 | RUN_ALL PASS, bit-exact | results/board/run_all_revd_bayer_b_bayer_a_eth_rev_d_12mhz.* |
| Gray | 33 | RUN_ALL PASS, bit-exact | results/board/run_all_revd_bayer_b_gray_eth_rev_d_12mhz.* |

Run: `python scripts/board/run_all.py --rev d --variant bayer_b --mode bayer_b --images chart,photo --link eth
--hw results/hw/bayer_b/rev_d_12mhz --timeout-ms 10000` (and `--mode bayer_a`, `--mode gray`).

B vs A cycles (B here at 11.9 MHz, A from the 100 MHz Bayer A bitstream): without rotation B/A 0.76-0.93 (B faster per
clock), with rotation 1.4-1.97; B reads 50-62 % of A's bytes. CAUTION: at 11.9 MHz a DDR access costs about 8x fewer
clock cycles than at 100 MHz, so these board ratios flatter B on the latency-bound rotations; the equal-clock comparison
is the simulation (results/sim/bayer_ab_256x192_stage1.txt: rotations 1.7-3.1). Wall-clock B is 7-16x slower than A
(2448x2048 identity 385 ms vs 50.1 ms; rot90 2,113 ms vs 133 ms).
