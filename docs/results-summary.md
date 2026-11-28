# Bayer-PATRM: results summary (all measured numbers)

Generated 2026-11-28 14:21 by `scripts/summarize_results.py` from the tracked result files. Do not edit by hand: re-run the script. Board: ZedBoard Rev D (XC7Z020-1), PL clock 100 MHz (step 7.1: measured 100.0025 MHz), ARM Cortex-A9 at 650 MHz. Sizes are W x H. 'Bit-exact' = 0 differing bytes against the Python model.

## 1. FPGA builds: resources, timing, power (post-route, whole design)

| Build | LUT | LUTRAM | FF | BRAM36 | DSP | Slices | WNS ns | WHS ns | Power W (total / PS7 / logic+DSP) | Note |
|---|---|---|---|---|---|---|---|---|---|---|
| Grayscale, Rev C (Vivado 2026.1) | 2670 | 311 | 3934 | 8 | 17 | 1329 | 1.325 | 0.037 | 1.752 / 1.566 / 0.013 | reference gray build |
| Grayscale, Rev D (Vivado 2025.2) | 2670 | 311 | 3934 | 8 | 17 | 1345 | 0.779 | 0.024 | 1.753 / 1.566 / 0.014 | board-verified gray bundle (steps 4.x, 10.2, 10.3) |
| Bayer A, Rev D (Vivado 2026.1) | 2989 | 311 | 4071 | 8 | 17 | 1430 | 1.049 | 0.051 | 1.766 / 1.566 / 0.024 | board-verified; runs gray and Bayer (5.3, 10.4, 10.5) |
| Bayer B, Rev D (Vivado 2026.1) | 11575 | 453 | 6411 | 42 | 54 | 4175 | -46.129 | 0.001 | 1.877 / 1.566 / 0.073 | TIMING FAILED at 100 MHz, not loaded (6.3) |
| Bayer B stage 1, Rev D, 11.9 MHz | 11199 | 457 | 6390 | 42 | 54 | 4125 | 8.391 | 0.024 | 1.722 / 1.557 / 0.008 | reduced-clock experiment (D8 exception); board-tested, all modes bit-exact |

Device totals (XC7Z020): 53,200 LUT, 17,400 LUTRAM, 106,400 FF, 140 BRAM36, 220 DSP48E1, 13,300 slices. Power is a vectorless Vivado ESTIMATE; the PS7 (ARM, DDR controller) is about 1.57 W of the total. Sources: `results/hw/**/summary.txt`, `utilization.rpt`, `timing_summary.rpt`, `power.rpt`.

### Engine per module: Grayscale, Rev C (Vivado 2026.1)

Engine total (patrm_0): 2299 LUT, 3475 FF, 8 BRAM36, 17 DSP. AXI GP0 protocol converter (AMD IP) is outside the engine.

| Instance | Module | LUT | FF | BRAM36 | DSP |
|---|---|---|---|---|---|
| u_buf | line_buf | 128 | 0 | 8 | 0 |
| u_coord | coord_gen | 268 | 352 | 0 | 8 |
| u_ctrl | ctrl_fsm | 72 | 157 | 0 | 0 |
| u_fetch | pixel_fetch | 100 | 229 | 0 | 0 |
| u_ofifo | out_fifo | 130 | 78 | 0 | 0 |
| u_planner | block_planner | 562 | 812 | 0 | 0 |
| u_prefetch | prefetch_ctrl | 486 | 859 | 0 | 2 |
| u_rd | axi_rd_master | 89 | 191 | 0 | 0 |
| u_regs | axil_regs | 396 | 596 | 0 | 0 |
| u_wr | axi_wr_master | 99 | 196 | 0 | 0 |

The bilinear interpolator and other small logic are flattened into the top level (patrm_top) by Vivado, so they have no row; they are the difference to the engine total. Source: `results/hw/utilization_hier.rpt`.

### Engine per module: Bayer A, Rev D (Vivado 2026.1)

Engine total (patrm_0): 2617 LUT, 3612 FF, 8 BRAM36, 17 DSP. AXI GP0 protocol converter (AMD IP) is outside the engine.

| Instance | Module | LUT | FF | BRAM36 | DSP |
|---|---|---|---|---|---|
| u_buf | line_buf | 128 | 0 | 8 | 0 |
| u_coord | coord_gen | 268 | 352 | 0 | 8 |
| u_ctrl | ctrl_fsm | 71 | 156 | 0 | 0 |
| u_fetch | pixel_fetch | 109 | 231 | 0 | 0 |
| u_ofifo | out_fifo | 223 | 87 | 0 | 0 |
| u_planner | block_planner | 577 | 815 | 0 | 0 |
| u_prefetch | prefetch_ctrl | 495 | 860 | 0 | 2 |
| u_rd | axi_rd_master | 89 | 191 | 0 | 0 |
| u_regs | axil_regs | 527 | 596 | 0 | 0 |
| u_seq | bayer_seq | 49 | 99 | 0 | 0 |
| u_wr | axi_wr_master | 103 | 220 | 0 | 0 |

The bilinear interpolator and other small logic are flattened into the top level (patrm_top) by Vivado, so they have no row; they are the difference to the engine total. Source: `results/hw/bayer_a/rev_d/utilization_hier.rpt`.

