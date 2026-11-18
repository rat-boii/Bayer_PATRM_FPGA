# CLAUDE.md: Bayer-PATRM (Reconfigurable Computing course project)

Team: Abraar Ahmad Khan, Shreedhar S, Tushar. Board: Avnet ZedBoard (Zynq-7000 XC7Z020, part xc7z020clg484-1).
Base paper: [1] "An FPGA-Based Reconfigurable Accelerator for Real-Time Affine Transformation in Industrial
Imaging Heterogeneous SoC", Sensors 26(1):316, 2026 (PATRM). We reproduce PATRM in grayscale on the ZedBoard
and extend it to raw Bayer (RGGB) with two builds: Option A (one shared core, four plane passes) and
Option B (four lanes, one coordinate generator, one row-pair fetch). Then we prove acceleration against
the same fixed-point algorithm on the ARM Cortex-A9.

Team priority: FPGA work (RTL, AXI, memory system, resource/timing results) is the core. Course marks: plan of
work 2, presentation + viva 6, demo + deliverables 12, judged relative to complexity and completeness, so a fully
working stage beats a half-working extra one. Software is only for control, test and tooling.

## How we work (read before every task)
- Work happens one plan step at a time (see docs/implementation-plan.md). Each prompt names a step ID.
  Do exactly that step, run its Verify check, show the output, then STOP. Never start the next step on your own.
- A step is done only when its Verify check passes. If it fails, say so plainly; never weaken a check to make it pass.
- The Python model in model/ is the single reference. RTL simulation, the ARM C code and on-board output
  must match it bit-exactly (0 differing bytes). Never "fix" a mismatch by changing the model to match the RTL
  without telling the user which one is wrong and why.
- Do not change a fixed convention below or an open decision on your own. If something is unclear or
  conflicts, ask the user and wait.
- Label estimates as estimates. Do not invent numbers (timing, resources, speed); measure them or say they are unknown.
- After a step passes: `git add` + commit with message "step <ID>: <summary>" and tag `step-<ID>`.
- Before modifying or moving files that already exist, list what you will change.
- On a laptop you have not used before, or after a fresh clone, run python scripts/check_setup.py first and follow its fixes before any step. Board and Vitis setup is per laptop; see README 'New laptop setup'.

## Environment (decided 2026-11-06)
- Windows, native (NOT WSL; WSL has no Vivado). Vivado/Vitis 2026.1. Simulator: xsim. HDL: Verilog-2001.
- Use Python 3 on Windows for all scripts (model, generators, runners) so they can call Vivado tools directly.
  Prefer Python runner scripts over .sh/.bat so they work from Git Bash and PowerShell.
- Vivado in batch mode: `vivado -mode batch -source <script.tcl> -tclargs ...`. Keep projects reproducible from Tcl
  (no hand-edited project files checked in).
- Simulation: xvlog -> xelab -> xsim in batch mode, driven by scripts/sim.py. Testbenches are self-checking and print
  exactly one final line `TEST PASS` or `TEST FAIL: <reason>`.
- XSCT does NOT exist in 2026.1. Board access (program FPGA, load ELF, write/read DDR) uses XSDB
  (Tcl XSDB, or Python-based XSDB if Tcl XSDB is missing). Vitis software projects are created with the
  Vitis Python API (`vitis -s <script.py>`), not XSCT. Check AMD docs (UG1400, UG1725) for 2026.1 syntax; do not
  assume older XSCT-era commands still work.
- Vivado 2026.1 needs a valid license file to launch.

## Fixed technical conventions (do not change without asking)
- Coordinates as in the paper: x = row, y = column; u = output row (row_cnt), v = output column (col_cnt).
- Inverse mapping: x = b11*u + b12*v + b13, y = b21*u + b22*v + b23.
  Step along an output row (v+1) adds (b12, b22); next row (u+1) adds (b11, b21).
- Block start (X0, Y0) computed with a 3-stage multiply-add pipeline; inside a block, coordinates by addition only.
- Fixed point Q15.16 (scale 65536), signed 32-bit. Output truncated to 8 bits.
- Bilinear: D = xf*yf*r4 + (1-xf)*yf*r2 + xf*(1-yf)*r3 + (1-xf)*(1-yf)*r1, evaluated in integers as D10
  (7 multipliers per pixel: 3 weight + 4 pixel), 4-stage pipeline.
- Out-of-range source pixels output 0 (exact rule: D1 below).
- Images: raw GRAY8, row-major, no header. Image size is a register (not fixed in hardware); size rules: D3 below.
- Bayer RGGB offsets o = (row, column): R (0,0), Gr (0,1), Gb (1,0), B (1,1).
  Per-plane shift t_p = ((A - I) o + t) / 2, where A = [[b11,b12],[b21,b22]], t = (b13, b23).
  t_R = t/2; t_Gr = (t + (b12, b22-1))/2; t_Gb = (t + (b11-1, b21))/2; t_B = (t + (b11+b12-1, b21+b22-1))/2.
  Exact integer evaluation: D2 below.
