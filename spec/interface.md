# Grayscale engine: modules and interfaces (step 2.2)

Scope: the GRAYSCALE engine (BUILD_TYPE 0, MODES = 0b001) in sections 0-17; Bayer Option A (MODE 1) in section 18
(step 5.1); Option B design and verification are linked in section 14. Registers: `spec/regs.json`. DDR, interrupt, driver sequence: `spec/memory_map.md`.
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
| RD_OUTSTANDING | 8 | read bursts in flight on HP0 (>= 2 required; within the HP read acceptance of 14 to 70 commands, UG585; Q3 closed) |
| WR_OUTSTANDING | 8 | write bursts without B response on HP1 (at most 8: HP write acceptance is 8 to 32 commands, UG585; Q3) |
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
| bus_err | in | 1 | from ctrl_fsm, sampled at done_set: 1 sets STATUS.ERROR with ERR_CODE = BUS_ERROR (Q1, step 3.7) |
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

**STATUS.BUSY (step 3.7).** BUSY = `busy` OR `start_pending`. `start_pending` is 1 from T+1 and is cleared when `busy`
rises or at done_set, so BUSY reads 1 from the START write response onward however late the engine reacts; the
configuration lock and the START_BUSY check use the same signal.

**BUS_ERROR (Q1, step 3.7).** In the done_set cycle, `bus_err` = 1 sets ERROR and ERR_CODE = BUS_ERROR. It replaces an
earlier code of the same job (for example START_BUSY) and wins over a W1C of ERROR in that cycle. DONE and the
interrupt behave as in any other frame.

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
| rd_err, wr_err | in | 1 | from axi_rd_master / axi_wr_master: RRESP / BRESP != OKAY (Q1) |
| bus_err | out | 1 | to axil_regs: an error response was seen in this frame, including the current cycle |
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

**As built (step 3.6a, measured).** Four stages instead of the estimated three, same function: A scan (u, v, the
add-only X, Y; the start of the next output row is kept as a running sum, so every step is one 32-bit add),
B (D1 valid, x0, x0 = H-1, word columns wlo = y0 >> 3, whi = y1 >> 3), C (rules a, b, c and the block state),
D (rows, P1 reuse, slots, both FIFO writes). A block is closed by the first pixel of the next block, or by one
extra "flush" cycle after the last pixel of the frame, so at most one record is written per cycle: 1-pixel blocks
run at 1 descriptor per clock (rot90 64x64: 4096 descriptors in 4101 cycles from frame_start = W x H + 5). The
whole pipeline advances on ce = both FIFOs not full. The FIFOs are inside the module (distributed RAM, 16
entries each); a frame_start empties them. Blocks with nrows = 0 drive 0 on desc_slot_top / desc_slot_bot /
desc_s_col (the model writes -1 = none). 0 DSP48E1: the planner's coordinates are additions only, so they exist
twice by design (coord_gen recomputes each block start with its multiply-add). OOC post-route at 100 MHz
(`results/ooc/block_planner_summary.txt`): 591 LUT (80 LUTRAM), 703 FF, 0 BRAM, 0 DSP48E1, 0 latches,
WNS +0.373 ns. Critical path: closed block (d_x0last) -> row compares -> reuse -> slot muxes -> fetch FIFO write
data, 9.29 ns, 11 logic levels; stage C (rule decision) is close behind (slack +0.461 ns). Both are the first
candidates to pipeline if step 3.8 loses slack in the full design.

**Step 3.6c (timing only, same block lists, measured).** Five stages: A, B, C, D1 (row and range compares against
the previous fetching block, reuse decision, registered), D2 (slot ring, both FIFO writes). Stage C without min /
max: a block stays in one output row and along a row Y steps by b22, so y0, y1, wlo, whi of the valid pixels are
monotonic (D4: |Y| < 2^30, no wrap). For b22 >= 0 the block range is [wlo of the first valid pixel, whi of the
current one], for b22 < 0 the reverse; rule (c) is one compare with a bound computed in stage B (first wlo +
SPAN_MAX/8 - 1, or first whi - (SPAN_MAX/8 - 1)). Rule (b) is a flag blk_n == BLOCK_LEN computed one pixel ahead.
The reuse decision needs only the previous fetching block's rows and range (kept at D1); only the slots (ring
pointer, previous block's slots) stay a one-block-per-cycle loop, in D2. A descriptor now leaves 1 cycle later:
rot90 64x64 4096 descriptors in 4102 cycles = W x H + 6 (still 1 descriptor per clock); FIFO depths unchanged.
tb_block_planner: the same 542,485 descriptors and 533,408 fetch records, 0 mismatches (both seeds).
OOC post-route at 100 MHz: 569 LUT (80 LUTRAM), 826 FF (before 591 / 703), 0 BRAM, 0 DSP48E1, 0 latches,
WNS +2.753 ns (before +0.373 ns). Critical path: d_b0 (D2) -> reused-slot select -> ring compares -> slot -> desc
FIFO write data, 6.80 ns, 6 levels; stage C alone +3.073 ns (row_key -> rule a -> new block -> blk_n), D2 slot
registers +3.364 ns.

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
| buf_we, buf_wbank, buf_waddr, buf_wdata | out | 1, 1, [10] u, [64] | line_buf write: slot word p = (s_col / 8 + rd_word) mod 64 (words by source column, section 6.2), bank = p[0], addr = slot * 32 + p[5:1] |
| blocks_ready | out | [16] u | to pixel_fetch |
| blk_done | in | 1 | pulse from pixel_fetch: one more fetching block read out |

**Behaviour.** For the record at the head of the FIFO: update `last_user` for its slots; for each row with
fetch = 1 (top first): wait until `last_user[slot]` (before this update) < `blocks_done`, then compute the
address (row * W: one DSP48E1, 13 x 13 bit, 2-cycle pipeline) and issue one command. A record whose rows are
all reused issues nothing. `blocks_ready` increments when the last beat of the block's last command has been
written (or immediately, in order, for a block with nothing to fetch).

**Line_buf write address (spec fix, step 3.6b).** A beat is written to slot word p = (s_col / 8 + rd_word) mod 64,
where s_col is the byte column of the command (kept per slot from the command handshake: a slot gets a new command
only after every block using it was read out, so after all beats of the previous command). So word w of a source
row always sits at slot word (w mod 64), whichever block fetched it. Why: a reused row (D14 P1) keeps the slot
and the start column of the block that FETCHED it, while a later block that reuses it has its own, possibly larger,
s_col (P1 only asks that the earlier range covers the new one). The step 2.2 text addressed the slot relative to
the block's own s_col (word 0 = desc_s_col), which reads the wrong word for such a block; 72 of the 158 step 2.2 /
3.6a schedules contain one (e.g. identity 64x64, BLOCK_LEN 63: block 0 fetches columns [0, 64), block 1 = column
63 reuses it with s_col = 56). Addressing by source column needs no s_col downstream (desc_s_col / pix_s_col are
not used by pixel_fetch). It is alias-free because a slot never holds more than 64 consecutive words: SPAN_MAX
(D16 rule c) is measured on the 8-byte aligned range that is fetched, aligned_span <= 512 B = 64 words, and every
reused range lies inside the range held (scripts/check_slot_words.py: maximum 64 words reached and not exceeded,
0 reused rows outside the held range, over all schedules of step 3.6b incl. 4096 x 4096).

