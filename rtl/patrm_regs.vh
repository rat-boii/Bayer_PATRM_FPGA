// generated from spec/regs.json, do not edit
// PATRM engine register map (AXI-Lite slave on M_AXI_GP0), version 1
// Verilog-2001 localparams. `include this file INSIDE a module body (no include guard on purpose).

localparam integer PATRM_ADDR_BITS = 7;
localparam integer PATRM_VERSION = 1;   // register map version, reported in BUILD_ID.VERSION
localparam integer PATRM_MAX_SIZE = 4096;   // D11: largest WIDTH and largest HEIGHT (pixels)
localparam integer PATRM_SIZE_BITS = 13;   // D11: width of the WIDTH / HEIGHT / BLOCK_LEN fields
localparam integer PATRM_GRAY_W_MULT = 8;   // D3: grayscale WIDTH must be a multiple of this
localparam integer PATRM_BAYER_W_MULT = 16;   // D3: Bayer WIDTH must be a multiple of this
localparam integer PATRM_BAYER_H_MULT = 2;   // D3: Bayer HEIGHT must be a multiple of this
localparam integer PATRM_ADDR_ALIGN = 4096;   // SRC_ADDR and DST_ADDR must be multiples of this (4 KB)
localparam integer PATRM_FRAC_BITS = 16;   // Q15.16 fraction bits

// MODE: CTRL.MODE values
localparam [1:0] PATRM_MODE_GRAY = 2'd0;   // grayscale, one plane of WIDTH x HEIGHT, uses B11..B23
localparam [1:0] PATRM_MODE_BAYER_A = 2'd1;   // Bayer RGGB, Option A: one core, four plane passes; uses B11, B12, B21, B22 and T_*
localparam [1:0] PATRM_MODE_BAYER_B = 2'd2;   // Bayer RGGB, Option B: four lanes, one pass; uses B11, B12, B21, B22 and T_* (lane offsets T_p - T_R, D6)

// BUILD_TYPE: BUILD_ID.BUILD_TYPE values
localparam [1:0] PATRM_BUILD_TYPE_GRAY = 2'd0;   // grayscale build
localparam [1:0] PATRM_BUILD_TYPE_BAYER_A = 2'd1;   // Option A build
localparam [1:0] PATRM_BUILD_TYPE_BAYER_B = 2'd2;   // Option B build

// ERR: STATUS.ERR_CODE values. If several checks fail, the code reported is the first in this order: START_BUSY, BAD_MODE, BAD_SIZE, BAD_ADDR, BAD_BLOCK_LEN.
localparam [3:0] PATRM_ERR_NONE = 4'd0;   // no error
localparam [3:0] PATRM_ERR_BAD_SIZE = 4'd1;   // WIDTH or HEIGHT is 0 or above MAX_SIZE (D11), or breaks D3 for the selected mode (gray: WIDTH % 8 != 0; Bayer: WIDTH % 16 != 0 or HEIGHT odd)
localparam [3:0] PATRM_ERR_BAD_MODE = 4'd2;   // CTRL.MODE = 3, or a mode whose bit is 0 in BUILD_ID.MODES
localparam [3:0] PATRM_ERR_BAD_ADDR = 4'd3;   // SRC_ADDR or DST_ADDR is not 4 KB aligned (bits 11:0 not zero)
localparam [3:0] PATRM_ERR_BAD_BLOCK_LEN = 4'd4;   // BLOCK_LEN is 0 or above BUILD_ID.BLOCK_LEN_MAX (D13)
localparam [3:0] PATRM_ERR_START_BUSY = 4'd5;   // CTRL.START written while STATUS.BUSY = 1; the running job continues unaffected

// 0x00 CTRL (RW): Control. Write MODE and IRQ_EN together with START = 1 as the last write of a job.
localparam [6:0] PATRM_REG_CTRL = 7'h00;
localparam [31:0] PATRM_CTRL_RESET = 32'h00000000;
localparam integer PATRM_CTRL_START_LSB = 0;
localparam integer PATRM_CTRL_START_W = 1;   // WP: write 1 to check the configuration and start a job; reads 0
localparam integer PATRM_CTRL_MODE_LSB = 1;
localparam integer PATRM_CTRL_MODE_W = 2;   // RW: 0 = gray, 1 = Bayer Option A, 2 = Bayer Option B, 3 = invalid
localparam integer PATRM_CTRL_IRQ_EN_LSB = 3;
localparam integer PATRM_CTRL_IRQ_EN_W = 1;   // RW: 1 = drive the interrupt output (IRQ_F2P[0]) high while STATUS.DONE = 1

