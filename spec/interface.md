# Grayscale engine: modules and interfaces (step 2.2)

Scope: the GRAYSCALE engine (BUILD_TYPE 0, MODES = 0b001). Bayer A/B only appear as hooks (section 14),
detailed in steps 5.1 / 6.1. Registers: `spec/regs.json`. DDR, interrupt, driver sequence: `spec/memory_map.md`.
Block / fetch schedule: `model/memmodel.py` (docstring = the rules), vectors `data/vectors/sched_*.txt`.
Bit-exact reference for every pixel: `model/patrm.py`. Figure: `docs/figures/patrm_gray_top.tex`.

**Every number marked ESTIMATE is an estimate, not a measurement.** Timing and resources are measured in
step 3.8 (OOC implementation) and step 4.1 (full build).

## 0. Conventions for all modules

- One clock `aclk` = FCLK_CLK0, 100 MHz (D8). Synchronous active-low reset `aresetn` (held low for at least
  16 cycles by the Processor System Reset IP). Verilog-2001, one module per file, file name = module name.
- Handshake: `*_valid` / `*_ready`. A transfer happens in a cycle where both are 1. Once `valid` is 1 the
  sender keeps it and the data stable until the transfer (AXI rule). `ready` may depend on `valid`, never the
  other way round. No combinational path from a module's `ready` input to its `valid` output.
- Pipelines with internal stall use one clock enable `ce` per pipeline: all stages advance together when
  `ce = 1`; `ce = !(out_valid && !out_ready)`; `in_ready = ce`.
- A frame starts with the one-cycle pulse `frame_start` from `ctrl_fsm`; every module latches its configuration
  then and clears its frame state. Configuration registers cannot change while BUSY (spec/regs.json notes).
- Coordinates: x = row, y = column, u = output row, v = output column. X, Y = Q15.16, signed 32 bit, wrapping
  adds (D4). x0 = X >>> 16, xf = X[15:0] (unsigned); y0, yf likewise.