**As built (step 3.6b, rtl/prefetch_ctrl.v).** Prep pipeline P1 (record), P2 (row_top * W), P3 (addresses), then
the issue stage IS: record handshake in cycle t, first cmd_valid in t + 4 at the earliest (by construction; the spec
estimate was 3). The bottom row's address is the top row's + W (row_bot = row_top + 1 whenever it is fetched), so
fetch_row_bot is not used. "last_user[slot] < blocks_done" is kept as a busy bit per slot, set when a block that
uses the slot leaves IS and cleared by the blk_done of the block equal to last_user[slot]: the same condition while
fewer than 2^15 blocks are in flight (at most about 40 are), but it cannot wrap (a 16-bit modulo compare would see a
slot unused for more than 2^15 blocks as busy, possible with long runs of reused rows at 4096 x 4096). A ready queue
(16 entries, number of commands per record) turns completed commands into blocks_ready in order. Commands accepted
by axi_rd_master before a frame_start in the middle of a frame still return beats: they are counted and their beats
dropped (not written, not counted). OOC post-route at 100 MHz (`results/ooc/prefetch_ctrl_summary.txt`): 447 LUT
(22 LUTRAM: base[] and the ready queue), 882 FF (512 of them last_user), 0 BRAM, 2 DSP48E1 (Vivado duplicates
row_top * W to absorb the top and bottom address adds as DSP post-adders; 1 DSP + a fabric adder is the
alternative), 0 latches, WNS +2.431 ns; critical path is_sb -> last_user write enable, 7.28 ns, 6 levels.

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

- **Words by source column (spec fix, step 3.6b, option A).** Word w of a source row (bytes 8w .. 8w+7 of the
  row) is stored at slot word p = w mod 64, whichever block fetched it; a reused row (D14) keeps the start column
  of the block that fetched it, so slot words cannot be counted from the reusing block's own s_col (section 5).
- **Even / odd word banks.** Slot word p is stored in bank (p mod 2) at entry slot * 32 + (p >> 1).
  Two consecutive words always lie in different banks (64 is even, so also p = 63 and p + 1 = 0), so "word w and
  word w+1" is one read per bank.
- **Two copies.** Copy T serves row x0 (r1, r2), copy B serves row x1 (r3, r4). Every write goes to both
  copies of its bank.
- So there are 4 memories (T-even, T-odd, B-even, B-odd), each NSLOT x 32 = 1024 entries x 64 bit, each in
  simple dual-port mode: port A writes (from prefetch_ctrl), port B reads (for pixel_fetch). 4 reads + 1
  write per clock, every memory port used at most once per clock.
- Read address for one row: w0 = (y0 >> 3) mod 64, even bank entry = slot * 32 + (((w0 + 1) mod 64) >> 1), odd
  bank entry = slot * 32 + (w0 >> 1); the byte mux then picks r1 = byte (y0 mod 8) of word w0 and r2 = byte
  (y1 mod 8) of word w1 = (y1 >> 3) mod 64 (w1 = w0 or w0 + 1 mod 64). The (w0 + 1) mod 64 keeps the even read
  inside the slot; when its word is not needed (w1 = w0) the value is unused. y1 is always held: the block's
  range is taken over y1 = min(y0 + 1, W - 1) (memmodel chi), and rule (c) keeps it within 64 words.
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

**As built (step 3.6b, rtl/line_buf.v, measured).** Inferred block RAM (no vendor IP), 4 memories x 1024 x 64 bit,
one write and one read port each: 8 RAMB36, 1 LUT, 0 FF (`results/ooc/line_buf_summary.txt`). Compared with the
step 1.4 estimate (gray worst case 160 B footprint, 320 B ping-pong per block pair at BLOCK_LEN 64, scale0p8): the
buffer is 32 slots x 512 B = 16 KB per copy because (1) a slot must hold SPAN_MAX = 512 B (D16 allows it: scale 0.1
reaches 64 words, scripts/check_slot_words.py), (2) NSLOT = 32 keeps about 16 blocks in flight to hide the read
latency (Q2), (3) 4 reads per clock need 4 memories (2 banks x 2 copies). Even a 320 B buffer would take 4 RAMB18
(= 2 RAMB36) for the 4 read ports; NSLOT = 16 would take 4 RAMB36. In tb_fetch_path without back-pressure no
transform ever waited for a slot (slot wait 0 in group f), so NSLOT = 32 is not the limit at L = 20 / 40; whether 16
is enough is not measured (Q2 stays open).

## 7. pixel_fetch

**Purpose.** For each pixel from coord_gen: D1 validity, integer/fraction split, waits until the pixel's block
is in line_buf, reads the four neighbours, passes (xf, yf, r1..r4, valid) to the interpolator.

**Pipeline.** F1: valid (D1, signed compares), x0/y0/xf/yf, y1 = min(y0 + 1, W - 1), slot words
w0 = (y0 >> 3) mod 64, w1 = (y1 >> 3) mod 64 (words by source column, section 6.2; spec fix in step 3.6b: the
step 2.2 offsets (y0 - s_col) >> 3 read the wrong word in a block that reuses a row fetched with a smaller
s_col), bank addresses (section 6.2), block-ready check. pix_s_col is not used.
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

**As built (step 3.6b, rtl/pixel_fetch.v, measured).** F1 is the input register; while it waits for its block F2
gets a bubble (F2 / F3 still advance on ce). buf_re = F1 -> F2 transfer of a D1-valid pixel; blk_done is registered,
one cycle after the last pixel of a fetching block moved F1 -> F2. OOC post-route at 100 MHz
(`results/ooc/pixel_fetch_summary.txt`): 226 LUT, 232 FF, 0 BRAM, 0 DSP, 0 latches, WNS +5.075 ns; critical path
k -> block-ready compare -> F1 load enable, 4.64 ns. Joined with prefetch_ctrl and line_buf
(`vivado/ooc_fetch_path_wrap.v`, `results/ooc/fetch_path_summary.txt`): 667 LUT, 1114 FF, 8 RAMB36, 2 DSP48E1,
WNS +2.313 ns (prefetch_ctrl is_nt -> P3 enable); paths into the RAMs +3.368 ns, RAM -> byte muxes -> F3 at least
+4.589 ns slack.

**Measured speed (step 3.6b, tb_fetch_path group f: block_planner -> ... -> bilinear_interp, 256x192, BLOCK_LEN 64,
SPAN_MAX 512, no back-pressure; L = memory latency of tb/axi_mem.v, the real HP0 latency is unknown until 4.3).**
Cycles from frame_start to the last output pixel; estimate = memmodel max(W x H, beats + 2 x bursts).

| transform | L = 20 | L = 40 | memmodel estimate | step 3.4 (axi_rd_master alone, same schedule) | limit |
|---|---|---|---|---|---|
| identity | 49,273 | 49,293 | 49,152 | not measured | pixel rate (planner / coord_gen 1 pixel per clock) |
| rot15 | 51,895 | 90,244 | 60,797 | not measured | L = 20 pixel rate, L = 40 memory (8 bursts in flight) |
| rot37 | 84,581 | 150,343 | 93,013 | 78,642 (0.466 beats / clock) / 149,023 | memory latency (8 short bursts in flight) |
| rot90 | 108,385 | 194,211 | 115,200 | not measured | memory latency (1-beat bursts) |

Prefetch never waited for a slot in these runs (slot wait 0) and the planner is not the limit (identity reaches
W x H + 121 cycles); for the rotations axi_rd_master holds RD_OUTSTANDING bursts most of the frame (cmd_ready = 0:
48,375 of 84,581 cycles for rot37 at L = 20). The memmodel OVERHEAD = 2 estimate is pessimistic at L = 20 and
optimistic at L = 40 for short bursts, as step 3.4 found.

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