// 0x04 STATUS (RO/W1C): Status. The interrupt output is CTRL.IRQ_EN & DONE (level).
localparam [6:0] PATRM_REG_STATUS = 7'h04;
localparam [31:0] PATRM_STATUS_RESET = 32'h00000000;
localparam integer PATRM_STATUS_BUSY_LSB = 0;
localparam integer PATRM_STATUS_BUSY_W = 1;   // RO: 1 from an accepted start until the last write response of the job has been received
localparam integer PATRM_STATUS_DONE_LSB = 1;
localparam integer PATRM_STATUS_DONE_W = 1;   // W1C: set when a job ends (same cycle BUSY falls, all output data accepted by DDR); write 1 to clear (also clears the interrupt)
localparam integer PATRM_STATUS_ERROR_LSB = 2;
localparam integer PATRM_STATUS_ERROR_W = 1;   // W1C: set when a start is rejected; write 1 to clear (also clears ERR_CODE)
localparam integer PATRM_STATUS_ERR_CODE_LSB = 4;
localparam integer PATRM_STATUS_ERR_CODE_W = 4;   // RO: reason for the last rejected start, see ERR enum; 0 when ERROR = 0

// 0x08 SRC_ADDR (RW): DDR byte address of the source image (raw GRAY8 or raw RGGB mosaic, row-major, no header). Must be 4 KB aligned.
localparam [6:0] PATRM_REG_SRC_ADDR = 7'h08;
localparam [31:0] PATRM_SRC_ADDR_RESET = 32'h00000000;
localparam integer PATRM_SRC_ADDR_ADDR_LSB = 0;
localparam integer PATRM_SRC_ADDR_ADDR_W = 32;   // RW: byte address; bits 11:0 must be 0

// 0x0C DST_ADDR (RW): DDR byte address of the output image (same format and size as the source). Must be 4 KB aligned.
localparam [6:0] PATRM_REG_DST_ADDR = 7'h0C;
localparam [31:0] PATRM_DST_ADDR_RESET = 32'h00000000;
localparam integer PATRM_DST_ADDR_ADDR_LSB = 0;
localparam integer PATRM_DST_ADDR_ADDR_W = 32;   // RW: byte address; bits 11:0 must be 0

// 0x10 WIDTH (RW): Image width W in pixels (full mosaic width in Bayer modes). D3, D11.
localparam [6:0] PATRM_REG_WIDTH = 7'h10;
localparam [31:0] PATRM_WIDTH_RESET = 32'h00000000;
localparam integer PATRM_WIDTH_W_LSB = 0;
localparam integer PATRM_WIDTH_W_W = 13;   // RW: 1..4096; gray: multiple of 8; Bayer: multiple of 16

// 0x14 HEIGHT (RW): Image height H in pixels (full mosaic height in Bayer modes). D3, D11.
localparam [6:0] PATRM_REG_HEIGHT = 7'h14;
localparam [31:0] PATRM_HEIGHT_RESET = 32'h00000000;
localparam integer PATRM_HEIGHT_H_LSB = 0;
localparam integer PATRM_HEIGHT_H_W = 13;   // RW: 1..4096; Bayer: even

// 0x18 B11 (RW): Inverse map coefficient b11 (x per output row u). Reset = 1.0 (identity).
localparam [6:0] PATRM_REG_B11 = 7'h18;
localparam [31:0] PATRM_B11_RESET = 32'h00010000;
localparam integer PATRM_B11_VALUE_LSB = 0;
localparam integer PATRM_B11_VALUE_W = 32;   // RW: signed Q15.16

// 0x1C B12 (RW): Inverse map coefficient b12 (x per output column v).
localparam [6:0] PATRM_REG_B12 = 7'h1C;
localparam [31:0] PATRM_B12_RESET = 32'h00000000;
localparam integer PATRM_B12_VALUE_LSB = 0;
localparam integer PATRM_B12_VALUE_W = 32;   // RW: signed Q15.16

// 0x20 B13 (RW): Inverse map offset b13 (x at u = v = 0). Used in GRAY mode only; Bayer modes use T_*_X.
localparam [6:0] PATRM_REG_B13 = 7'h20;
localparam [31:0] PATRM_B13_RESET = 32'h00000000;
localparam integer PATRM_B13_VALUE_LSB = 0;
localparam integer PATRM_B13_VALUE_W = 32;   // RW: signed Q15.16

// 0x24 B21 (RW): Inverse map coefficient b21 (y per output row u).
localparam [6:0] PATRM_REG_B21 = 7'h24;
localparam [31:0] PATRM_B21_RESET = 32'h00000000;
localparam integer PATRM_B21_VALUE_LSB = 0;
localparam integer PATRM_B21_VALUE_W = 32;   // RW: signed Q15.16