- Platform: custom AXI masters, no DMA. HP0 = read, HP1 = write, 64-bit. AXI3 HP ports: max 16-beat bursts,
  never cross a 4 KB boundary. AXI-Lite register file on GP0. Done interrupt PL -> PS (IRQ_F2P[0]).
  Performance counters: cycles per frame, bytes read, bytes written (plus stall counters).
- Data in/out of DDR over USB-JTAG (XSDB); console on USB-UART (115200). No SD card.
- PL clock: 100 MHz for every build (D8).

Worked example (use it as a test): b = (0.8, -0.6, 2, 0.6, 0.8, 1). Output pixel (u,v) = (3,2) maps to source
(x,y) = (3.2, 4.4). With neighbours r1 = 100 (x0,y0), r2 = 140 (x0,y0+1), r3 = 120 (x0+1,y0), r4 = 160 (x0+1,y0+1)
the result is 120 in exact arithmetic (r2 is the next column, r3 the next row, matching the D formula).
Blue-plane shift t_B = (0.6, 0.7). In Q15.16 the coefficients are not exact, so the fixed-point result may be
119 or 120 depending on coefficient rounding and truncation; report which, and why, rather than forcing 120.
Exact integers (D5 quantisation, D2 shift): b = (52429, -39322, 131072, 39322, 52429, 65536) and
t_B = (39321, 45875). Step 1.3 checks these exactly.

## Decided 2026-11-06 (fixed; do not change without asking)
- D1 Edge rule. An output pixel is valid if and only if 0 <= x <= H-1 and 0 <= y <= W-1, compared on the Q15.16
  coordinate: 0 <= X <= (H-1)*65536 and 0 <= Y <= (W-1)*65536. Otherwise the output is 0.
  Neighbour indices x0+1 and y0+1 are clamped to H-1 / W-1. When a clamp is active the fraction is 0, so that
  neighbour has weight 0. Identity and mirror must reproduce the input exactly.
- D2 t_p. Computed from the already-quantised integer b's: evaluate (A-I)*o + t in Q15.16 integers
  (I = 65536 on the diagonal), then arithmetic shift right by 1 (floor). The same integer formula is used in
  Python, C and wherever the registers are written.
- D3 Size rules. Grayscale: W a multiple of 8. Bayer: W a multiple of 16 and H even. Model, driver and generators
  reject other sizes with a clear error; no padding. Test images (W x H): 480x272, 640x480, 800x480, 1920x1080,
  2448x2048 (large Bayer). Paper comparison: grayscale at 2448x2095 (W x H, see D7).
  Simulation sizes stay small: 64x64, 128x96.
- D4 Overflow. RTL uses plain 32-bit two's-complement arithmetic, no saturation. Intermediate wraps cancel as long
  as the final coordinate fits; source coordinates are affine in (u,v), so their extremes are at the four output
  corners. The PC tool and driver reject any transform whose four output corners map outside +/-16384 px
  (row or column), and the model asserts this.
- D5 Quantisation. Coefficients are quantised as floor(v*65536 + 0.5) on the PC side.
- D6 Option B lane offset = register difference T_p - T_R. Never recompute (A-I)o/2 in RTL; with D2 rounding
  it can differ by 1 LSB.
- D7 Sizes are always written W x H. The paper size is 2448x2095 (W x H).
- D8 PL clock is 100 MHz for every build. 150 MHz only as an Fmax experiment in step 7.3.
- D9 The ILA is a debug-build option only. All resource, timing and speed numbers come from builds without it.
- D10 Interpolator (option A2, decided 2026-11-07). xf = X & 0xFFFF, yf = Y & 0xFFFF;
  w2 = ((65536-xf)*yf)>>16; w3 = (xf*(65536-yf))>>16; w4 = (xf*yf)>>16; w1 = 65536-(w2+w3+w4);
  D = (w1*r1 + w2*r2 + w3*r3 + w4*r4)>>16, with r1=(x0,y0), r2=(x0,y0+1), r3=(x0+1,y0), r4=(x0+1,y0+1).
  7 multipliers (3 weight + 4 pixel). The weights always sum to exactly 65536 (a flat image stays flat).
  Replaces the earlier "8 multipliers" convention.
- Block length. Integer stepping equals direct multiplication exactly (mod 2^32), so block length never changes
  results. It is a memory/prefetch parameter, decided in steps 1.4/2.2.
- Coefficients. b is the inverse mapping (output -> source). A PC-side model helper builds b from forward
  parameters (rotation, scale, shift, mirror) in float and quantises it with D5. From then on model, C and RTL
  all use the same integer b. The ARM never does floating-point transform maths.
- Bayer planes. Each plane is warped as an independent image: H and W in D1 are the plane size (H/2, W/2),
  in plane coordinates.