**Implementation (step 3.5, rtl/out_fifo.v).** `op_ready = !(packer holds 7 bytes && count == OUT_DEPTH)`, from
registers only (no bypass for a word leaving in the same cycle). The 8th byte and the 7 held bytes enter the FIFO
as one word at the same edge. frame_start clears the packer and the FIFO. `op_last` is not used by the logic
(axi_wr_master knows W and H); simulation checks it arrives as the 8th byte of a word. **OOC (measured, post-route,
100 MHz):** 114 LUT (86 as LUTRAM: the 64 x 64-bit FIFO), 78 FF, 0 BRAM, 0 DSP, 0 latches, WNS +6.000 ns; critical
path count -> FIFO write enable (3.38 ns).

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
| m_axi_hp0_rresp | in | [2] | not OKAY: data delivered unchanged, `rd_err` = 1 on that beat (Q1) |
| m_axi_hp0_rlast | in | 1 | checked against the expected length (simulation assertion) |
| m_axi_hp0_rvalid / rready | in / out | 1 | rready = 1 always |
| rd_valid, rd_data, rd_slot, rd_word, rd_cmd_last | out | 1, [64], [5], [6], 1 | to prefetch_ctrl |
| rd_beat | out | 1 | to ctrl_fsm (BYTES_RD += 8); same cycle as rd_valid |
| rd_err | out | 1 | one cycle per beat with RRESP != OKAY, same cycle as its rd_valid. For Q1 (BUS_ERROR status, wired in step 3.7); not connected before that |

**Handshake.** AR: valid held until ready (AXI). A burst-info FIFO (RD_OUTSTANDING entries: slot, first word,
last-of-command) records each issued burst; R beats are matched in order. **Latency.** Command to first AR:
1 cycle. R beat to rd_valid: 1 cycle (registered). **Throughput.** One AR per cycle, one beat per cycle.
**Reset.** arvalid = 0, FIFO empty. **Stall.** Stops issuing when RD_OUTSTANDING bursts are in flight or
arready = 0; never back-pressures R.

**Implementation (step 3.4, rtl/axi_rd_master.v).** The first burst of a command is formed from the input port
(bypass), so a command accepted in cycle t has ARVALID in cycle t + 1. cmd_ready = no command in progress, AR
register free, fewer than RD_OUTSTANDING bursts in flight; it therefore depends combinationally on arready
(ready -> ready, allowed by section 0). The burst length is computed separately for the port and for the command
in progress (whose 4 KB room is precomputed one cycle ahead) and selected at the end. The burst-info FIFO
entry is written one cycle after the issue from the AR register (the first R beat can come two cycles after
the issue at the earliest). A burst counts as in flight from its issue to its last R beat.

**Measured (step 3.4, tb_axi_rd_master with tb/axi_mem.v; the memory latency is a model parameter, the real HP0
latency is unknown until step 4.3).** Command -> first rd_valid = 1 + L + 1 cycles (L = AR handshake -> first
RVALID). With RD_OUTSTANDING = 8 and no back-pressure: bursts of 8 or 16 beats stream at 1.000 beat per clock
with 0 cycles between bursts for L = 20, 40, 60. Short bursts are bound by latency: about (L + 2) / 8 cycles per
burst. 1-beat bursts: 2.74 / 5.23 / 7.72 cycles per burst at L = 20 / 40 / 60. Schedule rot37 256x192
(28,183 bursts, 1.30 beats per burst): 0.466 / 0.246 / 0.167 beats per clock at L = 20 / 40 / 60. memmodel
OVERHEAD = 2 (step 1.4: beats + 2 x bursts) is pessimistic for long bursts and for short bursts while L <= about
20 cycles, and optimistic for short bursts when L is larger (rot37 at L = 40: 149,023 cycles measured vs 93,013
predicted).

**OOC (step 3.4, post-route, 100 MHz, RD_OUTSTANDING = 8).** 145 LUT (14 as LUTRAM: the burst-info FIFO), 191 FF,
0 BRAM, 0 DSP, 0 latches, WNS +4.730 ns; critical path s_active -> ar_word (2 logic levels, 4.76 ns). Port paths
inside the module (information only): cmd_addr -> s_active 5.93 ns (the bypass), arready -> AR / FIFO
registers 3.19 ns. `results/ooc/axi_rd_master_summary.txt`.

**RD_OUTSTANDING = 14 check (step 3.5; no change, the build value stays 8).** No RTL change needed (pointers wrap at
RD_OUTSTANDING - 1). tb_axi_rd_master with RD_OUTSTANDING = 14 and the memory accepting >= 14: TEST PASS (172 cases).
OOC: 148 LUT, 197 FF, WNS +4.928 ns (+3 LUT, +6 FF vs 8). Schedule rot37 256x192, beats per clock:

| L (cycles) | RD_OUTSTANDING = 8 | RD_OUTSTANDING = 14 |
|---|---|---|
| 20 | 0.466 | 0.793 |
| 40 | 0.246 | 0.426 |
| 60 | 0.167 | 0.291 |

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
| m_axi_hp1_wstrb | out | [8] | 8'hFF (gray); Option A: pass_wstrb, section 18 |
| m_axi_hp1_wlast | out | 1 | |
| m_axi_hp1_wvalid / wready | out / in | 1 | |
| m_axi_hp1_bid | in | [6] | ignored |
| m_axi_hp1_bresp | in | [2] | not OKAY: the frame still completes, `wr_err` = 1 for that response (Q1) |
| m_axi_hp1_bvalid / bready | in / out | 1 | bready = 1 always |
| wr_beat | out | 1 | to ctrl_fsm (BYTES_WR += 8); one cycle after the W handshake |
| wr_frame_done | out | 1 | to ctrl_fsm; 2 cycles after the last B response of the frame (as built) |
| wr_err | out | 1 | one cycle per B response with BRESP != OKAY, one cycle after it. For Q1 (BUS_ERROR status, wired in step 3.7); not connected before that |

**Handshake.** AW and W are independent; W beats of a burst follow in order after (or with) its AW.
**Latency.** wq_count reaching the burst length to AWVALID: 1 cycle. **Throughput.** One beat per clock.
**Reset.** All valid = 0, counters 0. **Stall.** No AW while fewer beats than the burst are in out_fifo or
WR_OUTSTANDING bursts lack a B response; awready / wready back-pressure from HP1.

**Implementation (step 3.5, rtl/axi_wr_master.v).** Rows are contiguous, so the burst address runs on through the
frame and only the words-left counter restarts at W / 8 per row. An AW needs `wq_count - pending_w >= length`
(pending_w = beats promised to issued bursts and not yet taken from out_fifo). The burst length is registered
one cycle ahead (section 15): no AW in the cycle after an issue or frame_start, so at most one AW every 2 cycles
(the pixel input fills at most one word per 8 cycles). W: a burst's length enters a W-burst FIFO one cycle after
its issue; W beats load into the registered W outputs only for bursts in that FIFO, so a burst's first WVALID
comes at the earliest one cycle after its AWVALID. A burst is outstanding from its issue to its B response;
wr_frame_done when all rows are issued and none is outstanding.

**Measured (step 3.5, tb_out_path: bilinear_interp pass-through -> out_fifo -> axi_wr_master -> tb/axi_mem.v).**
At 1 pixel per clock with no back-pressure and B latency 20 the pixel stream is never stalled (0 stall cycles,
1.000 pixel and 0.125 W beat per clock, 256x192, 2448x8, 4096x2, 8x1024). Last pixel in -> last B response:
28 to 43 cycles (B latency 20), wr_frame_done 2 cycles after the last B response. **OOC (post-route, 100 MHz,
WR_OUTSTANDING = 8):** 135 LUT (4 LUTRAM), 206 FF, 0 BRAM, 0 DSP, 0 latches, WNS +2.824 ns; critical path
pending_w -> words-available compare -> AW register enable (6 levels, 6.68 ns). Port path wq_count -> same, 6.17 ns
inside the module (wq_count is a register in out_fifo).

