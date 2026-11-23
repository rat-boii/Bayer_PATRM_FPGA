# Step 6.1 | Four-lane Bayer Option B design

## 6.1.1 | What Option B can reuse

This checkpoint traces one frame from the job registers to DDR. Option B is intended to produce the same final mosaic as Option A and the Python reference. It changes the order of work. A lane processes one of the four Bayer planes, with its own source coordinates and edge checks.

## Follow one output tile

Take a 16 x 4 test mosaic with byte values 0 through 63 in row order and apply the identity transform. At plane position (0,0), the four expected outputs are R = 0, Gr = 1, Gb = 16 and B = 17. The top two bytes belong at destination offsets 0 and 1. The bottom two belong at offsets 16 and 17. The gap is one image-row stride. A merger that writes all four bytes consecutively would corrupt the first row.

Option A visits the entire R plane, then Gr, Gb and B. Each pass writes alternating bytes into its own row parity with a byte-enable mask. Option B visits each plane position once and produces the four values as a group. The writer must assemble even and odd destination rows into full words. Exact buffering and backpressure are later checkpoints.

## Data flow and reuse

```text
Option A today
  job -> four-pass sequencer -> block planner -> coordinate generator
                              -> prefetch -> HP0 reads -> line buffer
  coordinate + buffered neighbours -> interpolator -> masked word packer -> HP1

Option B design target
  job -> one plane-grid scan -> union block planner -> one R coordinate + lane offsets
                               -> shared fetch -> HP0 reads -> buffered mosaic rows
  four sets of neighbours -> four interpolators -> even/odd row packing -> HP1
```

| Existing RTL | What carries forward | Work specific to B |
|---|---|---|
| patrm_top, axil_regs, ctrl_fsm, bayer_seq | Job registers, plane shifts, counters, interrupt and final write-response completion. The sequencer implements gray and A today. | Select a single plane-grid pass for mode 2 and route its completion. Verify mode capability and counter inputs at integration. |
| coord_gen | One affine coordinate calculation for R and the existing add-per-column step. | Each lane derives its coordinate from the R result using the registered shift difference T_p - T_R. The top/bottom slot fields that travel with coordinates currently describe one lane. |
| block_planner, prefetch_ctrl, axi_rd_master | Block-length and span rules, row reuse policy, one HP0 AXI burst engine. | Determine the rows and column range covering all valid lanes. The current planner names two slots; prefetch tracks top/bottom. Define how B represents requests, readiness and slot lifetime. |
| line_buf, pixel_fetch | Banked storage, same-colour neighbour addressing, plane-level edge and clamp rules. | Supply the correct four neighbours and fractions to each lane. The current buffer routes two row copies to one pixel fetch. Port count and arbitration need a design. |
| bilinear_interp | Use four instances of the same fixed-point interpolation module. Each instance computes one output byte. | Keep four results from the same output position together through stalls, including a zero for an out-of-range lane. |
| out_fifo, axi_wr_master | Reuse the full-word AXI write protocol, burst splitting and final response tracking where the agreed packing order permits. | Assemble RG and Gb/B rows, supply the corresponding addresses in the chosen order and enable all eight bytes per full word. A's single-plane masked packer cannot accept a four-value group. |

## Checks run for this checkpoint

- The Option A job model and the golden Bayer model reproduced all 64 identity input bytes exactly. The first tile was [[0, 1], [16, 17]].
- For that frame the memory model gives A four single-lane passes and 16 write beats; B one four-lane pass and 8 write beats. Each beat is 8 bus bytes. Both modes produce a 64-byte image. These are model results.
- The six-physical-row statement in section 14 of the interface specification does not hold across the accepted transform range. Reproduce with a 64 x 64 frame and inverse coefficients (7,0,0,0,1,0) scaled by 65536. The full and plane D4 checks accept it. At output plane position (0,0), R and Gr start at plane row 0, Gb and B at row 3. Their neighbour row pairs are 0/1 and 3/4. The current memory model fetches the covering interval 0 through 4 as five physical row pairs, including the gap, and reports max_rows = 10. Ten is an example, not an upper bound. Carry the bound and scheduling question into checkpoint 6.1.3 before sizing the store.
- Verification entry points: model/bayer_a.py (run_job), model/bayer.py (warp_bayer, check_bayer_transform), model/memmodel.py (build_passes, write_stats, pixel_needs, frame_stats). RTL wiring is in rtl/patrm_top.v. The reference and interfaces are unchanged by this review.