## 2. Board test sets (every case checked bit-exact, last row, guard bytes, byte counters)

| Result file | Cases | Passed | What |
|---|---|---|---|
| `results/board/run_all_revd.csv` | 33 | 33 | gray bitstream, FPGA engine, JTAG |
| `results/board/run_all_revd_bayer_a_bayer_a.csv` | 66 | 66 | Bayer A, FPGA engine, JTAG |
| `results/board/run_all_revd_bayer_a_bayer_a_eth.csv` | 66 | 66 | Bayer A, FPGA engine, Ethernet |
| `results/board/run_all_revd_bayer_a_gray.csv` | 33 | 33 | gray on Bayer A bitstream, FPGA engine, JTAG |
| `results/board/run_all_revd_bayer_a_gray_eth.csv` | 33 | 33 | gray on Bayer A bitstream, FPGA engine, Ethernet |
| `results/board/run_all_revd_bayer_a_gray_eth_sw_patrm_eth.csv` | 33 | 33 | gray on Bayer A bitstream, ARM software, Ethernet |
| `results/board/run_all_revd_bayer_b_bayer_a_eth_rev_d_12mhz.csv` | 66 | 66 | gray bitstream, FPGA engine, Ethernet |
| `results/board/run_all_revd_bayer_b_bayer_b_eth_rev_d_12mhz.csv` | 66 | 66 | gray bitstream, FPGA engine, Ethernet |
| `results/board/run_all_revd_bayer_b_gray_eth_rev_d_12mhz.csv` | 33 | 33 | gray bitstream, FPGA engine, Ethernet |
| `results/board/run_all_revd_eth.csv` | 33 | 33 | gray bitstream, FPGA engine, Ethernet |
| `results/board/run_all_revd_jtag_rerun_2026-11-23.csv` | 33 | 33 | gray bitstream, FPGA engine, JTAG |
| `results/board/run_all_revd_sw_patrm_app.csv` | 33 | 33 | gray bitstream, ARM software, JTAG |
| `results/board/run_all_revd_sw_patrm_app_o3.csv` | 33 | 33 | gray bitstream, ARM software, JTAG, -O3 |

## 3. Acceleration: grayscale, FPGA engine vs ARM software (same algorithm, same frames, bit-exact)

FPGA = engine time START to DONE (Bayer A bitstream, Ethernet run). ARM = the same fixed-point warp in C (`sw/patrm_sw/patrm_sw.c`) on one Cortex-A9 core, warp time only (JTAG runs, -O2 and -O3). One frame per case (N = 1); step 7.2 will add N = 10 min/avg/max. Speedup = ARM -O2 / FPGA.

| Size | Transform | FPGA ms | FPGA Mpix/s | RD stall % | ARM -O2 ms | ARM -O3 ms | Speedup |
|---|---|---|---|---|---|---|---|
| 480x272 | identity | 1.308 | 99.83 | 0.0 | 8.74 | 8.93 | 6.7x |
| 480x272 | mirror_cols | 1.308 | 99.85 | 0.0 | 8.90 | 9.10 | 6.8x |
| 480x272 | mirror_rows | 1.308 | 99.84 | 0.0 | 8.80 | 9.00 | 6.7x |
| 480x272 | rot5 | 1.308 | 99.85 | 0.0 | 8.71 | 8.90 | 6.7x |
| 480x272 | rot15 | 1.382 | 94.45 | 5.4 | 8.32 | 8.50 | 6.0x |
| 480x272 | rot37 | 2.203 | 59.25 | 40.2 | 7.77 | 7.92 | 3.5x |
| 480x272 | scale0p8 | 1.308 | 99.85 | 0.0 | 6.36 | 6.48 | 4.9x |
| 480x272 | scale1p25 | 1.308 | 99.84 | 0.0 | 8.71 | 8.90 | 6.7x |
| 480x272 | combined | 1.307 | 99.87 | 0.0 | 7.72 | 7.88 | 5.9x |
| 480x272 | rot90 | 2.595 | 50.32 | 48.5 | 6.00 | 6.12 | 2.3x |
| 480x272 | rot180 | 1.308 | 99.85 | 0.0 | 8.81 | 9.02 | 6.7x |
| 800x480 | identity | 3.842 | 99.95 | 0.0 | 25.69 | 26.25 | 6.7x |
| 800x480 | mirror_cols | 3.842 | 99.95 | 0.0 | 26.06 | 26.66 | 6.8x |
| 800x480 | mirror_rows | 3.842 | 99.95 | 0.0 | 25.85 | 26.43 | 6.7x |
| 800x480 | rot5 | 3.842 | 99.95 | 0.0 | 25.82 | 26.38 | 6.7x |
| 800x480 | rot15 | 4.097 | 93.72 | 6.2 | 24.61 | 25.13 | 6.0x |
| 800x480 | rot37 | 6.647 | 57.77 | 42.0 | 23.30 | 23.76 | 3.5x |
| 800x480 | scale0p8 | 3.842 | 99.95 | 0.0 | 18.78 | 19.12 | 4.9x |
| 800x480 | scale1p25 | 3.842 | 99.95 | 0.0 | 25.59 | 26.14 | 6.7x |
| 800x480 | combined | 3.842 | 99.95 | 0.0 | 22.99 | 23.45 | 6.0x |
| 800x480 | rot90 | 7.824 | 49.08 | 50.2 | 18.51 | 18.86 | 2.4x |
| 800x480 | rot180 | 3.842 | 99.95 | 0.0 | 25.94 | 26.53 | 6.8x |
| 2448x2095 | identity | 51.288 | 100.00 | 0.0 | 342.91 | 350.28 | 6.7x |
| 2448x2095 | mirror_cols | 51.288 | 100.00 | 0.0 | 350.35 | 358.27 | 6.8x |
| 2448x2095 | mirror_rows | 51.288 | 100.00 | 0.0 | 344.87 | 352.50 | 6.7x |
| 2448x2095 | rot5 | 51.288 | 100.00 | 0.0 | 352.43 | 359.78 | 6.9x |
| 2448x2095 | rot15 | 56.857 | 90.20 | 9.8 | 342.34 | 349.35 | 6.0x |
| 2448x2095 | rot37 | 95.917 | 53.47 | 46.5 | 363.13 | 369.50 | 3.8x |
| 2448x2095 | scale0p8 | 51.288 | 100.00 | 0.0 | 250.61 | 255.16 | 4.9x |
| 2448x2095 | scale1p25 | 51.288 | 100.00 | 0.0 | 341.42 | 348.79 | 6.7x |
| 2448x2095 | combined | 51.290 | 99.99 | 0.0 | 315.22 | 321.45 | 6.1x |
| 2448x2095 | rot90 | 135.006 | 37.99 | 61.9 | 449.46 | 456.46 | 3.3x |
| 2448x2095 | rot180 | 51.288 | 100.00 | 0.0 | 347.85 | 355.72 | 6.8x |