## 12. patrm_top

**Purpose.** Wires the modules; the IP that goes into the block design (step 4.1).

**Ports**

| port | dir | width | meaning |
|---|---|---|---|
| aclk | in | 1 | FCLK_CLK0, 100 MHz |
| aresetn | in | 1 | peripheral_aresetn of the Processor System Reset IP |
| s_axi_* | | | AXI4-Lite slave, section 1 (`s_axil_*` of axil_regs), to M_AXI_GP0 through the AXI interconnect (decided 2026-11-18, step 3.7) |
| m_axi_hp0_* (all five AXI3 channels; AR / R used) | | | section 10, to S_AXI_HP0 (64 bit). Unused outputs are constants: awvalid = wvalid = 0, bready = 1; unused inputs ignored |
| m_axi_hp1_* (all five AXI3 channels; AW / W / B used) | | | section 11, to S_AXI_HP1 (64 bit). Unused outputs are constants: arvalid = 0, rready = 1; unused inputs ignored |
| interrupt | out | 1 | to IRQ_F2P[0], level, active high |

The ports carry `X_INTERFACE_INFO` attributes (Verilog-2001 `(* *)`), so the block design of step 4.1 sees the
interfaces s_axi, m_axi_hp0, m_axi_hp1, the clock aclk, the reset aresetn and the level interrupt.

**Handshake / latency / stall.** As the submodules. Frame latency is set by the data rate (estimates in
`results/memmodel_step2_2.md`). **Reset.** Everything idle after `aresetn`; the engine starts only by a CTRL
write. **Parameters.** Section 0.

**Measured (step 3.7, tb_patrm_top with tb/axi_mem.v, 256x192, BLOCK_LEN 64, no back-pressure).** L = memory latency
of the model, used for reads and for write responses; the real HP latency is unknown until step 4.3. Fetch path =
tb_fetch_path group f at the same commit (frame_start to last output pixel, no write path). The difference is the
write drain after the last pixel: 41 cycles at L = 20, 61 at L = 40, the same for every transform, and WR_STALL = 0.

| transform | L = 20 CYCLES | pixels / clock | fetch path | L = 40 CYCLES | pixels / clock | fetch path |
|---|---|---|---|---|---|---|
| identity | 49,315 | 0.997 | 49,274 | 49,355 | 0.996 | 49,294 |
| mirror_cols | 49,315 | 0.997 | not measured | 49,355 | 0.996 | not measured |
| mirror_rows | 49,315 | 0.997 | not measured | 49,355 | 0.996 | not measured |
| rot15 | 51,937 | 0.946 | 51,896 | 90,306 | 0.544 | 90,245 |
| rot37 | 84,623 | 0.581 | 84,582 | 150,405 | 0.327 | 150,344 |
| rot90 | 108,427 | 0.453 | 108,386 | 194,273 | 0.253 | 194,212 |

**Synthesis only (step 3.7, OOC, `results/ooc/patrm_top_synth_summary.txt`; no placement or routing, timing is step
3.8).** 2,376 LUT (260 as memory), 3,475 FF, 8 RAMB36, 17 DSP48E1, 0 latches, 0 multi-driven nets. Post-route numbers
and timing of step 3.8: sections 15 and 16.

## 13. Counters: exact definitions

All counters are cleared at the end of the cycle in which `start_accept` = 1 and count only while BUSY = 1.

- **CYCLES** = number of clock cycles with `busy` = 1: from the cycle after `start_accept` up to and including the
  `wr_frame_done` cycle (section 2: BUSY falls at the end of that cycle and DONE is set). As built, `wr_frame_done`
  comes 2 cycles after the last write response is accepted (section 11), so those 2 cycles are included. With T = the
  START write handshake and DONE first visible in cycle V: CYCLES = V - T - 2 (checked by tb_patrm_top).
- **BYTES_RD** = 8 x number of R beats accepted on HP0 (rvalid & rready) in the frame.
- **BYTES_WR** = 8 x number of W beats accepted on HP1 (wvalid & wready) in the frame, partial WSTRB included.
- **WR_STALL** = number of BUSY cycles in which the interpolator output register holds a pixel that out_fifo does
  not accept (`op_valid & !op_ready`). In these cycles the whole pixel pipeline is frozen.
- **RD_STALL** = number of BUSY cycles in which pixel_fetch stage F1 holds a pixel whose block is not yet in
  line_buf (`k >= blocks_ready`) and the pipeline is not frozen by WR_STALL in the same cycle. As built (decided
  2026-11-18, step 3.6b): `rd_stall = F1 waiting && ip_ready`; ip_ready (= bilinear_interp ce) is 0 exactly in
  the WR_STALL cycles, so the two never count the same cycle.
- RD_STALL and WR_STALL never count the same cycle. Cycles where the pipeline simply has no pixel (frame start,
  the planner or coord_gen behind, the drain after the last pixel) count in neither.

## 14. Bayer hooks (detail in steps 5.1 and 6.1)

- **Option A** (MODE 1): specified in section 18 (step 5.1): four plane passes (R, Gr, Gb, B) run by the new module
  bayer_seq with b = (b11, b12, T_px, b21, b22, T_py) from the T registers (D12) and plane size (W/2, H/2) for D1;
  memory row 2x + o_row, column 2y + o_col; WSTRB-masked writes into the interleaved buffer (D19).
- **Option B** (MODE 2): four lanes share one coord_gen; lane p adds T_p - T_R (register difference, D6).
  The six physical rows seen in step 1.4 are workload-specific. Legal transforms can also exceed a single
  512-byte column window. See the [step 6.1 design and verification](../docs/step-6.1-bayer-b.md) for the fetch policy and its verification status.
- Shared now: the T registers, MODE, BUILD_ID.MODES, and the plane-row / plane-column parameters of the planner.

## 15. Timing at 100 MHz (10 ns; whole engine MEASURED in step 3.8, module rows from the module runs)

| module | likely critical path | how it is pipelined |
|---|---|---|
| block_planner | MEASURED (step 3.6c): stage C row_key -> rule a -> new block -> blk_n, 6.41 ns, slack +3.073 ns (step 3.6a: 9.41 ns, +0.461 ns) | min / max replaced by "first" and "current" (monotonic along a row); rule (c) bound precomputed in B; rule (b) flag one pixel ahead |
| block_planner | MEASURED (step 3.6c): D2 d_b0 -> slot muxes -> desc FIFO write, 6.80 ns, WNS +2.753 ns (module critical path; step 3.6a: 9.29 ns, +0.373 ns) | D split: D1 reuse decision registered, D2 slot ring + FIFO writes |
| coord_gen | MEASURED (step 3.2): start-FIFO not-empty -> stepper load / add, 6.2 ns (WNS +3.817 ns); S3 3-input add 5.4 ns | 3 stages S1-S3 (DSP P register, 32-bit add, 3-input add); stepper is one 32-bit add |
| prefetch_ctrl | MEASURED (step 3.6b): is_sb -> last_user write enable 7.28 ns, WNS +2.431 ns; row * W + s_col + SRC_ADDR is in the DSPs (C + A*B, P register) | P1 / P2 / P3 prep pipeline; DSP with A/B, M and P registers |
| pixel_fetch | MEASURED (step 3.6b): k -> block-ready compare -> F1 load 4.64 ns, WNS +5.075 ns; with line_buf (wrapper): WNS +2.313 ns (in prefetch_ctrl), RAM -> byte mux -> F3 slack >= +4.589 ns | read in F2, mux in F3 (registered); BRAM output register available as a fallback |
| bilinear_interp | stage 2: 3-input 16-bit add + 17-bit subtract | DSP M/P registers in stages 1 and 3; stage 4 adder tree 24 bit (two levels) |
| axi_rd_master | MEASURED (step 3.4): s_active -> ar_word 4.76 ns, WNS +4.730 ns; port path cmd_addr -> burst length -> s_active 5.93 ns | registered AR outputs; 4 KB room of the command in progress computed one cycle ahead |
| axi_wr_master | MEASURED (step 3.5): pending_w -> words-available compare -> AW enable 6.68 ns, WNS +2.824 ns | registered outputs; length computed one cycle ahead |
| out_fifo | MEASURED (step 3.5): count -> FIFO write enable 3.38 ns, WNS +6.000 ns | registered count, LUTRAM FIFO |
| axil_regs | read mux 27 x 32 bit | registered read data |