// 0x28 B22 (RW): Inverse map coefficient b22 (y per output column v). Reset = 1.0 (identity).
localparam [6:0] PATRM_REG_B22 = 7'h28;
localparam [31:0] PATRM_B22_RESET = 32'h00010000;
localparam integer PATRM_B22_VALUE_LSB = 0;
localparam integer PATRM_B22_VALUE_W = 32;   // RW: signed Q15.16

// 0x2C B23 (RW): Inverse map offset b23 (y at u = v = 0). Used in GRAY mode only; Bayer modes use T_*_Y.
localparam [6:0] PATRM_REG_B23 = 7'h2C;
localparam [31:0] PATRM_B23_RESET = 32'h00000000;
localparam integer PATRM_B23_VALUE_LSB = 0;
localparam integer PATRM_B23_VALUE_W = 32;   // RW: signed Q15.16

// 0x30 T_R_X (RW): Bayer plane shift T_R, x part (D2, D12: computed by the ARM, never by the hardware). Ignored in GRAY mode.
localparam [6:0] PATRM_REG_T_R_X = 7'h30;
localparam [31:0] PATRM_T_R_X_RESET = 32'h00000000;
localparam integer PATRM_T_R_X_VALUE_LSB = 0;
localparam integer PATRM_T_R_X_VALUE_W = 32;   // RW: signed Q15.16, plane coordinates

// 0x34 T_R_Y (RW): Bayer plane shift T_R, y part (D2, D12). Ignored in GRAY mode.
localparam [6:0] PATRM_REG_T_R_Y = 7'h34;
localparam [31:0] PATRM_T_R_Y_RESET = 32'h00000000;
localparam integer PATRM_T_R_Y_VALUE_LSB = 0;
localparam integer PATRM_T_R_Y_VALUE_W = 32;   // RW: signed Q15.16, plane coordinates

// 0x38 T_GR_X (RW): Bayer plane shift T_Gr, x part (D2, D12). Ignored in GRAY mode.
localparam [6:0] PATRM_REG_T_GR_X = 7'h38;
localparam [31:0] PATRM_T_GR_X_RESET = 32'h00000000;
localparam integer PATRM_T_GR_X_VALUE_LSB = 0;
localparam integer PATRM_T_GR_X_VALUE_W = 32;   // RW: signed Q15.16, plane coordinates

// 0x3C T_GR_Y (RW): Bayer plane shift T_Gr, y part (D2, D12). Ignored in GRAY mode.
localparam [6:0] PATRM_REG_T_GR_Y = 7'h3C;
localparam [31:0] PATRM_T_GR_Y_RESET = 32'h00000000;
localparam integer PATRM_T_GR_Y_VALUE_LSB = 0;
localparam integer PATRM_T_GR_Y_VALUE_W = 32;   // RW: signed Q15.16, plane coordinates

// 0x40 T_GB_X (RW): Bayer plane shift T_Gb, x part (D2, D12). Ignored in GRAY mode.
localparam [6:0] PATRM_REG_T_GB_X = 7'h40;
localparam [31:0] PATRM_T_GB_X_RESET = 32'h00000000;
localparam integer PATRM_T_GB_X_VALUE_LSB = 0;
localparam integer PATRM_T_GB_X_VALUE_W = 32;   // RW: signed Q15.16, plane coordinates

// 0x44 T_GB_Y (RW): Bayer plane shift T_Gb, y part (D2, D12). Ignored in GRAY mode.
localparam [6:0] PATRM_REG_T_GB_Y = 7'h44;
localparam [31:0] PATRM_T_GB_Y_RESET = 32'h00000000;
localparam integer PATRM_T_GB_Y_VALUE_LSB = 0;
localparam integer PATRM_T_GB_Y_VALUE_W = 32;   // RW: signed Q15.16, plane coordinates

// 0x48 T_B_X (RW): Bayer plane shift T_B, x part (D2, D12). Ignored in GRAY mode.
localparam [6:0] PATRM_REG_T_B_X = 7'h48;
localparam [31:0] PATRM_T_B_X_RESET = 32'h00000000;
localparam integer PATRM_T_B_X_VALUE_LSB = 0;
localparam integer PATRM_T_B_X_VALUE_W = 32;   // RW: signed Q15.16, plane coordinates