Sources: `results/board/run_all_revd_bayer_a_gray_eth.csv`, `run_all_revd_sw_patrm_app.csv`, `run_all_revd_sw_patrm_app_o3.csv` (also `run_all_revd_bayer_a_gray_eth_sw_patrm_eth.csv`: ARM over Ethernet, same times within about 2 %).

## 4. Bayer Option A on the board (engine time, Ethernet run)

| Size | Image | Transform | Engine ms | fps (engine) | Mpix/s | RD stall % | BYTES_RD | BYTES_WR |
|---|---|---|---|---|---|---|---|---|
| 480x272 | chart | identity | 1.313 | 761.4 | 99.41 | 0.2 | 546336 | 261120 |
| 480x272 | chart | mirror_cols | 1.313 | 761.5 | 99.42 | 0.2 | 546336 | 261120 |
| 480x272 | chart | mirror_rows | 1.313 | 761.6 | 99.44 | 0.2 | 544320 | 261120 |
| 480x272 | chart | rot5 | 1.312 | 762.1 | 99.50 | 0.1 | 671304 | 261120 |
| 480x272 | chart | rot15 | 1.773 | 564.0 | 73.63 | 26.1 | 897152 | 261120 |
| 480x272 | chart | rot37 | 2.448 | 408.5 | 53.33 | 46.5 | 974752 | 261120 |
| 480x272 | chart | scale0p8 | 1.314 | 761.3 | 99.39 | 0.2 | 435456 | 261120 |
| 480x272 | chart | scale1p25 | 1.313 | 761.6 | 99.44 | 0.2 | 461312 | 261120 |
| 480x272 | chart | combined | 1.398 | 715.4 | 93.40 | 6.3 | 750680 | 261120 |
| 480x272 | chart | rot90 | 2.652 | 377.1 | 49.23 | 50.3 | 739840 | 261120 |
| 480x272 | chart | rot180 | 1.313 | 761.6 | 99.44 | 0.2 | 544320 | 261120 |
| 480x272 | photo | identity | 1.313 | 761.5 | 99.42 | 0.2 | 546336 | 261120 |
| 480x272 | photo | mirror_cols | 1.313 | 761.6 | 99.44 | 0.2 | 546336 | 261120 |
| 480x272 | photo | mirror_rows | 1.313 | 761.6 | 99.44 | 0.2 | 544320 | 261120 |
| 480x272 | photo | rot5 | 1.312 | 762.1 | 99.50 | 0.1 | 671304 | 261120 |
| 480x272 | photo | rot15 | 1.774 | 563.9 | 73.62 | 26.1 | 897152 | 261120 |
| 480x272 | photo | rot37 | 2.449 | 408.3 | 53.31 | 46.5 | 974752 | 261120 |
| 480x272 | photo | scale0p8 | 1.313 | 761.4 | 99.41 | 0.2 | 435456 | 261120 |
| 480x272 | photo | scale1p25 | 1.313 | 761.6 | 99.44 | 0.2 | 461312 | 261120 |
| 480x272 | photo | combined | 1.397 | 715.6 | 93.43 | 6.2 | 750680 | 261120 |
| 480x272 | photo | rot90 | 2.654 | 376.8 | 49.20 | 50.3 | 739840 | 261120 |
| 480x272 | photo | rot180 | 1.313 | 761.5 | 99.42 | 0.2 | 544320 | 261120 |
| 800x480 | chart | identity | 3.848 | 259.9 | 99.80 | 0.1 | 1624768 | 768000 |
| 800x480 | chart | mirror_cols | 3.848 | 259.9 | 99.81 | 0.1 | 1624768 | 768000 |
| 800x480 | chart | mirror_rows | 3.847 | 259.9 | 99.81 | 0.1 | 1621376 | 768000 |
| 800x480 | chart | rot5 | 3.846 | 260.0 | 99.84 | 0.0 | 1975496 | 768000 |
| 800x480 | chart | rot15 | 5.356 | 186.7 | 71.70 | 28.2 | 2658600 | 768000 |
| 800x480 | chart | rot37 | 7.569 | 132.1 | 50.73 | 49.2 | 2938560 | 768000 |
| 800x480 | chart | scale0p8 | 3.848 | 259.9 | 99.79 | 0.1 | 1290240 | 768000 |
| 800x480 | chart | scale1p25 | 3.847 | 259.9 | 99.81 | 0.1 | 1367040 | 768000 |
| 800x480 | chart | combined | 4.178 | 239.3 | 91.90 | 8.0 | 2229120 | 768000 |
| 800x480 | chart | rot90 | 8.092 | 123.6 | 47.46 | 51.4 | 2304000 | 768000 |
| 800x480 | chart | rot180 | 3.847 | 259.9 | 99.81 | 0.1 | 1621376 | 768000 |
| 800x480 | photo | identity | 3.848 | 259.9 | 99.80 | 0.1 | 1624768 | 768000 |
| 800x480 | photo | mirror_cols | 3.847 | 259.9 | 99.81 | 0.1 | 1624768 | 768000 |
| 800x480 | photo | mirror_rows | 3.847 | 259.9 | 99.81 | 0.1 | 1621376 | 768000 |
| 800x480 | photo | rot5 | 3.846 | 260.0 | 99.85 | 0.0 | 1975496 | 768000 |
| 800x480 | photo | rot15 | 5.356 | 186.7 | 71.70 | 28.2 | 2658600 | 768000 |
| 800x480 | photo | rot37 | 7.570 | 132.1 | 50.72 | 49.2 | 2938560 | 768000 |
| 800x480 | photo | scale0p8 | 3.848 | 259.9 | 99.80 | 0.1 | 1290240 | 768000 |
| 800x480 | photo | scale1p25 | 3.847 | 259.9 | 99.81 | 0.1 | 1367040 | 768000 |
| 800x480 | photo | combined | 4.180 | 239.3 | 91.87 | 8.0 | 2229120 | 768000 |
| 800x480 | photo | rot90 | 8.088 | 123.6 | 47.48 | 51.3 | 2304000 | 768000 |
| 800x480 | photo | rot180 | 3.848 | 259.9 | 99.80 | 0.1 | 1621376 | 768000 |
| 2448x2048 | chart | identity | 50.143 | 19.9 | 99.98 | 0.0 | 21288800 | 10027008 |
| 2448x2048 | chart | mirror_cols | 50.143 | 19.9 | 99.98 | 0.0 | 21288800 | 10027008 |
| 2448x2048 | chart | mirror_rows | 50.143 | 19.9 | 99.98 | 0.0 | 21278400 | 10027008 |
| 2448x2048 | chart | rot5 | 50.142 | 19.9 | 99.99 | 0.0 | 25880296 | 10027008 |
| 2448x2048 | chart | rot15 | 73.670 | 13.6 | 68.05 | 31.9 | 35422000 | 10027008 |
| 2448x2048 | chart | rot37 | 109.934 | 9.1 | 45.60 | 54.4 | 40789920 | 10027008 |
| 2448x2048 | chart | scale0p8 | 50.144 | 19.9 | 99.98 | 0.0 | 16857344 | 10027008 |
| 2448x2048 | chart | scale1p25 | 50.143 | 19.9 | 99.98 | 0.0 | 17629184 | 10027008 |
| 2448x2048 | chart | combined | 58.220 | 17.2 | 86.11 | 13.9 | 29700104 | 10027008 |
| 2448x2048 | chart | rot90 | 132.955 | 7.5 | 37.71 | 62.1 | 41943040 | 10027008 |
| 2448x2048 | chart | rot180 | 50.143 | 19.9 | 99.98 | 0.0 | 21278400 | 10027008 |
| 2448x2048 | photo | identity | 50.143 | 19.9 | 99.98 | 0.0 | 21288800 | 10027008 |
| 2448x2048 | photo | mirror_cols | 50.143 | 19.9 | 99.98 | 0.0 | 21288800 | 10027008 |
| 2448x2048 | photo | mirror_rows | 50.143 | 19.9 | 99.98 | 0.0 | 21278400 | 10027008 |
| 2448x2048 | photo | rot5 | 50.142 | 19.9 | 99.99 | 0.0 | 25880296 | 10027008 |
| 2448x2048 | photo | rot15 | 73.664 | 13.6 | 68.06 | 31.9 | 35422000 | 10027008 |
| 2448x2048 | photo | rot37 | 109.951 | 9.1 | 45.60 | 54.4 | 40789920 | 10027008 |
| 2448x2048 | photo | scale0p8 | 50.143 | 19.9 | 99.98 | 0.0 | 16857344 | 10027008 |
| 2448x2048 | photo | scale1p25 | 50.143 | 19.9 | 99.98 | 0.0 | 17629184 | 10027008 |
| 2448x2048 | photo | combined | 58.223 | 17.2 | 86.11 | 13.9 | 29700104 | 10027008 |
| 2448x2048 | photo | rot90 | 132.954 | 7.5 | 37.71 | 62.1 | 41943040 | 10027008 |
| 2448x2048 | photo | rot180 | 50.143 | 19.9 | 99.98 | 0.0 | 21278400 | 10027008 |