**Whole engine, MEASURED (step 3.8).** `vivado/ooc_patrm_top.tcl`, OOC, post-route, xc7z020clg484-1, aclk 10 ns, no I/O
delays (`results/ooc/patrm_top_summary.txt`).

| quantity | value |
|---|---|
| WNS / TNS | +1.634 ns / 0.000 ns (0 of 9,954 endpoints failing) |
| WHS | +0.026 ns (0 failing) |
| Fmax implied by WNS | about 119.5 MHz, ESTIMATE = 1000 / (10 - 1.634); not a run at that clock (the 150 MHz experiment is step 7.3) |
| critical path | u_planner/d_rp_reg[2] -> descriptor FIFO LUTRAM read (desc_v0[9]) -> u_coord/m22_l_reg/B[9]: 1 logic level, data path 4.542 ns (0.604 logic + 3.938 net), plus 3.740 ns DSP48E1 setup because the B input and multiplier are not registered |

Worst setup slack of the paths ending in each module, whole engine vs the module's own run:

| module | whole engine (ns) | standalone WNS (ns) |
|---|---|---|
| axil_regs | +3.729 | +3.948 |
| ctrl_fsm | +3.246 | no standalone run |
| block_planner | +2.338 | +2.753 |
| coord_gen | **+1.634** | +3.817 |
| prefetch_ctrl | +2.285 | +2.431 |
| axi_rd_master | +2.358 | +4.730 |
| line_buf | +2.580 | no register-to-register path |
| pixel_fetch | +3.295 | +5.075 |
| bilinear_interp | +2.559 | +4.252 |
| out_fifo | +2.867 | +6.000 |
| axi_wr_master | +2.725 | +2.824 |

The whole-engine slack is lower where a path now crosses modules: in a module run those paths start or end at
unconstrained ports. OOC limits: the clock has no clock tree (`HD.CLK_SRC` unset, Timing 38-242) and ports have no
partition pins (Route 35-198), so skew, hold (+0.026 ns) and port paths are confirmed only by the full build of step
4.1. Information only, with 0 ns I/O delays: the slowest input path is `aresetn` -> u_prefetch/buf_we_reg/R, which needs
8.197 ns of the 10 ns; the AXI inputs need at most 4.819 ns and the AXI outputs at most 3.232 ns.

## 16. Resources (MEASURED, step 3.8; XC7Z020: 53,200 LUT, 17,400 LUT usable as memory, 106,400 FF, 140 RAMB36, 220 DSP48E1)

Whole engine, OOC post-route: **2,301 LUT (4.33 %)**, of which 2,050 logic and 251 memory (232 LUTRAM + 19 SRL, 1.44 %
of the memory-capable LUTs); **3,475 FF (3.27 %)**; **8 RAMB36 (5.71 %)**; **17 DSP48E1 (7.73 %)**; 1,319 slices
(9.92 %); 0 latches; 0 multi-driven nets.

Per instance, next to the standalone OOC runs of steps 3.1-3.6c:

| module (instance) | LUT | of which LUTRAM + SRL | FF | RAMB36 | DSP48E1 | standalone LUT | standalone LUTRAM + SRL | standalone FF | standalone RAMB36 / DSP |
|---|---|---|---|---|---|---|---|---|---|
| axil_regs (u_regs) | 397 | 0 | 596 | 0 | 0 | 357 | 0 | 595 | 0 / 0 |
| ctrl_fsm (u_ctrl) | 72 | 0 | 157 | 0 | 0 | no run | no run | no run | no run |
| block_planner (u_planner) | 562 | 64 | 812 | 0 | 0 | 569 | 80 | 826 | 0 / 0 |
| coord_gen (u_coord) | 269 | 58 | 352 | 0 | 8 | 284 | 68 | 367 | 0 / 8 |
| prefetch_ctrl (u_prefetch) | 486 | 24 | 859 | 0 | 2 | 447 | 22 | 882 | 0 / 2 |
| axi_rd_master (u_rd) | 89 | 14 | 191 | 0 | 0 | 145 | 14 | 191 | 0 / 0 |
| line_buf (u_buf) | 128 | 0 | 0 | 8 | 0 | 1 | 0 | 0 | 8 / 0 |
| pixel_fetch (u_fetch) | 100 | 0 | 229 | 0 | 0 | 226 | 0 | 232 | 0 / 0 |
| bilinear_interp (u_interp, see below) | 47 | 1 | 5 | 0 | 7 | 80 | 1 | 9 | 0 / 7 |
| out_fifo (u_ofifo) | 130 | 86 | 78 | 0 | 0 | 114 | 86 | 78 | 0 / 0 |
| axi_wr_master (u_wr) | 99 | 4 | 196 | 0 | 0 | 135 | 4 | 206 | 0 / 0 |
| **sum of the rows** | 2,379 | 251 | 3,475 | 8 | 17 | 2,358 | 275 | 3,386 | 8 / 17 |

- The LUT sum exceeds the 2,301 total because a LUT shared by two instances (LUT combining) is counted in both rows.
- Vivado's hierarchical report has no row for u_interp, so that row is counted from its leaf cells, before LUT combining.
- Rows differ from the module runs because synthesis optimises across module boundaries. The clearest case: the 128
  LUT6 of the pixel byte muxes are named after u_buf in the whole engine (`u_buf/ip_r1[..]`), so line_buf + pixel_fetch
  is 228 LUT against 227 standalone.

Not included: AXI interconnect, protocol converters, the PS and the Processor System Reset IP of the block design.

**Power (ESTIMATE, step 3.8).** `report_power`, default settings, vectorless, confidence Medium, engine only without the
PS: 0.144 W total on-chip = 0.040 W dynamic + 0.104 W device static. No simulated switching activity is used.

## 17. Open questions (need a decision; defaults used in this spec)

- **Q1 AXI error responses. Closed (step 3.7).** A frame with RRESP / BRESP != OKAY still completes (DONE + interrupt
  as normal, data used as is) and STATUS.ERROR is set at the end of the frame with ERR_CODE 6 BUS_ERROR, sticky until
  cleared by W1C or an accepted start (`spec/regs.json`, sections 1 and 2).
