# Bayer Option B, Rev D: first post-route build (step 6.3), 23 November 2026

Status: **TIMING FAILED at 100 MHz. Do not load this bitstream.** The build script stopped at its timing check
(`CHECK FAILED timing: WNS = -46.129`). The .bit and .xsa were written before that check and are not tracked in git.

Build: `vivado -mode batch -source ../../vivado/build.tcl -tclargs variant=bayer_b rev=d`, Vivado 2026.1, main after
ec07477, RTL of steps 6.1/6.2 unchanged (MODES 7 = gray + A + B, BUILD_TYPE 2, ENABLE_FALLBACK on), 100 MHz (D8), no ILA.

## Timing (post-route, summary.txt)

- WNS -46.129 ns, TNS -31,964 ns, 4,392 of 22,521 endpoints failing; WHS +0.001 ns.
- Worst path: option_b.engine state -> run_first, 86 logic levels (41 CARRY4), 55.7 ns. It is the fallback's
  "smallest word" search in rtl/bayer_lanes.v: 16 chained 21-bit compare/select steps in one clock, fed by the lane
  coordinates.
- Failing endpoints by block (worst slack): fallback run_first/run_last -46.1 ns; B scan/coordinates (coords, xs/ys,
  block_lo/hi, key_lo/hi, scan_row/col) -19.6 to -22.2 ns; bayer_store 1,808 endpoints, -18.5 ns; AXI read master
  -14.6 ns; B interpolator inputs (xf_q, yf_q, lanes) -12.8 to -13.7 ns; bayer_merge -4.3 ns; shared gray/A modules
  (block_planner, prefetch_ctrl, axi_wr_master, pixel_fetch, axil_regs) -2.3 to -3.3 ns.
- Start points: 1,616 failing paths start at u_regs/ctrl_mode (mode multiplexers into the shared datapath), 1,146 at
  the B controller state, 664 at its pos register. So the B build also slows the gray and A paths.
- Rough implied clock: about 1 / (10 + 46.1) ns = 18 MHz (estimate from WNS; not a closed design).

## Resources (post-route, whole design)

11,575 LUT (21.8 %), 6,411 FF, 42 RAMB36 (30 %), 54 DSP48E1 (24.6 %), 0 latches. Engine alone: 11,203 LUT,
5,952 FF, 42 RAMB36, 54 DSP. Compare Option A build: 2,989 LUT, 4,071 FF, 8 RAMB36, 17 DSP.

## Speed (simulation, results/sim/bayer_ab_256x192.txt)

Bit-exact, but at the same 100 MHz cycle count B is 0.97-1.10x A for identity/scaling and 3.65-6.22x slower than A
for every rotation, because bayer_store fetches one window at a time.

Raw list of failing paths (slack, levels, start, end): build/step63_fail_paths.txt (not in git).