- Integer/fraction split. Integer part = arithmetic shift right by 16 (floor); fraction = low 16 bits, unsigned.
  Negative coordinates are out of range under D1.
- Output truncation = drop the fraction bits; no saturation needed (bilinear output cannot exceed 255).
- "Interrupt" (not "IRQ") is for diagrams only; the port keeps its AMD name IRQ_F2P.

## Decided 2026-11-10 (fixed; do not change without asking)
- D11 Maximum image size 4096 x 4096. WIDTH/HEIGHT registers are 13 bits; a value above 4096, or a size breaking
  D3 for the selected mode, sets STATUS.error and the engine does not start.
- D12 The ARM computes T_R, T_Gr, T_Gb, T_B with the D2 integer formula (the same as model/bayer.py plane_shifts)
  and writes them to registers. The hardware never recomputes them. Option B lane offsets = T_p - T_R from these
  registers (D6).
- D13 Block length is a register BLOCK_LEN (1..BLOCK_LEN_MAX). BLOCK_LEN_MAX is a synthesis parameter chosen in
  step 2.2 from the step 1.4 numbers. Out-of-range values set STATUS.error.
- D14 Fetch policy P1: skip a row fetch when the previous block already holds that row with a covering column
  range.
- D15 BLOCK_LEN_MAX = 64 (synthesis parameter; BUILD_ID.BLOCK_LEN_MAX = 64; driver default BLOCK_LEN = 64).
- D16 A block ends at the first of: (a) the source top row x0 changes, (b) BLOCK_LEN pixels reached, (c) the
  column span of a needed row would exceed SPAN_MAX = 512 bytes. So the buffers can never overflow, and every
  D4-valid transform is supported (speed varies). Exact rules: model/memmodel.py docstring, spec/interface.md.

## Decided 2026-11-15 (fixed; do not change without asking)
- D17 No SystemVerilog unless completely necessary. All our RTL and testbenches are Verilog-2001: .v files only,
  xvlog and read_verilog without -sv. Verilog-2005 system functions that xvlog accepts in plain Verilog mode
  (e.g. $clog2) are fine. Vendor IP that is SystemVerilog inside (Zynq-7000 VIP, ILA) is allowed because we do
  not write it; our testbench around it stays Verilog. Do not use AXI VIP; use our own Verilog memory model.
  If you think SystemVerilog is needed, stop and ask me with the reason. scripts/check_no_sv.py (run by
  scripts/sim.py before compiling) fails on .sv files or any -sv flag.

## Decided 2026-11-18 (fixed; do not change without asking)
- D18 ZedBoard DDR memory part. The lab board is ZedBoard Rev C (confirmed from the silkscreen), which uses
  MT41J128M16 HA-15E. The Digilent zedboard 1.3 preset sets PCW_UIPARAM_DDR_PARTNO = "MT41K128M16 JT-125"
  (the Rev D part). After apply_bd_automation with the board preset, set the Zynq PS DDR memory part to
  MT41J128M16 HA-15E. Pending: confirm the DDR chip marking on the lab board with Micron's FBGA decoder; if it
  decodes to MT41K128M16JT-125, D18 is reverted.
  Never use the ZC702 board or preset (same chip, different DDR and pins).
- Board files: Digilent vivado-boards, zedboard version 1.3, installed in
  C:\AMDDesignTools\2026.1\Vivado\data\boards\board_files\zedboard\1.3. Vivado shows the board as "ZedBoard",
  vendor digilentinc.com; board part name (get_board_parts *zed*): digilentinc.com:zedboard:part0:1.1.
  Fallback if they cannot go in the Vivado install folder: keep them elsewhere and add
  `set_param board.repoPaths [list <folder>]` to %APPDATA%\Xilinx\Vivado\Vivado_init.tcl.

## Open decisions (proposed defaults; ask before relying on them)
- Option A output writes (step 5.1). Proposal: WSTRB-masked writes into the interleaved buffer.

## Repository layout
model/ Python reference model and generators · spec/ regs.json and interface spec · rtl/ Verilog sources ·
tb/ testbenches and bus models · vivado/ Tcl build scripts · sw/ bare-metal driver and ARM baseline ·
scripts/ sim, board (XSDB) and test runners · data/ test images and golden outputs · results/ CSV, reports, plots ·
docs/ plan and specs.

## RTL style
- Verilog-2001, one module per file, file name = module name. Single clock domain (FCLK_CLK0), synchronous
  active-low reset `aresetn` (matches AXI). Parameters for widths and depths, no magic numbers.
- Explicit signed arithmetic with `$signed` and documented truncation points that match the model.
- valid/ready handshakes between blocks. No latches; no combinational loops.
- Diagrams for the slides: black and white, no fills, dashed border = new/changed vs the paper,
  write "interrupt" (not "IRQ"). Credit the paper for reused figures.
