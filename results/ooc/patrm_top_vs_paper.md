# Grayscale engine vs the paper (step 3.8, for the slides)

Paper: [1] PATRM, Sensors 26(1):316, 2026, on an Anlogic FPGA, numbers as given for this project. Ours: `patrm_top` on
xc7z020clg484-1, out-of-context post-route (`patrm_top_summary.txt`), speed from simulation (`tb_patrm_top`).

| | Paper [1] | This work |
|---|---|---|
| Device | Anlogic FPGA | Xilinx Zynq-7020 (ZedBoard) |
| LUT | 2,934 | 2,301 (4.33 %), of which 251 used as memory |
| FF | not in our comparison data | 3,475 (3.27 %) |
| Embedded RAM | 66 | 8 RAMB36 (5.71 %) |
| DSP | 17 | 17 DSP48E1 (7.73 %) |
| Clock | 200 MHz | 100 MHz (fixed by D8; WNS +1.634 ns, WHS +0.026 ns) |
| Implied Fmax | not applicable | about 119.5 MHz, ESTIMATE from WNS, no run at that clock |
| px/clk | about 0.64, measured on hardware | 0.25 to 0.997, **simulation only until step 4.3** (table below) |
| Throughput | 128.21 Mpix/s, measured on hardware | 25.3 to 99.7 Mpix/s at 100 MHz, **from simulation** |

Our speed, 256x192, BLOCK_LEN 64, simulated memory (latency L cycles on reads and on write responses, no back-pressure).
Mpix/s = px/clk x 100 MHz.

| Transform | L = 20: px/clk | Mpix/s | L = 40: px/clk | Mpix/s |
|---|---|---|---|---|
| identity | 0.997 | 99.7 | 0.996 | 99.6 |
| mirror_cols, mirror_rows | 0.997 | 99.7 | 0.996 | 99.6 |
| rot15 | 0.946 | 94.6 | 0.544 | 54.4 |
| rot37 | 0.581 | 58.1 | 0.327 | 32.7 |
| rot90 | 0.453 | 45.3 | 0.253 | 25.3 |

## How to read it

- Throughput: at 100 MHz this engine stays below the paper's 128.21 Mpix/s in every simulated case, because it cannot
  exceed 1 pixel per clock. Per clock it is above the paper's 0.64 for identity and the mirrors (L = 20 and 40) and for
  rot15 at L = 20, and below it for rot15 at L = 40, rot37 and rot90.
- The speed figures are not like for like. Ours are simulated at 256x192 with a memory model whose latency is an
  assumption; the paper's are measured on hardware. The real HP-port latency is unknown until step 4.3.
- Anlogic and Xilinx LUT counts are only roughly comparable: the LUT structures and synthesis tools differ.
- Embedded RAM counts are not directly comparable: one RAMB36 holds 36 Kbit, and the size of the paper's RAM unit must
  be checked before comparing capacity.
- The DSP blocks are different primitives, so equal counts do not prove equal multiplier capacity.
- Our figures cover the engine with its AXI-Lite registers and both AXI masters, without the AXI interconnect, reset IP
  or PS. Check the scope of the paper's table before quoting a LUT saving on a slide.