No ARM Bayer baseline exists yet (the ARM software is grayscale only). Source: `results/board/run_all_revd_bayer_a_bayer_a_eth.csv`.

## 5. Comparison with the paper (2448x2095 grayscale)

| | Paper [1] | This project |
|---|---|---|
| Frame time (FPGA) | 40 ms (25 fps) | 51.29 ms (19.5 fps), identity |
| Throughput | about 128 Mpixel/s | 100.00 Mpixel/s (about 1 pixel per clock at 100 MHz) |
| ARM software, same image | 157.68 ms | 342.9 ms (-O2, Cortex-A9 650 MHz, fixed point) |

Paper figures as quoted in docs/implementation-plan.md step 7.4; check them against the paper before publishing.

## 6. Links, video and clock

### Ethernet echo / sink / source

```
ping 192.168.1.10: OK ['1', '1', '1'] ms
echo 1 MB run  1: identical  4.044 s  0.25 MB/s each direction
echo 1 MB run  2: identical  1.264 s  0.79 MB/s each direction
echo 1 MB run  3: identical  1.257 s  0.80 MB/s each direction
echo 1 MB run  4: identical  3.424 s  0.29 MB/s each direction
echo 1 MB run  5: identical  0.639 s  1.57 MB/s each direction
echo 1 MB run  6: identical  2.801 s  0.36 MB/s each direction
echo 1 MB run  7: identical  4.667 s  0.21 MB/s each direction
echo 1 MB run  8: identical  0.326 s  3.07 MB/s each direction
echo 1 MB run  9: identical  3.426 s  0.29 MB/s each direction
echo 1 MB run 10: identical  0.321 s  3.12 MB/s each direction
echo 5 MB run  1: identical  6.280 s  0.80 MB/s each direction
echo 5 MB run  2: identical  18.996 s  0.26 MB/s each direction
echo 5 MB run  3: identical  1.025 s  4.88 MB/s each direction
echo 5 MB run  4: identical  9.055 s  0.55 MB/s each direction
echo 5 MB run  5: identical  2.245 s  2.23 MB/s each direction
echo 5 MB run  6: identical  3.177 s  1.57 MB/s each direction
echo 5 MB run  7: identical  1.649 s  3.03 MB/s each direction
echo 5 MB run  8: identical  0.735 s  6.80 MB/s each direction
echo 5 MB run  9: identical  4.436 s  1.13 MB/s each direction
echo 5 MB run 10: identical  1.959 s  2.55 MB/s each direction
GEM0 counters over the echo runs: frames_tx 58291; nonzero error counters: {'rx_overruns': 1023}
SUMMARY echo 1 MB: 10 of 10 identical; MB/s min 0.21 median 0.79 max 3.12
SUMMARY echo 5 MB: 10 of 10 identical; MB/s min 0.26 median 2.23 max 6.80
sink 1 MB run  1: identical  0.009 s  107.23 MB/s PC->board
sink 1 MB run  2: identical  0.009 s  106.41 MB/s PC->board
sink 1 MB run  3: identical  0.009 s  108.95 MB/s PC->board
sink 1 MB run  4: identical  0.009 s  106.28 MB/s PC->board
sink 1 MB run  5: identical  0.009 s  105.49 MB/s PC->board
sink 1 MB run  6: identical  0.009 s  107.99 MB/s PC->board
sink 1 MB run  7: identical  0.009 s  107.93 MB/s PC->board
sink 1 MB run  8: identical  0.009 s  106.15 MB/s PC->board
sink 1 MB run  9: identical  0.010 s  104.41 MB/s PC->board
sink 1 MB run 10: identical  0.009 s  108.64 MB/s PC->board
sink 5 MB run  1: identical  0.046 s  108.90 MB/s PC->board
sink 5 MB run  2: identical  0.046 s  109.16 MB/s PC->board
sink 5 MB run  3: identical  0.046 s  107.54 MB/s PC->board
sink 5 MB run  4: identical  0.046 s  109.41 MB/s PC->board
sink 5 MB run  5: identical  0.051 s  97.26 MB/s PC->board
sink 5 MB run  6: identical  0.046 s  107.78 MB/s PC->board
sink 5 MB run  7: identical  0.047 s  107.32 MB/s PC->board
sink 5 MB run  8: identical  0.046 s  109.09 MB/s PC->board
sink 5 MB run  9: identical  0.046 s  109.42 MB/s PC->board
sink 5 MB run 10: identical  0.046 s  109.43 MB/s PC->board
GEM0 counters over the sink runs: frames_tx 21802; nonzero error counters: none
SUMMARY sink 1 MB: 10 of 10 identical; MB/s min 104.41 median 107.23 max 108.95
SUMMARY sink 5 MB: 10 of 10 identical; MB/s min 97.26 median 109.09 max 109.43
source 1 MB run  1: identical  0.010 s  95.58 MB/s board->PC
source 1 MB run  2: identical  0.010 s  97.16 MB/s board->PC
source 1 MB run  3: identical  0.010 s  96.63 MB/s board->PC
source 1 MB run  4: identical  0.011 s  93.19 MB/s board->PC
source 1 MB run  5: identical  0.010 s  98.36 MB/s board->PC
source 1 MB run  6: identical  0.010 s  98.33 MB/s board->PC
source 1 MB run  7: identical  0.010 s  98.61 MB/s board->PC
source 1 MB run  8: identical  0.010 s  97.04 MB/s board->PC
source 1 MB run  9: identical  0.010 s  97.87 MB/s board->PC
source 1 MB run 10: identical  0.011 s  94.85 MB/s board->PC
source 5 MB run  1: identical  0.051 s  98.48 MB/s board->PC
source 5 MB run  2: identical  0.051 s  97.57 MB/s board->PC
source 5 MB run  3: identical  0.051 s  98.20 MB/s board->PC
source 5 MB run  4: identical  0.051 s  97.40 MB/s board->PC
source 5 MB run  5: identical  0.051 s  98.95 MB/s board->PC
source 5 MB run  6: identical  0.050 s  99.14 MB/s board->PC
source 5 MB run  7: identical  0.050 s 
```
Source: `results/eth/echo_2026-11-23_105757.txt`.