- Widths below: `[n]` = n bits, `s` = signed (two's complement), `u` = unsigned.

### Build parameters (patrm_top)

| parameter | value | meaning |
|---|---|---|
| VERSION | 1 | BUILD_ID.VERSION (= regs.json version) |
| BUILD_TYPE | 0 | gray build |
| MODES | 3'b001 | only CTRL.MODE = 0 accepted |
| BLOCK_LEN_MAX | 64 | D15; BUILD_ID.BLOCK_LEN_MAX; driver default BLOCK_LEN = 64 |
| SPAN_MAX | 512 | D16 rule (c), bytes per row per block = one buffer slot (64 words) |
| NSLOT | 32 | line buffer row slots (proposal, section 6.2) |
| RD_OUTSTANDING | 8 | read bursts in flight on HP0 (>= 2 required; proposal) |
| WR_OUTSTANDING | 8 | write bursts without B response on HP1 (proposal) |
| DESC_DEPTH | 16 | block descriptor FIFO (planner -> coord_gen) |
| FETCH_DEPTH | 16 | fetch FIFO (planner -> prefetch_ctrl) |
| OUT_DEPTH | 64 | out_fifo depth in 64-bit words (4 bursts) |
| SIZE_BITS | 13 | WIDTH / HEIGHT / BLOCK_LEN / row / column fields |

### Data path

```
GP0 -> axil_regs -> ctrl_fsm --frame_start--> all
block_planner --desc--> coord_gen --pix--> pixel_fetch --> bilinear_interp --> out_fifo --> axi_wr_master -> HP1
      |                                        ^  (4 reads/clk)
      +--fetch--> prefetch_ctrl --cmd--> axi_rd_master <- HP0
                       |  (1 write/clk)        |
                       +------> line_buf <-----+ data
```

## 1. axil_regs

**Purpose.** AXI4-Lite slave on M_AXI_GP0 (through the AXI interconnect / protocol converter of the block
design). Holds the registers of `spec/regs.json` (`rtl/patrm_regs.vh`), checks a start (error codes), drives
the interrupt.

**Ports**

| port | dir | width | meaning |
|---|---|---|---|
| aclk, aresetn | in | 1 | clock, reset |
| s_axil_awaddr | in | [7] u | byte address (bits 1:0 ignored) |
| s_axil_awprot | in | [3] | ignored |
| s_axil_awvalid / awready | in / out | 1 | write address handshake |
| s_axil_wdata | in | [32] | write data |
| s_axil_wstrb | in | [4] | byte enables; byte lanes with 0 are not written |
| s_axil_wvalid / wready | in / out | 1 | write data handshake |
| s_axil_bresp | out | [2] | always 2'b00 (OKAY), also for unmapped addresses (write ignored) |
| s_axil_bvalid / bready | out / in | 1 | write response |
| s_axil_araddr | in | [7] u | byte address |
| s_axil_arprot | in | [3] | ignored |
| s_axil_arvalid / arready | in / out | 1 | read address handshake |
| s_axil_rdata | out | [32] | read data (0 for unmapped offsets) |
| s_axil_rresp | out | [2] | always 2'b00 |
| s_axil_rvalid / rready | out / in | 1 | read data |
| cfg_mode | out | [2] u | CTRL.MODE |
| cfg_src_addr, cfg_dst_addr | out | [32] u | SRC_ADDR, DST_ADDR |
| cfg_width, cfg_height | out | [13] u | W, H |
| cfg_b11, cfg_b12, cfg_b13, cfg_b21, cfg_b22, cfg_b23 | out | [32] s | Q15.16 |
| cfg_t_r_x ... cfg_t_b_y | out | 8 x [32] s | T registers (unused in the gray build) |
| cfg_block_len | out | [13] u | BLOCK_LEN |
| start_accept | out | 1 | one-cycle pulse, registered: a start passed all checks |
| busy | in | 1 | from ctrl_fsm |
| done_set | in | 1 | one-cycle pulse from ctrl_fsm: set STATUS.DONE |
| cnt_cycles, cnt_bytes_rd, cnt_bytes_wr, cnt_rd_stall, cnt_wr_stall | in | [32] u | counters from ctrl_fsm |
| interrupt | out | 1 | CTRL.IRQ_EN & STATUS.DONE, registered, level (to IRQ_F2P[0]) |

**Handshake.** One transaction at a time; a write has priority over a read that arrives in the same cycle.
`awready = wready = 1` only in a cycle where both `awvalid` and `wvalid` are 1, no write response is pending and
no read is in progress, so address and data are taken together (cycle T). `bvalid` rises in T+1 and stays until
`bready`. A read is accepted (`arready`) only when no write is pending; `rvalid` rises the next cycle.

**Start check (cycle T of a CTRL write with wdata[0] = 1).** Combinational on the current registers and the
new MODE (wdata[2:1]), first failing check wins: START_BUSY (busy = 1), BAD_MODE (MODE = 3 or MODES[MODE] = 0),
BAD_SIZE (W = 0, W > 4096, H = 0, H > 4096, gray W[2:0] != 0, Bayer W[3:0] != 0 or H[0] = 1), BAD_ADDR
(SRC_ADDR[11:0] or DST_ADDR[11:0] != 0), BAD_BLOCK_LEN (L = 0 or L > BLOCK_LEN_MAX). On failure ERROR and
ERR_CODE are set at the end of T. On success `start_accept` = 1 in T+1 and DONE, ERROR, ERR_CODE are cleared at
the end of T; ctrl_fsm sets BUSY at the end of T+1. The earliest following read is accepted in T+2 (the write
response must complete first), so it always sees BUSY = 1 or ERROR = 1 (spec/memory_map.md section 2).

**Latency.** Write: B one cycle after the handshake. Read: R one cycle after the AR handshake. At most one
transaction every 2 cycles (AXI-Lite traffic is a few dozen accesses per frame).

**Reset.** All registers take their regs.json reset values; bvalid = rvalid = 0; interrupt = 0.

**Stall.** Only by AXI-Lite back-pressure (`bready` / `rready` low holds the response). Never stalls the engine.

## 2. ctrl_fsm

**Purpose.** Frame control and performance counters.

**Ports**

| port | dir | width | meaning |
|---|---|---|---|
| aclk, aresetn | in | 1 | |
| start_accept | in | 1 | from axil_regs |
| busy | out | 1 | STATUS.BUSY |
| done_set | out | 1 | pulse: frame finished |
| frame_start | out | 1 | pulse to all data-path modules (same cycle BUSY rises) |
| wr_frame_done | in | 1 | pulse from axi_wr_master: last B response of the frame received |
| rd_beat | in | 1 | from axi_rd_master: one R beat accepted |
| wr_beat | in | 1 | from axi_wr_master: one W beat accepted |
| rd_stall, wr_stall | in | 1 | from pixel_fetch / bilinear_interp (section 13) |
| cnt_cycles, cnt_bytes_rd, cnt_bytes_wr, cnt_rd_stall, cnt_wr_stall | out | [32] u | to axil_regs |

**States.** IDLE -> (start_accept) RUN -> (wr_frame_done) IDLE. In the cycle `wr_frame_done` = 1: `done_set` = 1
and BUSY falls at the end of the cycle. The frame is complete only after the last write response, so all output
data are in DDR when DONE is set (spec/memory_map.md step 10).

**Counters** (section 13 for the exact definitions): cleared at the end of the `start_accept` cycle; hold their
value when BUSY falls; 32-bit wrapping (an estimated 0.2 s frame is 2e7 cycles, far below 2^32).

**Handshake.** Pulses only (no back-pressure). **Latency.** BUSY rises 1 cycle after `start_accept`.
**Reset.** IDLE, counters 0. **Stall.** None.

## 3. block_planner

**Purpose.** Scans the output frame row by row one pixel per clock AHEAD of the interpolation, decides the
blocks (D16), the rows each block needs, row reuse (D14 P1) and the buffer slots (ring rule), and emits one
block descriptor per block (to coord_gen) and one fetch record per block with valid pixels (to prefetch_ctrl).
It is the hardware form of `model/memmodel.py` `make_blocks` + `schedule`; its output must equal
`data/vectors/sched_blocks_*.txt` record for record.

**Its own coordinates.** Add-only, exact: X(0,0) = b13, Y(0,0) = b23; +(b12, b22) per output column,
+(b11, b21) per output row, 32-bit wrapping. Integer stepping equals direct multiplication exactly (mod 2^32),
so these are the same integers coord_gen computes with the multiply-add block start (cross-checked in
simulation). The planner only uses them for scheduling decisions; the pixels that are interpolated come from
coord_gen (fixed convention: block start by 3-stage multiply-add, add-only inside the block).

**Per pixel** (u, v): valid (D1: 0 <= X <= (H-1)<<16 and 0 <= Y <= (W-1)<<16, signed compares against values
precomputed at frame_start), x0 = X >>> 16, y0 = Y >>> 16, y1 = min(y0 + 1, W - 1), x1 = min(x0 + 1, H - 1).

**Block rules (D16, exact).** A block starts at v = 0 and before pixel v when the first of these holds:
(a) v valid, the row already had a valid pixel, x0(v) != x0 of the most recent valid pixel in this output row;
(b) the block already has BLOCK_LEN pixels; (c) v valid and ceil8(max(cmax, y1) + 1) - floor8(min(cmin, y0)) >
SPAN_MAX, where [cmin, cmax] is the column range of the block's valid pixels so far. Invalid pixels never end a
block by themselves and do not change the key. End reason codes: 0 row end, 1 (a), 2 (b), 3 (c).

**At block close.** rows: none (no valid pixel), {x0} if x0 = H-1, else {x0, x0+1}. Byte range of every row
[s_col, s_col + span) with s_col = floor8(cmin), span = ceil8(cmax + 1) - s_col (<= SPAN_MAX). Reuse (D14 P1):
a row is not fetched if the previous block WITH valid pixels needed the same row and its range covers
[s_col, s_col + span). Slots: a reused row keeps its slot; each fetched row takes the ring pointer slot,
skipping slots already used by this block; the pointer advances by one per fetched row. All of this is one
cycle per block, so blocks of one pixel still run at 1 pixel per clock.

**Ports**

| port | dir | width | meaning |
|---|---|---|---|
| aclk, aresetn, frame_start | in | 1 | |
| cfg_width, cfg_height, cfg_block_len | in | [13] u | |
| cfg_b11 ... cfg_b23 | in | [32] s | |
| desc_valid / desc_ready | out / in | 1 | descriptor stream to coord_gen (via DESC_DEPTH FIFO) |
| desc_u, desc_v0 | out | [13] u | first pixel of the block |
| desc_n | out | [7] u | pixels in the block, 1..64 |
| desc_nrows | out | [2] u | 0, 1 or 2 |
| desc_slot_top, desc_slot_bot | out | [5] u | slots of rows x0 and x1 (equal when nrows = 1) |
| desc_s_col | out | [13] u | byte column of word 0 of the slots (multiple of 8) |
| desc_last | out | 1 | last block of the frame |
| fetch_valid / fetch_ready | out / in | 1 | fetch record to prefetch_ctrl (FETCH_DEPTH FIFO); only blocks with nrows > 0 |
| fetch_row_top, fetch_row_bot | out | [13] u | source rows |
| fetch_slot_top, fetch_slot_bot | out | [5] u | |
| fetch_top, fetch_bot | out | 1 | 1 = fetch this row, 0 = reused (fetch_bot = 0 when nrows = 1) |
| fetch_s_col | out | [13] u | byte column of the range start |
| fetch_words | out | [7] u | span / 8, 1..64 |

**Handshake.** The planner advances one pixel per clock while both FIFOs have room for one more record; a
block record is written to both FIFOs in the same cycle (descriptor always, fetch record if nrows > 0).

**Latency.** 3 pipeline stages (P1 step X, Y; P2 valid, x0, y0, y1; P3 rule decision, close, reuse, slots).
A descriptor appears 3 cycles after the pixel that ends it (estimate of the RTL structure, exact value set in
step 3.6 and not visible at any interface).

**Throughput.** 1 output pixel per clock, any block length. It runs ahead of the interpolation by up to
DESC_DEPTH blocks; the step 2.2 schedules show a slot is refilled at the earliest 16 blocks after its previous
user with NSLOT = 32 (test_memmodel [9]), so slot waits in prefetch_ctrl do not throttle it for short blocks.

**Reset.** Idle, ring pointer 0, "previous fetching block" empty. At frame_start the same.

**Stall.** Stops (holds state) when either FIFO is full. Never waits for data.

## 4. coord_gen

**Purpose.** Produces the exact (X, Y) of every output pixel in frame order for the interpolation, from the
block descriptors: block start (X0, Y0) = (b11 u + b12 v0 + b13, b21 u + b22 v0 + b23) by a 3-stage
multiply-add pipeline (paper convention), then +(b12, b22) per pixel inside the block (add only).

**Multiply-add, mod 2^32 (D4).** Each product b x k (b [32] s, k = u or v0 [13] u) uses two DSP48E1: b = bh * 2^16
+ bl with bl = b[15:0] (17-bit non-negative operand) and bh = b[31:16] (16-bit signed); low 32 bits of b k =
(bl k + ((bh k) << 16)) mod 2^32. Stage S1: 8 partial products (DSP M register). Stage S2: the four products
mod 2^32 (one 32-bit add each). Stage S3: X0 = p11 + p12 + b13, Y0 = p21 + p22 + b23 (3-input 32-bit adds).
8 DSP48E1 in total.

**As built (step 3.2, measured).** Vivado 2026.1 puts the S1 register in the P register of each DSP48E1 (not
the M register) and absorbs the b latched at frame_start into its A register (AREG = 1, MREG = 0, PREG = 1).
Depth (3 stages) and function are the same. OOC post-route at 100 MHz (`results/ooc/coord_gen_summary.txt`):
284 LUT (68 of them LUTRAM: the 4-entry start FIFO and the side-field FIFO), 367 FF, 0 BRAM, 8 DSP48E1,
WNS +3.817 ns (register-to-register paths only). Critical path: start-FIFO not-empty (`start_wptr`) -> stepper
load / add (`y_r`), 6.2 ns, 11 logic levels; it is the first candidate to pipeline for the 150 MHz experiment
in step 7.3. The path from `desc_u` / `desc_v0` into the DSP48E1 needs 3.6 ns inside this module.

**Ports**

| port | dir | width | meaning |
|---|---|---|---|
| aclk, aresetn, frame_start | in | 1 | |
| cfg_b11 ... cfg_b23 | in | [32] s | |
| desc_* / desc_valid / desc_ready | in | (as block_planner) | descriptor stream |
| pix_valid / pix_ready | out / in | 1 | pixel stream to pixel_fetch |
| pix_X, pix_Y | out | [32] s | Q15.16 source coordinate |
| pix_first, pix_last | out | 1 | first / last pixel of its block |
| pix_nrows | out | [2] u | of the pixel's block |
| pix_slot_top, pix_slot_bot | out | [5] u | |
| pix_s_col | out | [13] u | |
| pix_frame_last | out | 1 | last pixel of the frame |

**Handshake.** Descriptors are popped into the S1..S3 pipeline as soon as it has room (up to 4 block starts
computed ahead, held in a 4-entry start FIFO), independent of the stepping of the current block, so a new
block can start every cycle. The stepper outputs one pixel per transfer.

**Latency.** First pixel of the frame: 4 cycles after the first descriptor (S1, S2, S3, stepper register).
Then 1 pixel per clock (II = 1) for all block lengths, including 1-pixel blocks.

**Reset.** Pipelines empty, pix_valid = 0. **Stall.** Holds its output when `pix_ready` = 0 (ce rule);
stops popping descriptors when its start FIFO is full.

## 5. prefetch_ctrl

**Purpose.** Turns fetch records into row read commands for axi_rd_master, never overwriting a slot that an
earlier block still needs, writes the returned beats into line_buf, and tells pixel_fetch which blocks are
complete.

**Block counters** (16-bit, modulo compares). Fetching blocks (nrows > 0) are numbered in order from 0 at
frame_start. `blocks_ready`: number of fetching blocks whose fetched rows are completely in line_buf (reads
return in order, ARID = 0, so this is a counter). `blocks_done` (from pixel_fetch): number of fetching blocks
fully read out of line_buf. `last_user[slot]`: the last fetching block that uses the slot (fetched or reused).

**Ports**

| port | dir | width | meaning |
|---|---|---|---|
| aclk, aresetn, frame_start | in | 1 | |
| cfg_src_addr | in | [32] u | |
| cfg_width | in | [13] u | |
| fetch_* / fetch_valid / fetch_ready | in | (as block_planner) | fetch records |
| cmd_valid / cmd_ready | out / in | 1 | row read command to axi_rd_master |
| cmd_addr | out | [32] u | SRC_ADDR + row * W + s_col (8-byte aligned) |
| cmd_words | out | [7] u | 1..64 |
| cmd_slot | out | [5] u | target slot |
| rd_valid | in | 1 | one beat from axi_rd_master (no back-pressure) |
| rd_data | in | [64] | beat, byte k = bits 8k+7:8k (address order) |
| rd_slot, rd_word | in | [5] u, [6] u | where the beat goes |
| rd_cmd_last | in | 1 | last beat of a row command |
| buf_we, buf_wbank, buf_waddr, buf_wdata | out | 1, 1, [10] u, [64] | line_buf write (bank = word[0], addr = slot * 32 + word[5:1]) |
| blocks_ready | out | [16] u | to pixel_fetch |
| blk_done | in | 1 | pulse from pixel_fetch: one more fetching block read out |

**Behaviour.** For the record at the head of the FIFO: update `last_user` for its slots; for each row with
fetch = 1 (top first): wait until `last_user[slot]` (before this update) < `blocks_done`, then compute the
address (row * W: one DSP48E1, 13 x 13 bit, 2-cycle pipeline) and issue one command. A record whose rows are
all reused issues nothing. `blocks_ready` increments when the last beat of the block's last command has been
written (or immediately, in order, for a block with nothing to fetch).

**Handshake.** fetch: valid/ready. cmd: valid/ready. rd: valid only (prefetch_ctrl always accepts, the slot
is reserved). **Latency.** Record to first command: 3 cycles (estimate of the RTL structure). Beat to line_buf
write: 1 cycle. **Throughput.** One command per cycle; the read path (<= 1 beat per clock) is the limit.
**Reset.** Counters 0, all slots free, FIFO empty. **Stall.** Holds a command while the target slot is in
use or `cmd_ready` = 0; this stops `fetch_ready`.

## 6. line_buf (the ping-pong buffer)

**Purpose.** On-chip copy of the source row segments: NSLOT = 32 slots x 64 words x 64 bit = 16 KB. Gives
pixel_fetch the four neighbour bytes r1..r4 of one pixel per clock while prefetch_ctrl writes other slots.

### 6.1 What one pixel needs per clock

r1 = (x0, y0), r2 = (x0, y1), r3 = (x1, y0), r4 = (x1, y1) with y1 = y0 + 1 or y0. Rows x0 and x1 are in
different slots (or the same slot at the bottom edge). Within a row, y0 and y1 are in the same 64-bit word
unless y0 mod 8 = 7, then y1 is in the next word. So per clock: 2 rows x 2 consecutive words = 4 word reads,
plus 1 word write (HP0 delivers at most one 64-bit beat per clock).

### 6.2 Organisation (chosen)

- **Even / odd word banks.** Word w of a slot is stored in bank (w mod 2) at entry slot * 32 + (w >> 1).
  Two consecutive words always lie in different banks, so "word w and word w+1" is one read per bank.
- **Two copies.** Copy T serves row x0 (r1, r2), copy B serves row x1 (r3, r4). Every write goes to both
  copies of its bank.
- So there are 4 memories (T-even, T-odd, B-even, B-odd), each NSLOT x 32 = 1024 entries x 64 bit, each in
  simple dual-port mode: port A writes (from prefetch_ctrl), port B reads (for pixel_fetch). 4 reads + 1
  write per clock, every memory port used at most once per clock.
- Read address for one row: even bank entry = slot * 32 + ((w0 + 1) >> 1), odd bank entry = slot * 32 + (w0 >> 1),
  with w0 = word of y0; the byte mux then picks r1 = byte (y0 mod 8) of word w0 and r2 = byte (y1 mod 8) of
  word w1 (w1 = w0 or w0 + 1). y1 never leaves the slot because rule (c) and the y1 clamp keep it inside the
  block's range.
- **Why the reads never collide with the writes.** prefetch_ctrl writes a slot only after every block that
  used it has been read out (`last_user < blocks_done`); pixel_fetch reads only slots of blocks counted in
  `blocks_ready`. A slot is never read and written in the same cycle, so the RAM write mode does not matter.
  This is the ping-pong idea with 32 slots instead of 2 halves: P1 row reuse (D14) needs a row to stay where it
  is while the next block's rows are being fetched, which two fixed halves cannot do.

**Numbers (ESTIMATE where marked).**

| option | memories | resources | verdict |
|---|---|---|---|
| BRAM, 2 banks x 2 copies, SDP 512 x 72 (64 bits used) | 4 x 1024 x 64 | 8 RAMB36 (2 per memory) of 140 = 5.7 % | **chosen**: no LUTs, 1-cycle synchronous read, fits the pipeline |
| BRAM, 1 copy, true dual-port | 2 ports per memory | 2 RAMB36 per bank but only 2 ports for 4 reads + 1 write | not enough ports |
| distributed RAM (LUTRAM), same 4 memories | 4 x 65536 bit | 65536 bit / 64 bit per LUT = 1024 LUTs per memory, 4096 LUTs (ESTIMATE, without read muxes) = 24 % of the 17,400 SLICEM LUTs | too large at 16 KB |
| 4 full copies instead of even/odd | 4 x 16 KB | 16 RAMB36 | twice the BRAM for nothing |

NSLOT: with NSLOT = 16 the buffer is 8 KB (4 RAMB36) and a slot is refilled 8 blocks after its previous user
(half of the 16 measured with NSLOT = 32). The fetch latency per block has to be covered by the blocks in
between; for 1 to 2 pixel blocks (rotation 37 degrees) more blocks in flight hide more DDR latency. 32 is a
proposal; the HP0 read latency is unknown until measured (step 3.6 testbench uses a programmable latency;
step 4.3 measures RD_STALL on the board).

**Ports**

| port | dir | width | meaning |
|---|---|---|---|
| aclk | in | 1 | (no reset: RAM contents are don't-care until written) |
| we, wbank, waddr, wdata | in | 1, 1, [10] u, [64] | write, from prefetch_ctrl |
| re | in | 1 | read enable (pixel_fetch ce) |
| raddr_te, raddr_to, raddr_be, raddr_bo | in | [10] u | four read addresses |
| rdata_te, rdata_to, rdata_be, rdata_bo | out | [64] | data one cycle after `re` |

**Handshake.** None (RAM). **Latency.** Read 1 cycle (output register off; can be switched on in step 3.8 for
timing, then pixel_fetch adds one stage). **Reset.** No reset on contents. **Stall.** `re` = 0 holds the
output registers.

## 7. pixel_fetch

**Purpose.** For each pixel from coord_gen: D1 validity, integer/fraction split, waits until the pixel's block
is in line_buf, reads the four neighbours, passes (xf, yf, r1..r4, valid) to the interpolator.

**Pipeline.** F1: valid (D1, signed compares), x0/y0/xf/yf, y1 = min(y0 + 1, W - 1), word offsets
w0 = (y0 - s_col) >> 3, w1 = (y1 - s_col) >> 3, bank addresses (section 6.2), block-ready check.
F2: line_buf read (1 cycle). F3: byte muxes -> r1..r4 (r3 = r1's column in row slot_bot, etc.), register.
Invalid pixels skip the RAM read and give r1..r4 = 0 (the interpolator forces D = 0 anyway; the zeros keep
X values out of simulation).

**Ports**

| port | dir | width | meaning |
|---|---|---|---|
| aclk, aresetn, frame_start | in | 1 | |
| cfg_width, cfg_height | in | [13] u | |
| pix_* / pix_valid / pix_ready | in | (as coord_gen) | |
| blocks_ready | in | [16] u | from prefetch_ctrl |
| blk_done | out | 1 | pulse: last pixel of a fetching block has been read (F2 done) |
| buf_re, buf_raddr_te/to/be/bo | out | 1, 4 x [10] u | line_buf read |
| buf_rdata_te/to/be/bo | in | 4 x [64] | |
| ip_valid / ip_ready | out / in | 1 | to bilinear_interp |
| ip_xf, ip_yf | out | [16] u | fractions |
| ip_r1, ip_r2, ip_r3, ip_r4 | out | [8] u | neighbours (0 when invalid) |
| ip_ok | out | 1 | D1 valid |
| ip_last | out | 1 | last pixel of the frame |
| rd_stall | out | 1 | to ctrl_fsm (section 13) |

**Handshake.** ce pipeline (section 0). F1 holds a pixel of fetching block k (k = count of earlier fetching
blocks) until k < blocks_ready; pixels of blocks without valid pixels never wait.

**Latency.** 3 cycles (F1, F2, F3). **Throughput.** 1 pixel per clock when the block is ready.
**Reset.** Empty, fetching-block counter 0. **Stall.** Waits for data (RD_STALL) or for the interpolator (ce).

## 8. bilinear_interp (D10, option A2)

**Purpose.** D = (w1 r1 + w2 r2 + w3 r3 + w4 r4) >> 16 with the D10 weights, bit-exact to
`model/patrm.py` `interp_d10`; output 0 for invalid pixels (D1). 7 multipliers (3 weight + 4 pixel), 4 stages,
II = 1.

**Bit widths (all unsigned; checked against the model by `model/test_interface.py`).** The minimum and maximum are
those reachable over all xf, yf in 0..65535 and r in 0..255; bits = bits of the maximum. Truncation happens
in two places only, both `>> 16` (drop the 16 low bits, floor): w2..w4 and D.

<!-- widths:begin -->
| signal | expression (interp_d10) | min | max | bits | stage | where |
|---|---|---|---|---|---|---|
| xf | X & 0xFFFF | 0 | 65535 | 16 | in | input |
| yf | Y & 0xFFFF | 0 | 65535 | 16 | in | input |
| nxf | 65536 - xf | 1 | 65536 | 17 | in | fabric (input register) |
| nyf | 65536 - yf | 1 | 65536 | 17 | in | fabric (input register) |
| p2 | nxf * yf | 0 | 4294901760 | 32 | 1 | DSP48E1 #1 (17 x 16) |
| p3 | xf * nyf | 0 | 4294901760 | 32 | 1 | DSP48E1 #2 (16 x 17) |
| p4 | xf * yf | 0 | 4294836225 | 32 | 1 | DSP48E1 #3 (16 x 16) |
| w2 | p2 >> 16 | 0 | 65535 | 16 | 2 | wiring (truncation 1) |
| w3 | p3 >> 16 | 0 | 65535 | 16 | 2 | wiring (truncation 1) |
| w4 | p4 >> 16 | 0 | 65534 | 16 | 2 | wiring (truncation 1) |
| s234 | w2 + w3 + w4 | 0 | 65535 | 16 | 2 | fabric adder |
| w1 | 65536 - s234 | 1 | 65536 | 17 | 2 | fabric subtract |
| r1 | pixel (x0, y0) | 0 | 255 | 8 | in | input |
| r2 | pixel (x0, y1) | 0 | 255 | 8 | in | input |
| r3 | pixel (x1, y0) | 0 | 255 | 8 | in | input |
| r4 | pixel (x1, y1) | 0 | 255 | 8 | in | input |
| q1 | w1 * r1 | 0 | 16711680 | 24 | 3 | DSP48E1 #4 (17 x 8) |
| q2 | w2 * r2 | 0 | 16711425 | 24 | 3 | DSP48E1 #5 (16 x 8) |
| q3 | w3 * r3 | 0 | 16711425 | 24 | 3 | DSP48E1 #6 (16 x 8) |
| q4 | w4 * r4 | 0 | 16711170 | 24 | 3 | DSP48E1 #7 (16 x 8) |
| acc | q1 + q2 + q3 + q4 | 0 | 16711680 | 24 | 4 | fabric adder tree (or DSP cascade) |
| D | acc >> 16 | 0 | 255 | 8 | 4 | wiring (truncation 2) |
<!-- widths:end -->

Notes: w2 + w3 + w4 <= 65535 because the exact weights satisfy a + b - ab < 1 for a, b < 1; the RTL may
still compute s234 in 18 bits (no difference). acc <= 255 x (w1 + w2 + w3 + w4) = 255 x 65536, so all partial
sums fit 24 bits. Every DSP operand fits the DSP48E1 25 x 18 signed ports as a non-negative number (17-bit
operand on the 18-bit B port). Output: D_out = ok ? D : 0, registered.

**Ports**

| port | dir | width | meaning |
|---|---|---|---|
| aclk, aresetn | in | 1 | |
| ip_valid / ip_ready, ip_xf, ip_yf, ip_r1..ip_r4, ip_ok, ip_last | in | (as pixel_fetch) | |
| op_valid / op_ready | out / in | 1 | to out_fifo |
| op_d | out | [8] u | output pixel |
| op_last | out | 1 | last pixel of the frame |
| wr_stall | out | 1 | to ctrl_fsm (section 13) |

**Handshake / stall.** ce pipeline: `ip_ready = ce`, `ce = !(op_valid && !op_ready)`. **Latency.** 4 cycles,
II = 1. **Reset.** Valid bits 0 (data registers need no reset).

## 9. out_fifo

**Purpose.** Packs 8 consecutive output bytes into one 64-bit word (byte k of the word = output pixel 8j + k
of the frame, i.e. address order, little endian) and buffers words for axi_wr_master. W is a multiple of 8
(D3), so a word never spans two output rows.

**Ports**

| port | dir | width | meaning |
|---|---|---|---|
| aclk, aresetn, frame_start | in | 1 | |
| op_valid / op_ready, op_d, op_last | in | | from bilinear_interp |
| wq_valid / wq_ready | out / in | 1 | word stream to axi_wr_master |
| wq_data | out | [64] | |
| wq_count | out | [7] u | words stored (axi_wr_master issues a burst only when all its beats are here) |

**Handshake.** `op_ready` = 0 only when the packer holds 7 bytes, receives the 8th and the word FIFO is full.
**Latency.** Byte to word: the word is written in the cycle after its 8th byte. **Throughput.** 1 byte per
clock in, 1 word per clock out. **Storage.** OUT_DEPTH = 64 words (LUTRAM). **Reset.** Empty, packer index 0.
**Stall.** Full FIFO -> `op_ready` = 0 -> interpolator stalls (WR_STALL).

## 10. axi_rd_master (HP0)

**Purpose.** Executes row read commands as AXI3 read bursts: 64-bit beats, ARSIZE = 3, ARBURST = INCR,
at most 16 beats, never across a 4 KB boundary, up to RD_OUTSTANDING (8, at least 2) bursts in flight, and
returns every beat with its slot and word. The bursts must equal `data/vectors/sched_bursts_*.txt` in order.

**Splitting.** For a command (addr, words): next burst starts at a, length = min(remaining, 16,
(4096 - a mod 4096) / 8) beats; a += 8 x length. Same as `memmodel.split_bursts`.

**Ports (HP0 is an AXI3 slave of the PS; only the read channels are used, the write channels are tied off:
awvalid = wvalid = 0, bready = 1)**

| port | dir | width | meaning |
|---|---|---|---|
| aclk, aresetn | in | 1 | |
| cmd_valid / cmd_ready, cmd_addr, cmd_words, cmd_slot | in | | from prefetch_ctrl |
| m_axi_hp0_arid | out | [6] | 0 |
| m_axi_hp0_araddr | out | [32] u | burst address |
| m_axi_hp0_arlen | out | [4] u | beats - 1 (AXI3) |
| m_axi_hp0_arsize | out | [3] | 3'b011 (8 bytes) |
| m_axi_hp0_arburst | out | [2] | 2'b01 (INCR) |
| m_axi_hp0_arlock | out | [2] | 0 |
| m_axi_hp0_arcache | out | [4] | 4'b0011 |
| m_axi_hp0_arprot | out | [3] | 0 |
| m_axi_hp0_arqos | out | [4] | 0 |
| m_axi_hp0_arvalid / arready | out / in | 1 | |
| m_axi_hp0_rid | in | [6] | ignored (single ID, in order) |
| m_axi_hp0_rdata | in | [64] | |
| m_axi_hp0_rresp | in | [2] | not OKAY: see open question Q1 |
| m_axi_hp0_rlast | in | 1 | checked against the expected length (simulation assertion) |
| m_axi_hp0_rvalid / rready | in / out | 1 | rready = 1 always |
| rd_valid, rd_data, rd_slot, rd_word, rd_cmd_last | out | 1, [64], [5], [6], 1 | to prefetch_ctrl |
| rd_beat | out | 1 | to ctrl_fsm (BYTES_RD += 8) |

**Handshake.** AR: valid held until ready (AXI). A burst-info FIFO (RD_OUTSTANDING entries: slot, first word,
last-of-command) records each issued burst; R beats are matched in order. **Latency.** Command to first AR:
1 cycle. R beat to rd_valid: 1 cycle (registered). **Throughput.** One AR per cycle, one beat per cycle.
**Reset.** arvalid = 0, FIFO empty. **Stall.** Stops issuing when RD_OUTSTANDING bursts are in flight or
arready = 0; never back-pressures R.

## 11. axi_wr_master (HP1)

**Purpose.** Writes the output frame row by row: row u at DST_ADDR + u W, split like the reads (<= 16 beats,
no 4 KB crossing; `memmodel.write_stats` counts exactly these bursts), WSTRB = 8'hFF in gray mode.
An AW is issued only when all its beats are in out_fifo (`wq_count`), so W never waits mid-burst. Counts B
responses; after the last B of the frame pulses `wr_frame_done`.

**Ports (HP1: write channels used, read channels tied off: arvalid = 0, rready = 1)**

| port | dir | width | meaning |
|---|---|---|---|
| aclk, aresetn, frame_start | in | 1 | |
| cfg_dst_addr | in | [32] u | |
| cfg_width, cfg_height | in | [13] u | |
| wq_valid / wq_ready, wq_data, wq_count | in | | from out_fifo |
| m_axi_hp1_awid | out | [6] | 0 |
| m_axi_hp1_awaddr | out | [32] u | |
| m_axi_hp1_awlen | out | [4] u | beats - 1 |
| m_axi_hp1_awsize, awburst, awlock, awcache, awprot, awqos | out | [3], [2], [2], [4], [3], [4] | 3'b011, INCR, 0, 4'b0011, 0, 0 |
| m_axi_hp1_awvalid / awready | out / in | 1 | |
| m_axi_hp1_wid | out | [6] | 0 (AXI3) |
| m_axi_hp1_wdata | out | [64] | |
| m_axi_hp1_wstrb | out | [8] | 8'hFF (gray); Option A hook: masked, section 14 |
| m_axi_hp1_wlast | out | 1 | |
| m_axi_hp1_wvalid / wready | out / in | 1 | |
| m_axi_hp1_bid | in | [6] | ignored |
| m_axi_hp1_bresp | in | [2] | not OKAY: open question Q1 |
| m_axi_hp1_bvalid / bready | in / out | 1 | bready = 1 always |
| wr_beat | out | 1 | to ctrl_fsm (BYTES_WR += 8) |
| wr_frame_done | out | 1 | to ctrl_fsm |

**Handshake.** AW and W are independent; W beats of a burst follow in order after (or with) its AW.
**Latency.** wq_count reaching the burst length to AWVALID: 1 cycle. **Throughput.** One beat per clock.
**Reset.** All valid = 0, counters 0. **Stall.** No AW while fewer beats than the burst are in out_fifo or
WR_OUTSTANDING bursts lack a B response; awready / wready back-pressure from HP1.

## 12. patrm_top

**Purpose.** Wires the modules; the IP that goes into the block design (step 4.1).

**Ports**

| port | dir | width | meaning |
|---|---|---|---|
| aclk | in | 1 | FCLK_CLK0, 100 MHz |
| aresetn | in | 1 | peripheral_aresetn of the Processor System Reset IP |
| s_axil_* | | | section 1, to M_AXI_GP0 through the AXI interconnect |
| m_axi_hp0_* (read channels; write channels tied off) | | | section 10, to S_AXI_HP0 (64 bit) |
| m_axi_hp1_* (write channels; read channels tied off) | | | section 11, to S_AXI_HP1 (64 bit) |
| interrupt | out | 1 | to IRQ_F2P[0], level, active high |

**Handshake / latency / stall.** As the submodules. Frame latency is set by the data rate (estimates in
`results/memmodel_step2_2.md`). **Reset.** Everything idle after `aresetn`; the engine starts only by a CTRL
write. **Parameters.** Section 0.

## 13. Counters: exact definitions

All counters are cleared at the end of the cycle in which `start_accept` = 1 and count only while BUSY = 1.

- **CYCLES** = number of clock cycles with BUSY = 1: from the cycle after `start_accept` (the first cycle BUSY
  reads 1) up to and including the cycle in which the last write response of the frame is accepted (BUSY falls
  at the end of that cycle and DONE is set).
- **BYTES_RD** = 8 x number of R beats accepted on HP0 (rvalid & rready) in the frame.
- **BYTES_WR** = 8 x number of W beats accepted on HP1 (wvalid & wready) in the frame, partial WSTRB included.
- **WR_STALL** = number of BUSY cycles in which the interpolator output register holds a pixel that out_fifo does
  not accept (`op_valid & !op_ready`). In these cycles the whole pixel pipeline is frozen.
- **RD_STALL** = number of BUSY cycles in which pixel_fetch stage F1 holds a pixel whose block is not yet in
  line_buf (`k >= blocks_ready`) and the pipeline is not frozen by WR_STALL in the same cycle.
- RD_STALL and WR_STALL never count the same cycle. Cycles where the pipeline simply has no pixel (frame start,
  the planner or coord_gen behind, the drain after the last pixel) count in neither.

## 14. Bayer hooks (detail in steps 5.1 and 6.1)

- **Option A** (MODE 1): ctrl_fsm runs four plane passes (R, Gr, Gb, B) with b = (b11, b12, T_px, b21, b22, T_py)
  from the T registers (D12) and plane size (W/2, H/2) for D1. block_planner maps plane row x -> memory row
  2x + o_row and plane column y -> memory column 2y + o_col (memmodel Pass "A-*"); the 2-row / SPAN_MAX bound
  stays. axi_wr_master writes each full row once per pass with WSTRB on every other byte (open decision 5.1).
- **Option B** (MODE 2): four lanes share one coord_gen; lane p adds T_p - T_R (register difference, D6).
  A block holds up to 3 plane rows = 6 memory rows (step 1.4), so the buffer needs more read copies; to be
  designed in 6.1.
- Shared now: the T registers, MODE, BUILD_ID.MODES, and the plane-row / plane-column parameters of the planner.

## 15. Timing budget at 100 MHz (10 ns; ESTIMATE until step 3.8)

| module | likely critical path | how it is pipelined |
|---|---|---|
| block_planner | rule decision loop: min/max of 13-bit columns -> word span subtract -> compare with SPAN_MAX/8 -> restart mux -> block state register (about 5 LUT levels + two short carry chains) | coordinate step (P1) and D1 compares (P2) are separate stages; only the 13-bit decision loop is left; along a row y0 is monotonic, so min/max can be replaced by "first" and "current" if needed |
| block_planner | block close: two row compares + range compares + ring pointer with up to 2 skips | own stage P3, 5-bit pointer logic |
| coord_gen | MEASURED (step 3.2): start-FIFO not-empty -> stepper load / add, 6.2 ns (WNS +3.817 ns); S3 3-input add 5.4 ns | 3 stages S1-S3 (DSP P register, 32-bit add, 3-input add); stepper is one 32-bit add |
| prefetch_ctrl | row * W + s_col + SRC_ADDR | DSP48E1 with M and P registers, then one 32-bit add |
| pixel_fetch | BRAM clock-to-out + 8:1 byte mux | read in F2, mux in F3 (registered); BRAM output register available as a fallback |
| bilinear_interp | stage 2: 3-input 16-bit add + 17-bit subtract | DSP M/P registers in stages 1 and 3; stage 4 adder tree 24 bit (two levels) |
| axi_rd_master / axi_wr_master | 32-bit address + 4 KB boundary length | registered outputs; length computed one cycle ahead |
| axil_regs | read mux 27 x 32 bit | registered read data |

## 16. Resource estimate (ESTIMATE until step 3.8; XC7Z020: 53,200 LUT, 106,400 FF, 140 RAMB36, 220 DSP48E1)

| module | LUT | FF | RAMB36 | DSP48E1 |
|---|---|---|---|---|
| axil_regs | 400 | 700 | 0 | 0 |
| ctrl_fsm | 200 | 200 | 0 | 0 |
| block_planner (incl. desc / fetch FIFOs) | 600 | 500 | 0 | 0 |
| coord_gen (MEASURED, step 3.2, OOC post-route) | 284 (68 LUTRAM) | 367 | 0 | 8 |
| prefetch_ctrl | 300 | 400 | 0 | 1 |
| line_buf | 50 | 0 | 8 | 0 |
| pixel_fetch | 200 | 300 | 0 | 0 |
| bilinear_interp | 100 | 250 | 0 | 7 |
| out_fifo | 180 | 120 | 0 | 0 |
| axi_rd_master | 150 | 150 | 0 | 0 |
| axi_wr_master | 150 | 150 | 0 | 0 |
| **total (ESTIMATE; coord_gen row measured)** | **about 2,600 (5 %)** | **about 3,200 (3 %)** | **8 (6 %)** | **16 (7 %)** |

Not included: AXI interconnect, protocol converters and the Processor System Reset IP of the block design.

## 17. Open questions (need a decision; defaults used in this spec)

- **Q1 AXI error responses.** RRESP / BRESP other than OKAY are currently ignored (data used as is). Proposal:
  add STATUS error code 6 BUS_ERROR (sticky, frame still completes). Changes `spec/regs.json` (step 2.1); not
  done without your OK.
- **Q2 NSLOT.** 32 (16 KB, 8 RAMB36) proposed; 16 halves the BRAM. Decide after the step 3.6 latency tests.
- **Q3 Outstanding reads.** RD_OUTSTANDING = 8 proposed (spec requires >= 2); the HP port's own acceptance limit
  is to be checked in UG585 before step 3.4.