- **Q2 NSLOT.** 32 (16 KB, 8 RAMB36) proposed; 16 halves the BRAM. Decide after the step 3.6 latency tests.
  Step 3.6b (built with 32): 8 RAMB36 measured; with no back-pressure no transform waited for a slot at L = 20 / 40
  (the rotations are limited by RD_OUTSTANDING = 8 short bursts). Step 3.6c data (tb_fetch_path with
  --define TB_SLOT_BITS=4, all groups TEST PASS): line_buf with 16 slots = 4 RAMB36 (OOC). Group f (no
  back-pressure, 256x192), cycles NSLOT 32 -> 16: L = 20 identity 49,274 -> 49,274, rot15 51,896 -> 52,041
  (+0.3 %), rot37 84,582 -> 86,667 (+2.5 %), rot90 108,386 -> 111,420 (+2.8 %); L = 40 rot15 90,245 -> 91,785
  (+1.7 %), rot37 150,344 -> 152,791 (+1.6 %), rot90 194,212 -> 194,235 (0 %). Slot-wait cycles 0 -> 3,279..5,616
  for the rotations. Group d (random memory and back-pressure): cycles within -0.4 % .. +1.5 %. Still open: user
  decides; build value stays 32.
- **Q3 Outstanding reads. Closed (2026-11-17).** UG585 (Zynq-7000 TRM), AXI_HP Interfaces, Features: read
  acceptance 14 to 70 commands, write acceptance 8 to 32 commands, both depending on the burst length.
  RD_OUTSTANDING = 8 is within the read minimum; axi_wr_master (step 3.5) uses at most 8 outstanding writes.

## 18. Bayer Option A (MODE 1, step 5.1)

**Scope.** What changes when the engine runs CTRL.MODE = 1. Decisions used: D2 / D12 (T_p from the T registers), D19
(WSTRB-masked writes into the interleaved buffer), D20 (file layout). Executable form of this section:
`model/bayer_a.py`; check: `model/test_bayer_a.py` (bit-exact with `model/bayer.py` warp_bayer, counters equal to
`model/memmodel.py`, buffer and addressing bounds). Gray mode (MODE 0) must stay cycle-identical to the step 3.7 engine:
same CYCLES, same bursts, same outputs (tb_patrm_top and tb_system unchanged and passing).

### 18.1 One job = four plane passes

A job is accepted once (axil_regs start checks, unchanged: Bayer W multiple of 16, H even) and runs four passes in
the order R, Gr, Gb, B (`bayer.PLANES`). Each pass is a grayscale frame over the plane grid with these settings:

| per-pass value | gray (MODE 0, 1 pass) | Option A pass p, offset o = (o_row, o_col) |
|---|---|---|
| coefficients | B11, B12, B13, B21, B22, B23 | B11, B12, **T_p_X**, B21, B22, **T_p_Y** (registers, D12; B13 / B23 unused) |
| output grid (scan, D1, clamps) | H x W | **Hp x Wp = H/2 x W/2** (D1: 0 <= X <= (Hp-1)<<16, 0 <= Y <= (Wp-1)<<16) |
| source memory row of plane row x | x | **2x + o_row** |
| source memory column of plane column y | y | **2y + o_col** |
| x1, y1 clamp | min(x0+1, H-1), min(y0+1, W-1) | min(x0+1, Hp-1), min(y0+1, Wp-1) (in plane coordinates) |
| row stride in memory | W | W (the full mosaic row) |
| output row of grid row u | DST + u W | **DST + (2u + o_row) W** |
| output bytes of a 64-bit word | 8 pixels, byte k = pixel 8j+k | **4 pixels, byte 2k + o_col = plane pixel 4j+k, other bytes 0** |
| WSTRB | 8'hFF | **8'h55 << o_col** (R, Gb: 8'h55; Gr, B: 8'hAA) |

| pass | plane | o_row | o_col | T registers | WSTRB | output rows |
|---|---|---|---|---|---|---|
| 0 | R | 0 | 0 | T_R_X, T_R_Y | 8'h55 | even |
| 1 | Gr | 0 | 1 | T_GR_X, T_GR_Y | 8'hAA | even |
| 2 | Gb | 1 | 0 | T_GB_X, T_GB_Y | 8'h55 | odd |
| 3 | B | 1 | 1 | T_B_X, T_B_Y | 8'hAA | odd |

Every output byte is written by exactly one pass (test_bayer_a [1]), so no pre-fill of the output is needed; the
board tests still fill it with 0xA5 to catch a missed byte. Passes write disjoint bytes and read only the source, so
their order in DDR does not matter for the result.

**Pass sequencing (chosen for simplicity).** Pass p+1 starts only after pass p's last write response (its
wr_frame_done). The cost is one pipeline fill and one write drain per pass: about 3 x 100 cycles per job (ESTIMATE,
from the step 3.7 drain of 41 to 61 cycles plus the fill), below 0.3 % of a 480x272 job. Overlapping passes is a
possible later optimisation, not part of 5.2.

### 18.2 New module: bayer_seq (rtl/bayer_seq.v)

**Purpose.** Turns one accepted job into one pass (gray) or four passes (Option A) and gives every data-path module
the per-pass values of 18.1. It owns the pass counter; ctrl_fsm keeps BUSY and the counters for the whole job.