### Video stream, FPGA vs ARM (step 10.3)

```
video_matrix (step 10.3), 2026-11-23 13:25, frames data/gen/burst_800x480 (cover-cropped to each size), 100 frames per run, one frame at a time, every frame checked

size     transform engine     fps  engine ms  board job ms  round trip ms  bit-exact
800x480  identity  fpga      41.1       3.84          6.09          18.78  100 of 100
800x480  identity  arm       25.7      25.70         27.77          36.95  100 of 100
800x480  spin      fpga      40.6       7.44          9.69          18.32  100 of 100
800x480  spin      arm       27.5      22.20         24.31          34.25  100 of 100
640x480  identity  fpga      52.2       3.07          4.91          12.16  100 of 100
640x480  identity  arm       31.3      20.57         22.31          29.95  100 of 100
640x480  spin      fpga      45.4       6.15          7.99          17.79  100 of 100
640x480  spin      arm       34.6      18.41         20.16          27.29  100 of 100
480x272  identity  fpga      95.3       1.31          2.11           6.79  100 of 100
480x272  identity  arm       67.5       8.74          9.55          12.50  100 of 100
480x272  spin      fpga      91.2       2.46          3.26           7.42  100 of 100
480x272  spin      arm       71.2       7.18          7.98          12.12  100 of 100

VIDEO_MATRIX PASS
```
Source: `results/eth/video_matrix_2026-11-23_132556.txt`.

