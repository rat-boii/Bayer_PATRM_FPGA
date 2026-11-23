# Showing the project in the Vivado GUI (for the review)

Our builds and simulations run from Tcl and Python scripts so that they are reproducible, but every one of them opens in
the Vivado GUI. Two demos, about 10 minutes together:

- **A. The hardware design:** block design, the engine's place in it, post-route device view, timing and resources.
- **B. A single-image transformation testbench:** one real photo through the whole engine RTL in the Vivado simulator,
  with waveforms, checked byte for byte against the Python model.

Do both once before the review: the first launch of each takes a few minutes.

## A. Hardware design in Vivado

The build script leaves a normal Vivado project behind. On this laptop:

```
vivado build/vivado/patrm_bayer_a_revd/patrm_bayer_a_revd.xpr      (Bayer A + gray build, Rev D, MDIO fixed)
vivado build/vivado/patrm_gray/patrm_gray.xpr                      (gray build)
```

(Or start Vivado 2026.1 and use File > Project > Open.) On another laptop or a fresh clone, make the project first:
`cd build/vivado`, then `vivado -mode batch -source ../../vivado/build.tcl -tclargs variant=bayer_a rev=d` (about
30 min; add `bd_only=1` to stop after the block design, a few minutes).

What to click, in this order:

1. **Flow Navigator > IP Integrator > Open Block Design.** Show: the Zynq PS (`processing_system7_0`), the AXI-Lite
   interconnect to the engine's registers (GP0), the engine `patrm_0` with its two 64-bit AXI masters into HP0 (read)
   and HP1 (write), the reset block, and the interrupt line into the PS. Double-click the Zynq block to show the PS
   settings: DDR part, 100 MHz FCLK0, ENET0 on MIO 16..27 with MDIO on MIO 52/53.
2. **Sources > Design Sources:** expand `patrm_top` to show the RTL modules (coord_gen, block_planner, prefetch_ctrl,
   line_buf, pixel_fetch, bilinear_interp, out_fifo, AXI masters, bayer_seq).
3. **Flow Navigator > Implementation > Open Implemented Design.** The Device view shows where the engine sits on the
   XC7Z020 (Ctrl+F or the Netlist tab: select `patrm_0` to highlight it).
4. **Reports:** Report Timing Summary (WNS +1.049 ns at 100 MHz for the Bayer A build), Report Utilization (about
   3,000 LUT, 4,071 FF, 8 BRAM, 17 DSP: about 6 % of the chip). The same numbers are in
   `results/hw/bayer_a/rev_d/summary.txt`.
5. Optional: Open Synthesized Design > Schematic, then select `patrm_0` to show the engine's structure.

## B. Single-image transformation testbench (Vivado simulator)

```
python scripts/demo/run_demo_sim.py                      rot15 on the test photo, 256 x 192
python scripts/demo/run_demo_sim.py --transform rot37    any name from model/transforms.json
python scripts/demo/run_demo_sim.py --batch              same run without the GUI (SIM RESULT: PASS)
```

What happens (about 1-2 minutes): the script makes one test case from the photo (`scripts/demo/make_demo_case.py`):
source image, the Python model's expected output, and the predicted counters; then compiles the engine RTL and the
testbench with Vivado's xvlog/xelab, opens the **Vivado simulator GUI**, adds the waveforms
(`scripts/demo/demo_wave.tcl`) and runs the frame to the end.

In the GUI:

1. The Tcl Console (bottom) ends with the testbench summary: `total 1 frames, 49152 output bytes compared with the
   model`, `errors: checks 0 ...`, **`TEST PASS`**. Scroll up a little for the frame line: CYCLES about 51,900,
   about 0.95 pixels per clock, BYTES_RD equal to the prediction.
2. The editor jumps to `$finish` in the testbench: click the **"Untitled 1"** tab next to it. That is the wave window.
3. Press **Zoom Fit** (the toolbar button, or Ctrl+0). The whole frame is visible: `busy` high for about 520 us.
4. Zoom in on any part to show the pipeline at work, group by group:

| Group | What to point at |
| --- | --- |
| 1 Control | `start_accept` (the ARM-side START write), `busy` for the whole frame, `done_set` and `interrupt` at the end |
| 2 Coordinates | `pix_X`, `pix_Y`: source row and column of each output pixel in Q15.16 (divide by 65536); they change by a constant step along a block: addition only, as in the paper |
| 3 Bilinear | the fractions `ip_xf`, `ip_yf`, the four neighbours `ip_r1..r4`, and the output pixel `op_d` a few clocks later |
| 4 AXI to DDR | HP0 read bursts (`arvalid`, `araddr`, `arlen`, `rvalid`) of source rows, HP1 write bursts of output pixels (`awaddr`, `wdata`, 8 pixels per beat) |
| 5 Counters | `cnt_cycles`, `cnt_bytes_rd`, `cnt_bytes_wr` counting up to their final values |

5. Show the pictures: `data/vectors_demo/source.png` (the input) and `data/vectors_demo/expected.png` (the model's
   output). The testbench has just checked that the RTL's output equals `expected.png` in all 49,152 bytes, so this is
   also what the hardware produced.

Points to make: the same RTL is in the bitstream on the board; the board result matched the same model bit-exactly
(steps 4.3 and 10.2); the testbench also checks the AXI protocol, burst addresses inside the image areas and the
counters against the memory model's predictions.

Close the simulator when done (its files are in `build/sim/tb_patrm_top/`, regenerated each run).