## 6.1.2 | Coordinates of four lanes

Scan plane positions (u,v) in row order. Latch the four X/Y shift pairs written by the ARM at job start. Subtract T_R from each in wrapping signed 32-bit arithmetic once per job. For block start (u,v0) use the existing affine start pipeline with T_R. For each accepted tile, add the three constant differences to that R coordinate. Advance the base by (b12,b22) only on transfer. The planner's lookahead may run ahead; it must apply the same offset and validity rules.

Worked example at (3,2), with quantised coefficients (52429,-39321,131071,39322,52429,65535). One Q15.16 unit is 1/65536 pixel. Each integer pair below selects the top-left neighbour in its own colour plane.

| Lane | Source X,Y in Q15.16 integers | Integer row,column | Fractions in units of 1/65536 |
|---|---|---|---|
| R | 144180, 255591 | 2, 3 | 13108, 58983 |
| Gr | 124520, 249038 | 1, 3 | 58984, 52430 |
| Gb | 137627, 275252 | 2, 4 | 6555, 13108 |
| B | 117966, 268699 | 1, 4 | 52430, 6555 |

Gr's X offset is floor((131071-39321)/2) - floor(131071/2) = -19660. Separately halving -39321 gives -19661. The test compares both tile (3,2) and the next step (3,3) with direct per-plane affine evaluation. For every lane check both signed coordinates against the inclusive plane bounds before reading. Invalid lanes contribute zero and still occupy their position. Clamp the second neighbour on the last row or column. Fetch each sample from mosaic (2*x + row parity, 2*y + column parity).

## 6.1.3 | From a block to a shared memory request

The planner scans up to BLOCK_LEN plane positions per block, with BLOCK_LEN in 1..64. Use memmodel.make_blocks for the logical boundaries: start of output row, change of the valid lanes' minimum/maximum top-row key, length, then aligned span. Retain the previous valid key across invalid positions; an all-invalid block performs zero reads. For a fetching block use the minimum top and maximum clamped bottom plane row of every valid lane. Expand that inclusive interval into even/odd physical row pairs. For the columns, round the first even mosaic column down and one past the last odd mosaic column up to an 8-byte boundary. Never index storage with a truncated endpoint: the exclusive end can equal 4096.

For a rectangle of at most 16 physical rows and a width of at most 512 bytes, emit one window per physical row in ascending order. A physical window is (row, first byte inclusive, end byte exclusive). HP0 reads start at SRC_ADDR + row*W + first. Split reads at 16 beats and at each 4 KiB boundary. P1 reuses a previous fetching group's row only when its range covers the whole new range. All-invalid groups leave the previous fetching group intact.

Three legal inputs demonstrate why a fixed six-row or one-window bound cannot be inferred from the transform validity check.

| Mosaic and inverse map | First output tile in the covering-rectangle model |
|---|---|
| 64 x 64, x=7u, y=v | 10 physical rows |
| 64 x 128, x=65u, y=v | 68 physical rows |
| 2048 x 2, x=u, y=1024u+v | 2 physical rows, 1032 bytes on each at the origin, even for BLOCK_LEN=1 |

For the last input, R/Gr need columns 0..3 on row 0 and Gb/B need columns 1024..1027 on row 1. The model takes the same range [0,1032) on both rows. The source fits in DDR; the shared column range exceeds the row slot. This input passes D3, D4 and the per-plane checks.

## 6.1.4 | Storage, read ports and ownership

Use 32 slots of 512 bytes, with word positions indexed by (absolute column >> 3) modulo 64. A window of at most 512 aligned bytes has at most 64 distinct word addresses, so two different words of the same assigned window cannot alias. Store the full loaded range with its slot tag. Also retain the immediately preceding group's requested range for the P1 comparison, even if its slot originally held more. In the executable model the equivalent slot stores the byte origin and payload.