### Clock check (step 7.1)

```
step 7.1 clock check, 2026-11-27 20:59:13: board Rev D, link eth, sizes 128x96, 480x272, 800x480, 1920x1080, 2448x2095, N = 10, global timer 3 samples 30 s apart, limit 0.1%

--- 1. clock configuration (SLCR registers, through core 1)
  ARM_PLL_CTRL    0x00027008
  DDR_PLL_CTRL    0x00020008
  IO_PLL_CTRL     0x0001E008
  ARM_CLK_CTRL    0x1F000200
  FPGA0_CLK_CTRL  0x00200500
  CLK_621_TRUE    0x00000001
  GT_CONTROL      0x00000001
  PLLs (PS_CLK 33.333333 MHz): ARM 1300.000 MHz (FDIV 39), DDR 1066.667 MHz, IO 1000.000 MHz (FDIV 30)
  CPU_6x4x 650.000 MHz (ARM PLL / 2), ratio 6:2:1, global timer = CPU_3x2x 325.000 MHz (enabled: yes)
  FCLK0 100.000000 MHz (IO PLL / 5 / 2)

--- 2. global timer against the PC clock
  host 1795793357.400468 s (read window 1213 us), count 194598170364
  host 1795793387.493865 s (read window 2223 us), count 204378419724
  host 1795793417.602984 s (read window 7456 us), count 214165490838
  measured 325.008111 MHz over 60.2 s, nominal 325.000000 MHz: +0.00250% (read-window bound +-0.01238%; the PC clock itself is typically within 0.01 %)

--- 3. PL clock against the global timer (identity jobs, photo, N = 10)
  128x96     CYCLES avg     12465 (min 12462, max 12470), engine avg     125.002 us, ratio 99.7184 cycles/us
  480x272    CYCLES avg    130730 (min 130723, max 130738), engine avg    1307.681 us, ratio 99.9709 cycles/us
  800x480    CYCLES avg    384165 (min 384161, max 384171), engine avg    3841.997 us, ratio 99.9910 cycles/us
  1920x1080  CYCLES avg   2073780 (min 2073776, max 2073782), engine avg   20738.177 us, ratio 99.9982 cycles/us
  2448x2095  CYCLES avg   5128743 (min 5128742, max 5128745), engine avg   51287.775 us, ratio 99.9993 cycles/us
  line fit: engine time = CYCLES / 100.000025 MHz + 0.364 us (fixed START/poll overhead), largest residual 0.018 us
  PL clock in global-timer time: 100.000025 MHz (+0.00003% from 100 MHz)
  PL clock in PC time:           100.002521 MHz (+0.00252% from 100 MHz)

CLOCK CHECK PASS
```
Source: `results/board/step7_1/clock_check_2026-11-27_205913.txt`.