// 0x4C T_B_Y (RW): Bayer plane shift T_B, y part (D2, D12). Ignored in GRAY mode.
localparam [6:0] PATRM_REG_T_B_Y = 7'h4C;
localparam [31:0] PATRM_T_B_Y_RESET = 32'h00000000;
localparam integer PATRM_T_B_Y_VALUE_LSB = 0;
localparam integer PATRM_T_B_Y_VALUE_W = 32;   // RW: signed Q15.16, plane coordinates

// 0x50 BLOCK_LEN (RW): Block length L (D13): output pixels per block, capped at the end of a row. Changes memory traffic only, never the output. Reset 0 is rejected, so the driver must write it.
localparam [6:0] PATRM_REG_BLOCK_LEN = 7'h50;
localparam [31:0] PATRM_BLOCK_LEN_RESET = 32'h00000000;
localparam integer PATRM_BLOCK_LEN_L_LSB = 0;
localparam integer PATRM_BLOCK_LEN_L_W = 13;   // RW: 1..BUILD_ID.BLOCK_LEN_MAX

// 0x54 CYCLES (RO): Clock cycles from the accepted start to DONE (100 MHz, D8). Cleared at an accepted start, holds its value after DONE.
localparam [6:0] PATRM_REG_CYCLES = 7'h54;
localparam [31:0] PATRM_CYCLES_RESET = 32'h00000000;
localparam integer PATRM_CYCLES_COUNT_LSB = 0;
localparam integer PATRM_CYCLES_COUNT_W = 32;   // RO: cycles

// 0x58 BYTES_RD (RO): Bytes read on HP0 in this job = 8 x accepted read beats (comparable to the step 1.4 memory model). Cleared at an accepted start.
localparam [6:0] PATRM_REG_BYTES_RD = 7'h58;
localparam [31:0] PATRM_BYTES_RD_RESET = 32'h00000000;
localparam integer PATRM_BYTES_RD_COUNT_LSB = 0;
localparam integer PATRM_BYTES_RD_COUNT_W = 32;   // RO: bytes

// 0x5C BYTES_WR (RO): Bytes written on HP1 in this job = 8 x accepted write beats, including beats with partial WSTRB (memmodel write_bus_bytes). Cleared at an accepted start.
localparam [6:0] PATRM_REG_BYTES_WR = 7'h5C;
localparam [31:0] PATRM_BYTES_WR_RESET = 32'h00000000;
localparam integer PATRM_BYTES_WR_COUNT_LSB = 0;
localparam integer PATRM_BYTES_WR_COUNT_W = 32;   // RO: bytes

// 0x60 RD_STALL (RO): Cycles in this job in which the pixel pipeline waited for source data that was not yet in the prefetch buffer. Exact definition in spec/interface.md (step 2.2). Cleared at an accepted start.
localparam [6:0] PATRM_REG_RD_STALL = 7'h60;
localparam [31:0] PATRM_RD_STALL_RESET = 32'h00000000;
localparam integer PATRM_RD_STALL_COUNT_LSB = 0;
localparam integer PATRM_RD_STALL_COUNT_W = 32;   // RO: cycles

// 0x64 WR_STALL (RO): Cycles in this job in which the pixel pipeline waited because the output FIFO was full. Exact definition in spec/interface.md (step 2.2). Cleared at an accepted start.
localparam [6:0] PATRM_REG_WR_STALL = 7'h64;
localparam [31:0] PATRM_WR_STALL_RESET = 32'h00000000;
localparam integer PATRM_WR_STALL_COUNT_LSB = 0;
localparam integer PATRM_WR_STALL_COUNT_W = 32;   // RO: cycles

// 0x68 BUILD_ID (RO): Build identification, constant per bitstream (set from synthesis parameters). The driver reads it before the first job.
localparam [6:0] PATRM_REG_BUILD_ID = 7'h68;
localparam integer PATRM_BUILD_ID_VERSION_LSB = 0;
localparam integer PATRM_BUILD_ID_VERSION_W = 8;   // RO: register map version (constant VERSION)
localparam integer PATRM_BUILD_ID_BUILD_TYPE_LSB = 8;
localparam integer PATRM_BUILD_ID_BUILD_TYPE_W = 2;   // RO: 0 = gray, 1 = Option A, 2 = Option B
localparam integer PATRM_BUILD_ID_MODES_LSB = 12;
localparam integer PATRM_BUILD_ID_MODES_W = 3;   // RO: supported CTRL.MODE values, bit n = mode n supported
localparam integer PATRM_BUILD_ID_BLOCK_LEN_MAX_LSB = 16;
localparam integer PATRM_BUILD_ID_BLOCK_LEN_MAX_W = 13;   // RO: largest accepted BLOCK_LEN (D13, synthesis parameter chosen in step 2.2)
