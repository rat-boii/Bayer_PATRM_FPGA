# Bayer-PATRM: step-by-step implementation plan (index)

Full plan with details: Claude doc https://claude.ai/artifact/GAcqfs7NKUcCbXovLP5R7t (created 2026-11-06).
Use: one prompt per step, in order. A step is done only when its Verify check passes. The Python model is the single reference; bit-exact = 0 differing bytes.

Prompt template (in the repo; the planning chat keeps its copies under claude/ in the claude.ai project):
"Step <ID>: <name>. Read CLAUDE.md and docs/implementation-plan.md. What I have from earlier steps: <...>. Produce what this step lists and give the exact commands for its Verify check. Problems so far: <logs>."

Repo layout: model/ spec/ rtl/ tb/ vivado/ sw/ scripts/ data/ results/

## Decided 2026-11-06 (step 0.1 inputs)
- Verilog-2001, xsim, Vivado/Vitis 2026.1, Windows native (WSL has no Vivado). Python scripts run on Windows.
- XSCT does not exist in 2026.1: board scripts use XSDB (Tcl, or Python XSDB); Vitis projects via the Vitis Python API (`vitis -s`).
- Claude Code runs in the repo; repo root CLAUDE.md carries the conventions (Claude Code cannot see this project).
- D1 edge rule: valid iff 0 <= x <= H-1 and 0 <= y <= W-1 (Q15.16 compare), else 0; next-row/col neighbour clamped (weight 0 there). Bayer: plane size.
- D2 t_p: from quantised Q15.16 integers, then arithmetic >>1.
- D3 sizes: gray W%8==0; Bayer W%16==0 and H even; others rejected, no padding. Tests: 480x272, 640x480, 800x480, 1920x1080, 2448x2048 (Bayer large), gray also 2448x2095 (paper size).
- D4 overflow: plain 32-bit wrap in RTL; software rejects transforms whose 4 output corners map beyond +/-16384 px.
- D5 coefficient quantisation: floor(v*65536 + 0.5). D6 Option B lane offset = register difference T_p - T_R (not (A-I)o/2 recomputed; D2 rounding can differ by 1 LSB). D7 all sizes written W x H. D8 PL clock 100 MHz for every build; 150 MHz only as an Fmax experiment in 7.3. D9 resource/timing/speed numbers from builds without the ILA (ILA = debug build option).
- b is the inverse map; PC helper builds it from forward params in float, quantises round-to-nearest; ARM never does float transform maths. Integer part = >>16 (floor).

## Open decisions (proposed defaults, not yet decided)
- 1.1: interpolator bit widths (proposed: full 16-bit fractions); block length for block-start computation.
- 1.4: largest rotation/scale the prefetch buffers support.
- 2.1: max width 4096 (BRAM sizing); who writes t_p registers (proposed: ARM, using the D2 integer formula).
- 5.1: Option A output via WSTRB-masked writes into interleaved buffer.

## Steps (Where -> Produce -> Verify)
Phase 0 Setup
- 0.1 Toolchain + repo: same tool versions; counter sims.
Board not yet available (2026-11-06): step 0.2 is split. 0.2a builds on the laptop, 0.2b and 0.3 wait for the board. Work continues with Phases 1-3, 4.1 and the new 4.1b (full-system simulation). The board must arrive before Gate 2.
- 0.2a PS-only build (laptop): Tcl Vivado project with only ZYNQ7 PS (ZedBoard preset: DDR, UART), XSA, bitstream, Vitis bare-metal hello ELF, scripts/load_run.tcl (XSDB). Needs ZedBoard Rev C board files. POSTPONED 2026-11-07 until lab access to the ZedBoard is confirmed.
- 0.2b PS-only bring-up (board): run 0.2a output; "hello" on USB-UART at 115200, boot jumpers = JTAG.
- 0.3 JTAG DDR round trip (board): put_image.tcl / get_image.tcl; 1 MB and 5 MB cmp-identical; record s/MB. Proposed buffers: src 0x1000_0000, dst 0x1800_0000.

Phase 1 Python model (laptop)
- 1.1 model/patrm.py: Q15.16, inverse coeffs, block start by multiply-add then add-only stepping (same 32-bit wrap as RTL), bilinear, truncate to 8 bits, out-of-range 0, stream dumps. Verify: worked example (3,2)->(3.2,4.4)->120; identity; integer shift; column mirror (b22=-1, b23=W-1); 5/15/37 deg vs independent float warp within small tolerance.
- 1.2 gen_images.py, transforms.json, gen_vectors.py (.hex for TBs). Sizes: 64x64, 128x96 (sim); 480x272, 640x480, 800x480, 1920x1080, 2448x2048, gray 2448x2095 (board). All W x H.
- 1.3 model/bayer.py: split, t_p, warp per plane, re-interleave. Verify: t_p vs full-res mapping on random points; t_B = (39321, 45875) Q15.16 ints from quantised b = (52429, -39322, 131072, 39322, 52429, 65536); identity; even shift; PSNR sanity only.
- 1.4 model/memmodel.py: per-block source span (Δv=1/|b12|), AXI burst list (<=16x8 B, no 4 KB crossing), ping-pong depth, predicted bytes for gray/A/B (A ~2x B reads).