## 7. Option B study (why it is not the better method)

Original B (one read in flight), simulation at equal clock, every frame bit-exact:

```
Option A vs Option B, simulation, 256x192, BLOCK_LEN 64, memory latency 20, no back-pressure (scripts/compare_bayer_ab.py)

transform     gray cyc     A cyc     B cyc    B/A  A px/clk  B px/clk  A BYTES_RD  B BYTES_RD  A RD_STALL  B RD_STALL
identity         49315     49868     54473   1.09     0.986     0.902      201696      100848         228       29798
mirror_cols      49315     49868     54855   1.10     0.986     0.896      201696      103904         228       30180
rot5             49303     49764    181500   3.65     0.988     0.271      254880      142688         124      155280
rot15            51937     65510    380191   5.80     0.750     0.129      343928      203728       15880      351168
rot37            84623     93846    537037   5.72     0.524     0.092      390304      244512       44263      502538
rot90           108427    103384    521859   5.05     0.475     0.094      368640      221184       53931      488064
scale0p8         49317     49860     48163   0.97     0.986     1.021      155648       77824         220       23408
scale1p25        49313     49844     52707   1.06     0.986     0.933      172032       86016         204       28032
combined         49301     51298    319232   6.22     0.958     0.154      283296      182800        1658      291360

B/A < 1: Option B faster. TEST PASS (every frame bit-exact)
```
Source: `results/sim/bayer_ab_256x192.txt`.

After stage 1 (reads issued back to back, 2026-11-27), same settings, every frame bit-exact:

```
Option A vs Option B, simulation, 256x192, BLOCK_LEN 64, memory latency 20, no back-pressure (scripts/compare_bayer_ab.py)

transform     gray cyc     A cyc     B cyc    B/A  A px/clk  B px/clk  A BYTES_RD  B BYTES_RD  A RD_STALL  B RD_STALL
identity         49315     49868     41889   0.84     0.986     1.173      201696      100848         228       17214
mirror_cols      49315     49868     42271   0.85     0.986     1.163      201696      103904         228       17596
rot5             49303     49764     86790   1.74     0.988     0.566      254880      142688         124       58356
rot15            51937     65510    159514   2.43     0.750     0.308      343928      203728       15880      128031
rot37            84623     93846    261999   2.79     0.524     0.188      390304      244512       44263      225431
rot90           108427    103384    318707   3.08     0.475     0.154      368640      221184       53931      283200
scale0p8         49317     49860     38131   0.76     0.986     1.289      155648       77824         220       13376
scale1p25        49313     49844     40035   0.80     0.986     1.228      172032       86016         204       15360
combined         49301     51298    134038   2.61     0.958     0.367      283296      182800        1658      104044

B/A < 1: Option B faster. TEST PASS (every frame bit-exact)
```
Source: `results/sim/bayer_ab_256x192_stage1.txt`.

Team decision 2026-11-27: Option B is presented as a measured design study with the stage 1 result. B beats A when the transform has no rotation (b12 = 0: identity, mirror, scaling; B/A 0.76-0.85, half the bytes read) and loses on every rotation (B/A 1.7-3.1): the source row changes every 1-2 output pixels, each block pays one memory latency, and B does not fetch across blocks the way A's prefetch does. Not pursued: bigger B blocks (about A's speed on rotations) and A-style deep prefetch plus timing closure (estimated ceiling about 2-3x A).

Hardware build at 100 MHz: WNS -46.129 ns, TNS -31963.963 (4392 failing of 22521 endpoints); 11575 LUT, 6411 FF, 42 BRAM36, 54 DSP (Option A: see section 1). Not loaded on the board.

Why the original B was not faster (details: `results/hw/bayer_b/rev_d/README.md`, plan Progress 2026-11-23):
1. Serial window fetch: `bayer_store` requests one missing source window and waits for its last beat before the next, so DDR latency is paid per window; read stall 30-94 % of cycles (A keeps up to 8 reads in flight).
2. Four lanes, but never more than about 1 output pixel per clock: the lanes starve waiting for data.
3. Timing: the fallback's 16-step compare chain in one clock (86 logic levels, 55.7 ns) and mode multiplexers that also slow the shared gray/A paths; implied clock about 18 MHz (estimate).
4. Cost: about 3.9x the LUTs, 5x the BRAM and 3x the DSP of Option A for no speed gain.

### Option B on the board (stage 1 RTL at 11.9 MHz) vs Option A (100 MHz), chart image

Both bit-exact. CAUTION: at 11.9 MHz a DDR access costs about 8x fewer clocks than at 100 MHz, so the board's B/A cycle ratio flatters B on the latency-bound rotations; the equal-clock comparison is the simulation above.