Reserve up to 16 distinct slots for a group. Keep the previous group's tags pinned through allocation; at least 16 slots remain for new rows or segments. For the initial RTL, consume one group before reusing its slots. A group becomes readable when every required HP0 command has returned its last beat and the RAM writes have completed. Release read ownership only after the final tile's synchronous RAM data has been captured. Empty requests issue no AXI commands. This schedule trades block overlap for a simple lifetime proof.

Broadcast each fetched 64-bit word to four lane-local copies of the existing line-buffer organization. Within each copy, top and bottom row ports each have even/odd word banks. Two same-colour column neighbours are zero or two bytes apart, so each row needs one word or two adjacent words in opposite banks. The two row copies cover different slots even if their word addresses have the same parity. Select the bytes and pass the four neighbours, fractions and D1-valid flag to that lane's interpolator. DDR still reads a fetched byte once per issued window. Logical source storage is 16 KiB. Four lanes times two row copies is 128 KiB of replicated payload before FPGA block packing. Verify the actual BRAM count and timing in 6.3.

## 6.1.5 | Four lanes under a stall

Use the same input valid, output ready, reset and last indication on all four existing four-stage interpolators. D1-invalid uses ip_ok=0 on a valid transaction. Interpolator valid pipelines therefore advance together. A tile transfers only when its four results can be consumed as a group. Assert equal valid and last across lanes in simulation. Until the transfer, hold tile data and metadata stable.

| Example clock | Group at output | Merger ready | Action |
|---|---|---|---|
| n | tile 17 | 0 | Hold all four outputs and freeze the interpolation stages |
| n+1 | tile 17 | 0 | Continue holding; no row pointer or output-byte count advances |
| n+2 | tile 17 | 1 | Accept once, append R/Gr to the even row and Gb/B to the odd row |
| n+3 | tile 18 if valid | 1 | Accept the next group |

## 6.1.6 | RGGB merge and writeback

Reserve two row buffers of W bytes each (up to 8192 bytes total). At group column v, append R,Gr into even-row bytes 2v and 2v+1; append Gb,B into the same positions of the odd row. A 64-bit accumulator per row completes one word per four accepted groups, first byte in bits 7:0. W divisible by 16 guarantees complete words at row end. Once full, drain the even row and then the odd row to the 64-word output FIFO, obeying ready. Reuse the existing AXI writer in contiguous-row mode with full W,H and WSTRB=0xFF. Free the row-pair buffers once the last word transfers into the FIFO. The next group waits while they drain. No four-byte group is written as a contiguous 2x2 tile in DDR.

Row u's even word j goes to DST_ADDR + (2*u)*W + 8*j; the odd word is W bytes later. Each row is split independently at 16 beats or the 4 KiB boundary. BYTES_WR = 8 times accepted W beats = W*H per completed frame. The existing master reserves complete bursts using the FIFO count and retains response ownership until BRESP. FIFO capacity exceeds the maximum burst length, so waiting for a full burst cannot in itself deadlock the row drain.

## 6.1.7 | Integration contract for step 6.2

| Boundary | Transfer and ownership |
|---|---|
| Job control to B sequencer | MODE=2, one start and one plane-grid sweep per job. Use full W,H for DDR and W/2,H/2 for scanning and D1. Latch coefficients, eight T values, bases and block length at accepted start. Route modes 0 and 1 through their existing paths. For a combined build use VERSION=1, BUILD_TYPE=2, MODES=7 and BLOCK_LEN_MAX=64, giving BUILD_ID=0x00407201. Only advertise B when built and tested. |
| Planner to fetch | Valid/ready descriptor carries (u,v0,n,frame_last) and group windows. Row/column endpoints need 13 bits including 4096, n needs 7, slot ID needs 5, physical window count needs 5 including 16. Each issued read carries the slot and starting word for response placement. No combinational valid-from-ready path. |
| Fetch to lanes | One group-ready event covers all valid lanes; advance each tile only on handshake. Retain group metadata until its final RAM read is captured. An all-invalid tile can still produce four zero bytes. |
| Lanes to merger | Valid/ready with 4 x 8-bit data in R,Gr,Gb,B order and row/frame-end flags aligned to that tile. Coordinates and lane masks remain associated across stalls. |
| Merger to HP1 | Full 64-bit words in row order, counted FIFO and existing write master. DONE rises only after the final B response per the current master; BUSY spans fill, execution and drain. Propagate RRESP/BRESP errors through the existing job error handling. |
| Counters and reset | CYCLES counts the job; BYTES_RD and BYTES_WR count accepted bus beats times eight. WR_STALL counts a valid tile blocked at the merger once per cycle. RD_STALL counts a held tile waiting on source data when the interpolation pipeline can advance; exclude WR_STALL. Reset across the engine and AXI subsystem as in section 0. Clear outstanding state, valid bits, ownership tags, row pointers, FIFO, counts and interrupt. RAM data need no clearing. A subsequent job uses a fresh context. |