| port | dir | width | meaning |
|---|---|---|---|
| aclk, aresetn | in | 1 | |
| start_accept | in | 1 | from axil_regs: a job was accepted |
| cfg_mode | in | [2] u | CTRL.MODE, sampled at start_accept |
| cfg_width, cfg_height | in | [13] u | W, H of the job (full mosaic) |
| cfg_b13, cfg_b23 | in | [32] s | gray offsets |
| cfg_t_r_x ... cfg_t_b_y | in | 8 x [32] s | T registers |
| pass_done | in | 1 | wr_frame_done of axi_wr_master: the current pass is complete in DDR |
| frame_start | out | 1 | one-cycle pulse per pass to every data-path module (replaces ctrl_fsm's) |
| job_done | out | 1 | one-cycle pulse after the last pass's pass_done (to ctrl_fsm) |
| pass_index | out | [2] u | 0..3 (0 in gray) |
| pass_b13, pass_b23 | out | [32] s | B13 / B23 (gray) or T_p_X / T_p_Y |
| pass_width, pass_height | out | [13] u | grid size: W, H (gray) or W/2, H/2 |
| pass_o_row, pass_o_col | out | 1 | plane offset (0 in gray) |
| pass_stride2 | out | 1 | 1 in Option A: memory row = 2x + o_row, column = 2y + o_col |
| pass_wstrb | out | [8] | 8'hFF (gray) or 8'h55 << o_col |

**Behaviour.** All pass_* outputs are registers, loaded in the cycle before frame_start and held for the whole pass
(modules may still latch them at frame_start, as they latch cfg_* today). start_accept -> pass 0 values ->
frame_start one cycle after start_accept (the same cycle as before, so gray timing is unchanged). pass_done of a
pass that is not the last -> next pass values -> frame_start (as built: 1 cycle after pass_done, 18.7). pass_done of the
last pass -> job_done in the same cycle as the step 3.7 done_set would have come (gray: CYCLES unchanged).
**Parameters.** MODES (bit 1 = Option A built). With MODES = 3'b001 the Option A logic is constant 0 and is removed
by synthesis (gray build resources: measured again in 5.2). **Reset.** Idle, pass 0 values, no pulses.

**ctrl_fsm change.** It no longer drives frame_start; done_set comes from job_done instead of wr_frame_done; BUSY
spans all passes. bus_err collects error responses of the whole job.

### 18.3 Changes in the existing modules (Option A only; with pass_stride2 = 0 each module is the gray module)

- **block_planner.** Scans pass_height x pass_width with b13 / b23 = pass_b13 / pass_b23; D1 and the x1, y1 clamps on
  the plane size. Memory columns mc = (y << stride2) | o_col drive the word columns (wlo = mc0 >> 3, whi = mc1 >> 3)
  and rule (c) (span in memory bytes, SPAN_MAX unchanged). Fetch rows are memory rows: fetch_row_top =
  (x0 << stride2) | o_row, fetch_row_bot = (x1 << stride2) | o_row. Reuse (D14 P1) compares memory rows and ranges,
  exactly as `memmodel.schedule()` does for the "A-<plane>" passes. mc stays monotonic along an output row, so the
  step 3.6c "first / current" range logic is unchanged. Field widths unchanged (memory row and column < 4096).
- **coord_gen.** Uses pass_b13 / pass_b23 instead of cfg_b13 / cfg_b23; u, v0 are plane coordinates. No other change.
- **prefetch_ctrl.** Address of the top row unchanged: SRC_ADDR + row_top * W + s_col with the full W. The bottom row
  is the next PLANE row: address = top + (W << stride2) (as built today: top + W).
- **pixel_fetch.** D1 and the clamps on pass_width / pass_height. Slot words and byte selects from memory columns:
  mc0 = (y0 << stride2) | o_col, mc1 = (y1 << stride2) | o_col, w0 = (mc0 >> 3) mod 64, w1 = (mc1 >> 3) mod 64,
  r1 = byte (mc0 mod 8) of w0, r2 = byte (mc1 mod 8) of w1 (rows likewise). mc1 - mc0 is 0 or 2, so w1 is w0 or
  w0 + 1 and the even / odd bank scheme of section 6.2 is unchanged ("stride-2 select").
- **out_fifo.** Option A packs 4 pixels per word: pixel k of the group goes to byte 2k + o_col, the other bytes are
  0. A plane row of Wp = W/2 pixels still gives W/8 words, so wq_count and the burst rule are unchanged.
- **axi_wr_master.** Rows per pass = pass_height, words per row = W/8 (full row). Row address = DST_ADDR +
  o_row x W + u x (W << stride2) (the address no longer runs on from row to row in Option A). Each row is split like a
  gray row (<= 16 beats, no 4 KB crossing). m_axi_hp1_wstrb = pass_wstrb. wr_frame_done ends the PASS (-> bayer_seq).
- **Unchanged:** axil_regs (registers, start checks and Bayer size rules exist since step 3.1; BUILD_ID.MODES /
  BUILD_TYPE from parameters), line_buf, axi_rd_master, bilinear_interp.

### 18.4 Counters (section 13, per job)

Cleared at the accepted start, counted over all four passes including the gaps between them. CYCLES ends with the
last pass. BYTES_RD = 8 x R beats of the four read schedules (= `memmodel.frame_stats("A")` bytes_read).
BYTES_WR = 8 x W beats including masked beats = **2 x W x H** (each full row is written by two passes).
RD_STALL / WR_STALL: unchanged definitions, summed over the passes.

### 18.5 Expected cost (ESTIMATES from model/memmodel.py, L = 64, P1, OVERHEAD = 2; not measurements)

| size (W x H) | transform | gray bytes read | Option A bytes read | read / output (gray, A) | est. cycles gray | est. cycles A |
|---|---|---|---|---|---|---|
| 480x272 | identity | 291,048 | 546,336 | 2.23, 4.18 | 130,560 | 130,560 |
| 480x272 | rot15 | 568,496 | 897,152 | 4.35, 6.87 | 158,348 | 227,014 |
| 480x272 | rot37 | 730,056 | 974,752 | 5.59, 7.47 | 231,325 | 281,668 |
| 480x272 | rot90 | 665,856 | 739,840 | 5.10, 5.67 | 231,234 | 240,516 |
| 2448x2048 | identity | 11,269,440 | 21,288,800 | 2.25, 4.25 | 5,013,504 | 5,013,504 |
| 2448x2048 | rot15 | 22,373,664 | 35,422,000 | 4.46, 7.07 | 6,216,958 | 8,937,930 |
| 2448x2048 | rot37 | 30,370,792 | 40,789,920 | 6.06, 8.14 | 9,615,439 | 11,748,358 |
| 2448x2048 | rot90 | 37,748,736 | 41,943,040 | 7.53, 8.37 | 13,109,248 | 13,635,584 |

Option A reads the full-resolution bytes around each plane span, so it reads up to about 2x what gray reads; it is
compute-bound at 1 pixel per clock when the reads keep up (identity) and read-bound otherwise. Writes are 2 x W x H
bus bytes (gray: W x H). The board gray runs (step 4.3) were slower than these estimates for steep rotations
(read latency, section 10), so Option A will be too; the real numbers come from step 5.3.

**Resources (ESTIMATE).** bayer_seq: a 2-bit counter and about 100 bits of registered pass values, roughly 100 LUT and
150 FF. Shifts / ORs in block_planner, pixel_fetch and out_fifo, the row address step and strobe in axi_wr_master: a
few dozen LUT each. No new DSP48E1, no new BRAM (line_buf and its 64-word slot bound are unchanged: test_bayer_a [6]
reaches 64 words and never exceeds it). Measured in step 5.2 / 5.3.

### 18.6 Verification plan (step 5.2)

- tb_bayer_seq: pass order, pass_* values against `bayer_a.pass_configs`, frame_start / job_done timing, gray = one
  pass with the step 3.7 timing, reset and a new start after a job.
- tb_patrm_top in MODE 1 with vectors from `model/bayer_a.py` (per pass: block / burst schedules from
  `memmodel.schedule()`, final output mosaic), sizes 64x64, 128x96, 256x192, 208x120, every transform; BYTES_RD and
  BYTES_WR equal to 18.4; strobes checked by tb/axi_mem.v (a byte with strobe 0 must not change).
- The whole gray regression unchanged (`scripts/regress.py`), including tb_system.
- Fault defines (as in step 3.7): wrong o_col in one pass, WSTRB 8'hFF, bottom row at top + W must each fail.

### 18.7 As built (step 5.2, measured)

**RTL.** New `rtl/bayer_seq.v`; small changes in block_planner, prefetch_ctrl, pixel_fetch, out_fifo, axi_wr_master and
patrm_top (wiring only for coord_gen and ctrl_fsm: coord_gen gets pass_b13 / pass_b23 on its cfg_b13 / cfg_b23 ports,
ctrl_fsm gets job_done on its wr_frame_done port and its own frame_start output is left open). Differences from the
5.1 text: frame_start of the next pass comes **1 cycle** after pass_done (the 5.1 estimate was 2). With MODES = 3'b001
the Option A logic is removed, but the per-pass registers of bayer_seq stay as copies of B13, B23, W and H (see the
resource table below). Test-only faults: PATRM_FAULT_A_OCOL (pixel_fetch ignores o_col), PATRM_FAULT_A_WSTRB
(axi_wr_master writes 8'hFF), PATRM_FAULT_A_ROWSTEP (prefetch_ctrl bottom row at top + W).

**Simulation.** tb_bayer_seq (MODES 3 and MODES 1 instances side by side; 204 random jobs, 510 passes: pass values,
frame_start / job_done timing, stability during a pass, stray pass_done, aresetn mid-job) TEST PASS. tb_patrm_top in two
builds of the same file: gray (cases.txt, 147 frames, 3,498,752 bytes) TEST PASS with the step 3.7 speed table
unchanged to the cycle (L = 20: identity 49,315, rot15 51,937, rot37 84,623, rot90 108,427; L = 40: 49,355, 90,306,
150,405, 194,273); Option A build (`--define TB_BAYER_A`, MODES 3, cases_bayer_a.txt: 134 MODE 1 jobs and 13 gray jobs,
147 frames, 3,196,672 bytes) TEST PASS: output mosaic = bayer.warp_bayer, 4 frame_start pulses per MODE 1 job, WSTRB
8'h55 / 8'hAA of the pass in progress on every W beat, BYTES_RD and the AR / AW burst counts = bayer_a / memmodel,
BYTES_WR = 2 x W x H, bus errors, locks, polling, rejected starts (Bayer W not a multiple of 16, H odd, MODE 2, MODE 3),
resets in pass 0, a middle pass and the last pass, gray and MODE 1 jobs back to back. Each of the three faults makes
the Option A build fail on its first job. Full regression REGRESSION PASS, 41 items (incl. tb_system with bayer_seq in
the block design).

**Speed (simulation, tb_patrm_top group h, 256x192, BLOCK_LEN 64; L = model memory latency; not hardware).**

| transform | gray L = 20 | Option A L = 20 | gray L = 40 | Option A L = 40 |
|---|---|---|---|---|
| identity | 49,315 | 49,868 | 49,355 | 50,028 |
| rot15 | 51,937 | 65,510 | 90,306 | 119,685 |
| rot37 | 84,623 | 93,846 | 150,405 | 172,729 |
| rot90 | 108,427 | 103,384 | 194,273 | 195,204 |

Identity / mirrors: Option A costs about 550 cycles more than gray at L = 20 (three extra pass starts and drains,
about 185 cycles each). Rotations: Option A reads more bytes (18.5) and is read-latency bound like gray; rot90 is
slightly faster in Option A at L = 20 (shorter plane rows: fewer bursts per block row). Board numbers: step 5.3.

**Resources and timing (OOC post-route, xc7z020clg484-1, 100 MHz, measured).** `vivado/ooc_patrm_top.tcl
-tclargs variant=bayer_a` -> `results/ooc/patrm_top_bayer_a_*`; the gray re-check with the step 5.2 RTL was run into a
scratch folder (results/ooc/patrm_top_* stay the step 3.8 reference).

| build | LUT | FF | RAMB36 | DSP48E1 | WNS | WHS | critical path |
|---|---|---|---|---|---|---|---|
| gray, step 3.8 (reference) | 2,301 | 3,475 | 8 | 17 | +1.634 ns | +0.026 ns | planner desc FIFO -> coord_gen DSP B input |
| gray, step 5.2 RTL | 2,372 | 3,574 | 8 | 17 | +1.618 ns | +0.026 ns | the same kind: planner desc FIFO -> coord_gen DSP B input |
| Option A (MODES 3) | 2,620 | 3,612 | 8 | 17 | +1.238 ns | +0.026 ns | u_planner/k_s2_reg -> u_ofifo/count (7 levels, 8.79 ns) |

Option A over the gray build of the same RTL: +248 LUT, +38 FF, no BRAM, no DSP, 0 latches. Largest parts: axil_regs
528 vs 384 LUT (the eight T registers are now read by bayer_seq, so synthesis keeps them), bayer_seq 49 vs 17 LUT
(99 vs 92 FF), out_fifo 223 vs 196, planner 577 vs 562. The gray build of the step 5.2 RTL is +71 LUT / +99 FF over
step 3.8: out_fifo 196 vs 130 LUT (the 64-bit packer with byte insert costs LUTs also in gray mode) and the bayer_seq
pass registers (92 FF, copies of B13, B23, W, H). Vivado merged the equivalent stride2 flags of block_planner, pixel_fetch and
out_fifo (all loaded from pass_stride2 at frame_start) into u_planner/k_s2_reg; its fan-out is the critical path
(slack +1.238 ns). Power ESTIMATE (vectorless, engine only): 0.159 W (0.055 dynamic + 0.104 static).

## 19. Bayer Option B RTL (step 6.2)

Build parameters are MODES=7 and BUILD_TYPE=2. MODE 2 starts a single full-frame job. The existing MODE 0/1 sequencer supplies a single start and existing contiguous-row writer configuration for B. The shared HP0 and HP1 masters, configuration registers, counters and final write-response completion logic remain the bus interface.

- **bayer_lanes** feeds the existing three-stage coordinate generator with plane-row chunks of up to 64 positions. One R coordinate plus the three latched register differences feeds **bayer_geometry**. The planner buffers up to 64 base coordinates so a group can be replayed during interpolation. The actual DDR block boundaries follow the row-key, BLOCK_LEN and aligned span rules independently of coordinate-generator chunks.
- **bayer_store** pins the previous fetching group's tags, allocates missed windows in the remaining slots, and broadcasts returned words into four banked line-buffer copies. This implementation waits for each missed window's final returned beat before issuing the next window. In fallback mode the controller emits sorted, deduplicated runs of adjacent words per tile. RD_STALL counts occupied-group preparation/fetch cycles before lane dispatch, excluding cycles already counted as WR_STALL.
- The four **bilinear_interp** instances share valid and output ready. A held read stage carries fractions and validity alongside the synchronous RAM outputs. **bayer_merge** collects the pair of rows and drains even then odd. Its counted word interface exposes the remaining row-buffer words directly to the existing writer. This uses the two row buffers as the queue and avoids a separate copy into the legacy output FIFO.
- The testbench compares every completed B frame with both references, checks every accepted W beat and every AR/AW address and length, and checks fallback tile count, guards, completion and interrupt. The combined build also runs gray and A jobs. Test-only TB_RECT_ONLY disables the fallback exclusively for workloads that fit the rectangular path.

**Vivado 2025.2 xsim results.** The combined build completed 24 frames, including 22 B frames and one each in gray and A mode. All 135,552 output bytes matched. The AXI memory checker reported zero protocol violations. Four mid-job resets and read/write error responses were exercised. The gray-only and Option A builds each passed their 147-frame regressions.

| B workload | Fallback tiles | Fallback-enabled cycles | Rectangular-only cycles |
|---|---:|---:|---:|
| Identity 64 x 64 | 0 | 3,865 | 3,865 |
| rot37 64 x 64 | 0 | 35,947 | 35,947 |
| rot37 208 x 120 | 0 | 258,455 | 258,455 |
| Tall footprint 64 x 128 | 32 / 2048 | 5,513 | exceeds row capacity |
| Wide footprint 2048 x 2 | 512 / 1024 | 14,517 | exceeds slot width |

All 20 paired ordinary B frames had identical cycles with identical AXI timing and seeds. Tall and wide required 480 and 6,256 read bytes respectively. Keep the fallback for the next milestone. The absolute performance of rotations is limited by fetch waits in this serialized controller (240,749 RD_STALL cycles for rot37 at 208 x 120). Check area and post-route clock timing in 6.3 and measure frame times on Rev D later. Cycle equivalence alone cannot establish equal clock frequency.

**Reproduce** from the repo root using the team's simulator environment:

```powershell
python scripts/gen_bayer_b_vectors.py
python scripts/sim.py --top tb_patrm_top -f tb/patrm_top.f --incdir rtl --define TB_BAYER_B --plusarg VEC_DIR=data/vectors
python scripts/sim.py --top tb_patrm_top -f tb/patrm_top.f --incdir rtl --define TB_BAYER_B --define TB_RECT_ONLY --plusarg VEC_DIR=data/vectors
```

The full regression preserves logs for both configurations under build/regress and prints the paired cycle difference. Step 6.1 documents the coverage bounds and rollback criteria. The RTL and tests require no board.
