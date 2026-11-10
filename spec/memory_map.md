# Memory map, interrupt and job sequence (step 2.1)

Registers: `spec/regs.json` (single source of truth) -> `sw/include/patrm_regs.h`, `rtl/patrm_regs.vh`,
`model/regs.py` via `python scripts/gen_regs.py`. Register image for a job: `python -m model.job ...`.
Sizes are written W x H (D7).

## 1. DDR (ZedBoard: 512 MB DDR3, PS address 0x0000_0000 - 0x1FFF_FFFF)

| region | start | end (incl.) | size | written by | read by |
|---|---|---|---|---|---|
| ARM program (ELF, stack, heap) | 0x0010_0000 | below 0x0F00_0000 | Vitis linker script | XSDB (ELF load) | ARM |
| source image | 0x1000_0000 | 0x10FF_FFFF | 16 MB | host over JTAG (XSDB) | engine (HP0) |
| output image | 0x1800_0000 | 0x18FF_FFFF | 16 MB | engine (HP1) | host over JTAG (XSDB) |
| job descriptor (host -> ARM) | 0x1F00_0000 | 0x1F00_0FFF | 4 KB | host over JTAG | ARM |
| job result (ARM -> host) | 0x1F00_1000 | 0x1F00_1FFF | 4 KB | ARM | host over JTAG |

- 16 MB = largest image, 4096 x 4096 x 1 byte (D11). An image occupies W x H bytes, row-major, no header
  (GRAY8, or the raw RGGB mosaic in Bayer modes). The output has the same size and layout as the source.
- The descriptor and result layouts are defined in step 4.2 (driver). The addresses above are fixed now.
- Step 0.3 (JTAG round trip) uses the same source and output addresses.

### Alignment and placement rules
- SRC_ADDR and DST_ADDR are multiples of 4096 (4 KB). The engine rejects other values (STATUS.ERR_CODE = BAD_ADDR).
  With 4 KB-aligned bases the AXI masters split bursts at 4 KB boundaries of the image only (AXI3: at most 16 beats
  of 8 bytes, never across a 4 KB boundary).
- Source and output buffers must not overlap (the engine does not support in-place warps), must lie inside DDR,
  and must not overlap the program or the job areas. `model/job.py` checks this; the driver will do the same.
  The engine itself checks only the alignment.
- The ARM caches are not snooped by the HP ports, so the driver does explicit cache maintenance (section 4).

## 2. Engine registers (AXI-Lite slave on M_AXI_GP0)

- Base address: **0x43C0_0000 (placeholder)**. The final value is assigned by the block design in step 4.1 and
  then written here and in the driver's `xparameters.h` usage. Address window 64 KB; registers use 0x00 - 0x6B
  (7 address bits), everything else in the window reads 0.
- Map: `python scripts/gen_regs.py --table`. Registers 0x00 - 0x50 are configuration, 0x54 - 0x64 counters,
  0x68 BUILD_ID.
- Configuration registers are ignored while STATUS.BUSY = 1 (except CTRL.IRQ_EN), so a job's settings cannot change
  in the middle of a frame.
- On CTRL.START = 1 the engine checks MODE, size, addresses and BLOCK_LEN in the same cycle. **RTL requirement:**
  STATUS already shows the outcome (BUSY = 1, or ERROR = 1 with ERR_CODE) when the AXI-Lite write response for that
  CTRL write is returned, so a STATUS read that follows always sees it.
- The engine does not check the transform (D4) or the plane shifts (D12); software does.

## 3. Interrupt

- Engine output `interrupt` -> Zynq `IRQ_F2P[0]` = GIC shared peripheral interrupt ID 61.
- **Level-sensitive, active high**: `interrupt = CTRL.IRQ_EN & STATUS.DONE`. Configure the GIC for this ID as
  active-high level (`XScuGic_SetPriorityTriggerType(..., 61, priority, 0x1)`).
- Cleared by writing 1 to STATUS.DONE (W1C). The handler must do this before returning, otherwise the level
  interrupt fires again.
- A rejected start (STATUS.ERROR) does not raise the interrupt; the driver sees it by reading STATUS right after
  the start (section 4, step 8).
- Polling fallback: with CTRL.IRQ_EN = 0 the driver polls STATUS.DONE.

## 4. Start / done sequence (ARM driver, bare metal)

Once, at power-up:
1. Read BUILD_ID. Check VERSION = PATRM_VERSION (else stop: bitstream and driver do not match). Keep BUILD_TYPE,
   MODES and BLOCK_LEN_MAX for the job checks.
2. Set up the GIC: connect the handler to ID 61, active-high level trigger, enable the ID and ARM interrupts.

For every job:
1. Check the job in software, exactly like `model/job.py`: size rules D3 and D11 for the mode, transform D4
   (four corners within +/-16384 px; in Bayer modes also for every plane), mode bit set in BUILD_ID.MODES,
   1 <= BLOCK_LEN <= BLOCK_LEN_MAX, buffer placement (section 1). Stop with a clear message on failure.
2. Read STATUS; BUSY must be 0.
3. `Xil_DCacheFlushRange(SRC, W*H)`: write any cached source bytes to DDR (the engine reads DDR directly).
4. `Xil_DCacheFlushRange(DST, W*H)`: clean and invalidate the output range, so that no dirty cache line can later
   be evicted on top of the engine's output. (Flush, not invalidate: W*H need not be a multiple of the
   32-byte cache line.)
5. Write STATUS = DONE | ERROR (W1C) to clear anything left from an earlier job.
6. Write SRC_ADDR, DST_ADDR, WIDTH, HEIGHT, B11 .. B23, T_R_X .. T_B_Y, BLOCK_LEN.
   - b: the quantised Q15.16 integers (D5) received from the host; the ARM does no floating-point transform maths.
   - Bayer modes: T_p from the D2 integer formula (same as `model/bayer.py` `plane_shifts`), computed by the ARM (D12).
   - Gray mode: T_* = 0 (ignored by the engine).
7. Write CTRL = (MODE << 1) | (IRQ_EN << 3) | START. This is the last configuration write. (GP0 is mapped as
   device memory, so the earlier register writes reach the engine first.)
8. Read STATUS. If ERROR = 1: report ERR_CODE, write STATUS = ERROR (W1C), stop.
9. Wait for DONE:
   - interrupt: the handler reads STATUS, writes STATUS = DONE (W1C, drops the line) and sets a flag the main loop
     waits on;
   - polling: read STATUS until DONE = 1, then write STATUS = DONE.
   Use a timeout in both cases (proposal: 2 s; estimate, the slowest expected frame at 4096 x 4096 is well below
   this) and report a timeout with the STATUS value and the counters.
10. `Xil_DCacheInvalidateRange(DST, W*H)`: drop stale cached copies of the output before the ARM reads it.
    DONE is set only after the last write response (BRESP) of the job, so all output data is in DDR.
11. Read CYCLES, BYTES_RD, BYTES_WR, RD_STALL, WR_STALL (they hold their values until the next accepted start).
12. Write the result record (status, counters) to the job result area for the host.