Resource budgeting: four D10 interpolators imply 28 multiplier instances in those lanes, plus the coordinate and address logic. The earlier approximate DSP budget is a planning estimate. Frequency target is 100 MHz. Throughput depends on fetches, stalls, row drains and actual timing; four simultaneous lane results per transfer do not establish a measured fourfold speedup.

## 6.1.8 | Verification and RTL handoff

Run `python -m model.test_bayer_b_design` from the repository root. The executable design steps the R coordinate, adds the registered lane offsets, issues physical read bursts into bounded slots, reads neighbours solely from loaded slots, and drains two rows into guarded destination storage. It uses the project's D10 arithmetic. The check independently compares every final byte with both the Option A job model and the golden Bayer warp. On the rectangular path it compares accepted read volume and burst count with the existing P1 memory model. The near-4-KiB base addresses in the bus stress cases are internal tests; normal board jobs use the documented base alignment.

For step 6.2, compare the Verilog against these model traces in the existing AXI memory testbench. Exercise address, data and response stalls independently, multiple outstanding reads, bottom/right clamps, invalid lanes mixed within a tile, group switches, 4 KiB splits, delayed final BRESP, bus errors, reset during fill/interpolation/write, and back-to-back gray/A/B jobs. Check every AR/AW address and length, strobes, accepted W data, byte counters, output guards and final interrupt. Inject a one-LSB offset error, swap the two greens, allow an early slot overwrite and raise DONE at final W; the corresponding tests must fail. Actual FPGA resource use, sustained speed and Rev D operation are later verification steps.

### Adopted fallback and performance review

For Option B, the 512-byte limit applies to each physical window. When the covering rectangle exceeds 16 physical rows or 512 bytes per row, process that logical block one tile at a time. Enumerate the four neighbours of each valid lane, align addresses to 8-byte words, deduplicate, and merge adjacent words on each row in ascending row/word order. At most 16 distinct words remain (four lanes times four neighbours), so every window fits a slot. Apply P1 to the previous nonempty physical group across both path transitions. Count a fallback tile each time it is serviced by this path. Hardware can sequence address enumeration over several cycles on the exceptional path. Use the design model as the physical read-count prediction; the historical rectangle model remains available for comparison.

Laptop verification passed for 42 frames and 327,712 output bytes against both references. The original 40 cases used zero fallback tiles and matched historical rectangular read beats and bursts. The two directed cases passed an independent count using direct plane coordinates.

| Case | Fallback tiles / total | HP0 read beats for frame | Read bursts |
|---|---:|---:|---:|
| 64 x 128 tall footprint | 32 / 2048 | 60 | 32 |
| 2048 x 2 wide footprint | 512 / 1024 | 782 | 288 |

**Decision to revisit after measurement.** In 6.2 compare two otherwise identical RTL configurations with and without the fallback on frames both can run. Use the same reference mosaic, transform, block length, bus latency and stall seed. Record fallback tiles / total, cycles per frame, read bytes/bursts, read/write stall cycles, and relative change in cycles. Include identity, rotations and representative course workloads. For oversized frames record the fallback's standalone cost; the old bounded path cannot complete those inputs. In 6.3 compare post-route 100 MHz timing and resources; repeat frame times on Rev D when available. If the team finds the slowdown material, revisit the earlier rectangular path for ordinary jobs and route unsupported jobs to a verified alternative such as Option A before disabling the fallback. Step 6.2 measured zero additional simulated cycles across 20 paired ordinary B jobs. Keep the fallback and revisit after post-route and board measurements. See [the RTL results](../spec/interface.md#19-bayer-option-b-rtl-step-62).