| Size | Transform | A cycles | B cycles | B/A cycles | A ms (100 MHz) | B ms (11.9 MHz) | A BYTES_RD | B BYTES_RD | B RD stall % |
|---|---|---|---|---|---|---|---|---|---|
| 480x272 | identity | 131294 | 106668 | 0.81 | 1.31 | 9.0 | 546336 | 273168 | 38.7 |
| 480x272 | mirror_cols | 131292 | 108285 | 0.82 | 1.31 | 9.1 | 546336 | 286176 | 39.6 |
| 480x272 | mirror_rows | 131258 | 123651 | 0.94 | 1.31 | 10.4 | 544320 | 409248 | 47.1 |
| 480x272 | rot5 | 131171 | 185919 | 1.42 | 1.31 | 15.6 | 671304 | 375728 | 56.2 |
| 480x272 | rot15 | 177267 | 309611 | 1.75 | 1.77 | 26.0 | 897152 | 533280 | 71.4 |
| 480x272 | rot37 | 244794 | 482121 | 1.97 | 2.45 | 40.5 | 974752 | 608128 | 79.1 |
| 480x272 | scale0p8 | 131326 | 100000 | 0.76 | 1.31 | 8.4 | 435456 | 217728 | 32.8 |
| 480x272 | scale1p25 | 131264 | 101340 | 0.77 | 1.31 | 8.5 | 461312 | 230656 | 35.4 |
| 480x272 | combined | 139754 | 268168 | 1.92 | 1.40 | 22.5 | 750680 | 486080 | 68.3 |
| 480x272 | rot90 | 265160 | 459286 | 1.73 | 2.65 | 38.6 | 739840 | 443904 | 80.3 |
| 480x272 | rot180 | 131269 | 126160 | 0.96 | 1.31 | 10.6 | 544320 | 428736 | 48.1 |
| 800x480 | identity | 384720 | 329319 | 0.86 | 3.85 | 27.7 | 1624768 | 812384 | 37.5 |
| 800x480 | mirror_cols | 384722 | 335081 | 0.87 | 3.85 | 28.1 | 1624768 | 858368 | 38.6 |
| 800x480 | mirror_rows | 384718 | 371809 | 0.97 | 3.85 | 31.2 | 1621376 | 1217728 | 46.8 |
| 800x480 | rot5 | 384560 | 553495 | 1.44 | 3.85 | 46.5 | 1975496 | 1108640 | 55.8 |
| 800x480 | rot15 | 535562 | 922290 | 1.72 | 5.36 | 77.5 | 2658600 | 1581552 | 71.2 |
| 800x480 | rot37 | 756919 | 1452128 | 1.92 | 7.57 | 122.0 | 2938560 | 1825152 | 79.1 |
| 800x480 | scale0p8 | 384750 | 313145 | 0.81 | 3.85 | 26.3 | 1290240 | 645120 | 30.5 |
| 800x480 | scale1p25 | 384700 | 316080 | 0.82 | 3.85 | 26.6 | 1367040 | 683520 | 34.0 |
| 800x480 | combined | 417813 | 799111 | 1.91 | 4.18 | 67.1 | 2229120 | 1446336 | 68.1 |
| 800x480 | rot90 | 809153 | 1434425 | 1.77 | 8.09 | 120.5 | 2304000 | 1382400 | 80.3 |
| 800x480 | rot180 | 384720 | 380424 | 0.99 | 3.85 | 32.0 | 1621376 | 1286656 | 48.0 |
| 2448x2048 | identity | 5014299 | 4584208 | 0.91 | 50.14 | 385.1 | 21288800 | 10644400 | 34.8 |
| 2448x2048 | mirror_cols | 5014290 | 4662605 | 0.93 | 50.14 | 391.7 | 21288800 | 11266688 | 35.9 |
| 2448x2048 | mirror_rows | 5014282 | 5214414 | 1.04 | 50.14 | 438.0 | 21278400 | 15964000 | 43.4 |
| 2448x2048 | rot5 | 5014144 | 7306601 | 1.46 | 50.14 | 613.8 | 25880296 | 14513424 | 55.5 |
| 2448x2048 | rot15 | 7366959 | 12316745 | 1.67 | 73.67 | 1034.6 | 35422000 | 21071904 | 71.2 |
| 2448x2048 | rot37 | 10993365 | 20123911 | 1.83 | 109.93 | 1690.4 | 40789920 | 25369792 | 79.5 |
| 2448x2048 | scale0p8 | 5014312 | 4315751 | 0.86 | 50.14 | 362.5 | 16857344 | 8428672 | 28.6 |
| 2448x2048 | scale1p25 | 5014270 | 4368489 | 0.87 | 50.14 | 367.0 | 17629184 | 8814592 | 31.3 |
| 2448x2048 | combined | 5821974 | 10659583 | 1.83 | 58.22 | 895.4 | 29700104 | 19291104 | 67.9 |
| 2448x2048 | rot90 | 13295481 | 25152089 | 1.89 | 132.96 | 2112.8 | 41943040 | 25165824 | 83.6 |
| 2448x2048 | rot180 | 5014287 | 5331579 | 1.06 | 50.14 | 447.9 | 21278400 | 16897280 | 44.6 |

Sources: `results/board/run_all_revd_bayer_b_bayer_b_eth_rev_d_12mhz.csv`, `results/board/run_all_revd_bayer_a_bayer_a_eth.csv`, `results/hw/bayer_b/rev_d_12mhz/README.md`. The same bitstream also ran Bayer A (66/66) and gray (33/33) bit-exact.