Phase 2 Spec (laptop)
- 2.1 spec/regs.json -> regs.h, regs.vh, regs.py. Proposed map: 0x00 CTRL (start, mode 0/1/2, int en), 0x04 STATUS (busy, done W1C, error), 0x08/0x0C SRC/DST_ADDR, 0x10/0x14 WIDTH/HEIGHT, 0x18-0x2C B11..B23, 0x30-0x4C T_R/T_GR/T_GB/T_B (x,y), 0x50 CYCLES, 0x54/0x58 BYTES_RD/WR, 0x5C/0x60 RD/WR_STALL, 0x64 BUILD_ID. HP0 read, HP1 write, 64-bit; done interrupt -> IRQ_F2P[0].
- 2.2 spec/interface.md: ports, valid/ready, widths, latencies, truncation points; LaTeX block diagram.

Phase 3 Grayscale RTL (sim + OOC synth each)
- 3.1 axil_regs + interrupt. 3.2 coord_gen (vs coordinate dump). 3.3 bilinear_interp (100k vectors, latency 4, II 1).
- 3.4 tb/axi_mem.v + axi_rd_master (16-beat, 4 KB split, >=2 outstanding). 3.5 out_fifo + axi_wr_master (WSTRB).
- 3.6 prefetch_ctrl + ping-pong BRAM + pixel_fetch (burst list = memmodel). 3.7 ctrl_fsm + patrm_top full-frame bit-exact at 64x64/128x96/256x192, all transforms. 3.8 OOC impl, WNS>=0 at 100 MHz, utilization saved.

Phase 4 Board grayscale (= Stage 1 done)
- 4.1 vivado/build.tcl: IP + block design (with ILA on AXI; keep captures for the debugging slide), bitstream, XSA; ILA only in debug builds (D9). Needs ZedBoard board files. 4.1b full-system sim (laptop, xsim): real block design with the Zynq-7000 VIP as ARM + DDR; TB programs registers over GP0 like the driver, loads image into VIP DDR, waits for done interrupt, dumps output; Verify: bit-exact with model for >=2 transforms, interrupt fires, byte counters = 1.4 predictions. 4.2 sw/patrm_drv.c: job descriptor in DDR, cache flush/invalidate, interrupt + polling fallback, counters on UART. 4.3 run_test.tcl + run_all.py: full set bit-exact, counters = predictions. 4.4 sw/patrm_sw.c ARM baseline: laptop gcc vs Python, then A9 -O2/-O3 with XTime; bit-exact.

Phase 5 Bayer Option A
- 5.1 spec delta (plane addressing 2i+o_row, 2j+o_col; full-row read, ~2x; WSTRB writes). 5.2 bayer_seq + stride-2 select + strobe writes; sim bit-exact, gray regression passes. 5.3 board bit-exact; build "A" reports.

Phase 6 Bayer Option B
- 6.1 design: one coord_gen + per-lane constant T_p - T_R (D6); one row-pair fetch + deinterleave; 4 lanes; merge_writer full bursts; buffer covers union of footprints. 6.2 RTL; output == Option A == model. 6.3 timing closure (~32 DSP of 220, estimate); fallback A. 6.4 board; build "B" reports.

Phase 7 Proof of acceleration
- 7.1 measured PL clock vs global timer (within 0.1%). 7.2 run_all.py --measure: sizes x transforms x {gray,A,B} x {ARM -O2,-O3,PL} -> CSV (cycles, ms PL and end-to-end, Mpixel/s, fps, bytes, GB/s, stalls, match). 7.3 utilization/timing/power from builds without ILA (power = estimate). 7.4 analyze.py: speedup, A vs B, bandwidth vs HP limit, comparison with paper (25 fps ~128 Mpixel/s at the paper's 2448x2095 W x H image; ARM 157.68 ms).

Phase 8 Slides, viva, demo (course notice: no written report; marks = plan of work 2, presentation+viva 6, demo+deliverables 12): 8.1 figures, 8.2 slides in the notice's order (title; background/motivation; objectives; methodology + architecture block diagram; HW/SW tools; resource use, timing, debugging incl. ILA captures, challenges; results/observations), 8.3 one-command demo. AI-code rule not in the notice: ask the instructor.
Phase 9 HUD (only if time): 9.1 mirror+alignment matrices 800x480; 9.2 90-frame sequence, view.py pixel-exact, >=30 fps DDR to DDR.

## Timeline (estimate) and roles
Week 1: Phases 0-2 + 3.1-3.3 (Gate 1: model checks pass, spec reviewed). Week 2: 3.4-3.8 + Phase 4 (Gate 2: grayscale bit-exact on board; the hard point). Week 3: Phases 5-6 (Gate 3). Week 4: Phases 7-8 (Gate 4). If Gate 2 slips, Option B moves to the end.
Roles: Model and software (1, 4.2-4.4, 7); Datapath RTL (3.2, 3.3, 3.6, 5, 6); Memory and integration (3.1, 3.4, 3.5, 3.7, 3.8, 4.1).

## Progress
- Prompts 0, 0b, 0c, 0d done (D1-D9 decided; plan synced; course notice read).
- Step 0.1 done (tag step-0.1).
- 2026-11-07: Step 0.2a postponed (board files not installed; waiting for lab access to the ZedBoard). 0.2b and 0.3 wait for the board.
