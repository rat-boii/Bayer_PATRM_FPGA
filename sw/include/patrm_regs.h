/* generated from spec/regs.json, do not edit */
/* PATRM engine register map (AXI-Lite slave on M_AXI_GP0), version 1 */

#ifndef PATRM_REGS_H
#define PATRM_REGS_H

/* Constants */
#define PATRM_VERSION                      1U   /* register map version, reported in BUILD_ID.VERSION */
#define PATRM_MAX_SIZE                     4096U   /* D11: largest WIDTH and largest HEIGHT (pixels) */
#define PATRM_SIZE_BITS                    13U   /* D11: width of the WIDTH / HEIGHT / BLOCK_LEN fields */
#define PATRM_GRAY_W_MULT                  8U   /* D3: grayscale WIDTH must be a multiple of this */
#define PATRM_BAYER_W_MULT                 16U   /* D3: Bayer WIDTH must be a multiple of this */
#define PATRM_BAYER_H_MULT                 2U   /* D3: Bayer HEIGHT must be a multiple of this */
#define PATRM_ADDR_ALIGN                   4096U   /* SRC_ADDR and DST_ADDR must be multiples of this (4 KB) */
#define PATRM_FRAC_BITS                    16U   /* Q15.16 fraction bits */

/* MODE: CTRL.MODE values */
#define PATRM_MODE_GRAY                     0U   /* grayscale, one plane of WIDTH x HEIGHT, uses B11..B23 */
#define PATRM_MODE_BAYER_A                  1U   /* Bayer RGGB, Option A: one core, four plane passes; uses B11, B12, B21, B22 and T_* */
#define PATRM_MODE_BAYER_B                  2U   /* Bayer RGGB, Option B: four lanes, one pass; uses B11, B12, B21, B22 and T_* (lane offsets T_p - T_R, D6) */

/* BUILD_TYPE: BUILD_ID.BUILD_TYPE values */
#define PATRM_BUILD_TYPE_GRAY                     0U   /* grayscale build */
#define PATRM_BUILD_TYPE_BAYER_A                  1U   /* Option A build */
#define PATRM_BUILD_TYPE_BAYER_B                  2U   /* Option B build */

/* ERR: STATUS.ERR_CODE values. If several start checks fail, the code reported is the first in this order: START_BUSY, BAD_MODE, BAD_SIZE, BAD_ADDR, BAD_BLOCK_LEN. BUS_ERROR is not a start check: it is set at the end of a job and replaces an earlier code. */
#define PATRM_ERR_NONE                     0U   /* no error */
#define PATRM_ERR_BAD_SIZE                 1U   /* WIDTH or HEIGHT is 0 or above MAX_SIZE (D11), or breaks D3 for the selected mode (gray: WIDTH % 8 != 0; Bayer: WIDTH % 16 != 0 or HEIGHT odd) */
#define PATRM_ERR_BAD_MODE                 2U   /* CTRL.MODE = 3, or a mode whose bit is 0 in BUILD_ID.MODES */
#define PATRM_ERR_BAD_ADDR                 3U   /* SRC_ADDR or DST_ADDR is not 4 KB aligned (bits 11:0 not zero) */
#define PATRM_ERR_BAD_BLOCK_LEN            4U   /* BLOCK_LEN is 0 or above BUILD_ID.BLOCK_LEN_MAX (D13) */
#define PATRM_ERR_START_BUSY               5U   /* CTRL.START written while STATUS.BUSY = 1; the running job continues unaffected */
#define PATRM_ERR_BUS_ERROR                6U   /* the job ended, but at least one AXI read (RRESP) or write (BRESP) response was not OKAY; DONE and the interrupt are as normal, the output must not be trusted */

/* 0x00 CTRL (RW): Control. Write MODE and IRQ_EN together with START = 1 as the last write of a job. */
#define PATRM_CTRL_OFFSET                   0x00U
#define PATRM_CTRL_RESET                    0x00000000U
#define PATRM_CTRL_START_SHIFT             0U
#define PATRM_CTRL_START_WIDTH             1U
#define PATRM_CTRL_START_MASK              0x00000001U   /* WP: write 1 to check the configuration and start a job; reads 0 */
#define PATRM_CTRL_MODE_SHIFT              1U
#define PATRM_CTRL_MODE_WIDTH              2U
#define PATRM_CTRL_MODE_MASK               0x00000006U   /* RW: 0 = gray, 1 = Bayer Option A, 2 = Bayer Option B, 3 = invalid */
#define PATRM_CTRL_IRQ_EN_SHIFT            3U
#define PATRM_CTRL_IRQ_EN_WIDTH            1U
#define PATRM_CTRL_IRQ_EN_MASK             0x00000008U   /* RW: 1 = drive the interrupt output (IRQ_F2P[0]) high while STATUS.DONE = 1 */

/* 0x04 STATUS (RO/W1C): Status. The interrupt output is CTRL.IRQ_EN & DONE (level). */
#define PATRM_STATUS_OFFSET                 0x04U
#define PATRM_STATUS_RESET                  0x00000000U
#define PATRM_STATUS_BUSY_SHIFT            0U
#define PATRM_STATUS_BUSY_WIDTH            1U
#define PATRM_STATUS_BUSY_MASK             0x00000001U   /* RO: 1 from an accepted start until the last write response of the job has been received */
#define PATRM_STATUS_DONE_SHIFT            1U
#define PATRM_STATUS_DONE_WIDTH            1U
#define PATRM_STATUS_DONE_MASK             0x00000002U   /* W1C: set when a job ends (same cycle BUSY falls, all output data accepted by DDR); write 1 to clear (also clears the interrupt) */
#define PATRM_STATUS_ERROR_SHIFT           2U
#define PATRM_STATUS_ERROR_WIDTH           1U
#define PATRM_STATUS_ERROR_MASK            0x00000004U   /* W1C: set when a start is rejected, or at the end of a job with an AXI error response (BUS_ERROR); write 1 to clear (also clears ERR_CODE) */
#define PATRM_STATUS_ERR_CODE_SHIFT        4U
#define PATRM_STATUS_ERR_CODE_WIDTH        4U
#define PATRM_STATUS_ERR_CODE_MASK         0x000000F0U   /* RO: reason for the last error, see ERR enum; 0 when ERROR = 0 */

/* 0x08 SRC_ADDR (RW): DDR byte address of the source image (raw GRAY8 or raw RGGB mosaic, row-major, no header). Must be 4 KB aligned. */
#define PATRM_SRC_ADDR_OFFSET               0x08U
#define PATRM_SRC_ADDR_RESET                0x00000000U
#define PATRM_SRC_ADDR_ADDR_SHIFT          0U
#define PATRM_SRC_ADDR_ADDR_WIDTH          32U
#define PATRM_SRC_ADDR_ADDR_MASK           0xFFFFFFFFU   /* RW: byte address; bits 11:0 must be 0 */

/* 0x0C DST_ADDR (RW): DDR byte address of the output image (same format and size as the source). Must be 4 KB aligned. */
#define PATRM_DST_ADDR_OFFSET               0x0CU
#define PATRM_DST_ADDR_RESET                0x00000000U
#define PATRM_DST_ADDR_ADDR_SHIFT          0U
#define PATRM_DST_ADDR_ADDR_WIDTH          32U
#define PATRM_DST_ADDR_ADDR_MASK           0xFFFFFFFFU   /* RW: byte address; bits 11:0 must be 0 */

/* 0x10 WIDTH (RW): Image width W in pixels (full mosaic width in Bayer modes). D3, D11. */
#define PATRM_WIDTH_OFFSET                  0x10U
#define PATRM_WIDTH_RESET                   0x00000000U
#define PATRM_WIDTH_W_SHIFT                0U
#define PATRM_WIDTH_W_WIDTH                13U
#define PATRM_WIDTH_W_MASK                 0x00001FFFU   /* RW: 1..4096; gray: multiple of 8; Bayer: multiple of 16 */

/* 0x14 HEIGHT (RW): Image height H in pixels (full mosaic height in Bayer modes). D3, D11. */
#define PATRM_HEIGHT_OFFSET                 0x14U
#define PATRM_HEIGHT_RESET                  0x00000000U
#define PATRM_HEIGHT_H_SHIFT               0U
#define PATRM_HEIGHT_H_WIDTH               13U
#define PATRM_HEIGHT_H_MASK                0x00001FFFU   /* RW: 1..4096; Bayer: even */

/* 0x18 B11 (RW): Inverse map coefficient b11 (x per output row u). Reset = 1.0 (identity). */
#define PATRM_B11_OFFSET                    0x18U
#define PATRM_B11_RESET                     0x00010000U
#define PATRM_B11_VALUE_SHIFT              0U
#define PATRM_B11_VALUE_WIDTH              32U
#define PATRM_B11_VALUE_MASK               0xFFFFFFFFU   /* RW: signed Q15.16 */

/* 0x1C B12 (RW): Inverse map coefficient b12 (x per output column v). */
#define PATRM_B12_OFFSET                    0x1CU
#define PATRM_B12_RESET                     0x00000000U
#define PATRM_B12_VALUE_SHIFT              0U
#define PATRM_B12_VALUE_WIDTH              32U
#define PATRM_B12_VALUE_MASK               0xFFFFFFFFU   /* RW: signed Q15.16 */

/* 0x20 B13 (RW): Inverse map offset b13 (x at u = v = 0). Used in GRAY mode only; Bayer modes use T_*_X. */
#define PATRM_B13_OFFSET                    0x20U
#define PATRM_B13_RESET                     0x00000000U
#define PATRM_B13_VALUE_SHIFT              0U
#define PATRM_B13_VALUE_WIDTH              32U
#define PATRM_B13_VALUE_MASK               0xFFFFFFFFU   /* RW: signed Q15.16 */

/* 0x24 B21 (RW): Inverse map coefficient b21 (y per output row u). */
#define PATRM_B21_OFFSET                    0x24U
#define PATRM_B21_RESET                     0x00000000U
#define PATRM_B21_VALUE_SHIFT              0U
#define PATRM_B21_VALUE_WIDTH              32U
#define PATRM_B21_VALUE_MASK               0xFFFFFFFFU   /* RW: signed Q15.16 */

/* 0x28 B22 (RW): Inverse map coefficient b22 (y per output column v). Reset = 1.0 (identity). */
#define PATRM_B22_OFFSET                    0x28U
#define PATRM_B22_RESET                     0x00010000U
#define PATRM_B22_VALUE_SHIFT              0U
#define PATRM_B22_VALUE_WIDTH              32U
#define PATRM_B22_VALUE_MASK               0xFFFFFFFFU   /* RW: signed Q15.16 */

/* 0x2C B23 (RW): Inverse map offset b23 (y at u = v = 0). Used in GRAY mode only; Bayer modes use T_*_Y. */
#define PATRM_B23_OFFSET                    0x2CU
#define PATRM_B23_RESET                     0x00000000U
#define PATRM_B23_VALUE_SHIFT              0U
#define PATRM_B23_VALUE_WIDTH              32U
#define PATRM_B23_VALUE_MASK               0xFFFFFFFFU   /* RW: signed Q15.16 */

/* 0x30 T_R_X (RW): Bayer plane shift T_R, x part (D2, D12: computed by the ARM, never by the hardware). Ignored in GRAY mode. */
#define PATRM_T_R_X_OFFSET                  0x30U
#define PATRM_T_R_X_RESET                   0x00000000U
#define PATRM_T_R_X_VALUE_SHIFT            0U
#define PATRM_T_R_X_VALUE_WIDTH            32U
#define PATRM_T_R_X_VALUE_MASK             0xFFFFFFFFU   /* RW: signed Q15.16, plane coordinates */

/* 0x34 T_R_Y (RW): Bayer plane shift T_R, y part (D2, D12). Ignored in GRAY mode. */
#define PATRM_T_R_Y_OFFSET                  0x34U
#define PATRM_T_R_Y_RESET                   0x00000000U
#define PATRM_T_R_Y_VALUE_SHIFT            0U
#define PATRM_T_R_Y_VALUE_WIDTH            32U
#define PATRM_T_R_Y_VALUE_MASK             0xFFFFFFFFU   /* RW: signed Q15.16, plane coordinates */

/* 0x38 T_GR_X (RW): Bayer plane shift T_Gr, x part (D2, D12). Ignored in GRAY mode. */
#define PATRM_T_GR_X_OFFSET                 0x38U
#define PATRM_T_GR_X_RESET                  0x00000000U
#define PATRM_T_GR_X_VALUE_SHIFT           0U
#define PATRM_T_GR_X_VALUE_WIDTH           32U
#define PATRM_T_GR_X_VALUE_MASK            0xFFFFFFFFU   /* RW: signed Q15.16, plane coordinates */

/* 0x3C T_GR_Y (RW): Bayer plane shift T_Gr, y part (D2, D12). Ignored in GRAY mode. */
#define PATRM_T_GR_Y_OFFSET                 0x3CU
#define PATRM_T_GR_Y_RESET                  0x00000000U
#define PATRM_T_GR_Y_VALUE_SHIFT           0U
#define PATRM_T_GR_Y_VALUE_WIDTH           32U
#define PATRM_T_GR_Y_VALUE_MASK            0xFFFFFFFFU   /* RW: signed Q15.16, plane coordinates */

/* 0x40 T_GB_X (RW): Bayer plane shift T_Gb, x part (D2, D12). Ignored in GRAY mode. */
#define PATRM_T_GB_X_OFFSET                 0x40U
#define PATRM_T_GB_X_RESET                  0x00000000U
#define PATRM_T_GB_X_VALUE_SHIFT           0U
#define PATRM_T_GB_X_VALUE_WIDTH           32U
#define PATRM_T_GB_X_VALUE_MASK            0xFFFFFFFFU   /* RW: signed Q15.16, plane coordinates */

/* 0x44 T_GB_Y (RW): Bayer plane shift T_Gb, y part (D2, D12). Ignored in GRAY mode. */
#define PATRM_T_GB_Y_OFFSET                 0x44U
#define PATRM_T_GB_Y_RESET                  0x00000000U
#define PATRM_T_GB_Y_VALUE_SHIFT           0U
#define PATRM_T_GB_Y_VALUE_WIDTH           32U
#define PATRM_T_GB_Y_VALUE_MASK            0xFFFFFFFFU   /* RW: signed Q15.16, plane coordinates */

/* 0x48 T_B_X (RW): Bayer plane shift T_B, x part (D2, D12). Ignored in GRAY mode. */
#define PATRM_T_B_X_OFFSET                  0x48U
#define PATRM_T_B_X_RESET                   0x00000000U
#define PATRM_T_B_X_VALUE_SHIFT            0U
#define PATRM_T_B_X_VALUE_WIDTH            32U
#define PATRM_T_B_X_VALUE_MASK             0xFFFFFFFFU   /* RW: signed Q15.16, plane coordinates */

/* 0x4C T_B_Y (RW): Bayer plane shift T_B, y part (D2, D12). Ignored in GRAY mode. */
#define PATRM_T_B_Y_OFFSET                  0x4CU
#define PATRM_T_B_Y_RESET                   0x00000000U
#define PATRM_T_B_Y_VALUE_SHIFT            0U
#define PATRM_T_B_Y_VALUE_WIDTH            32U
#define PATRM_T_B_Y_VALUE_MASK             0xFFFFFFFFU   /* RW: signed Q15.16, plane coordinates */

/* 0x50 BLOCK_LEN (RW): Block length L (D13): output pixels per block, capped at the end of a row. Changes memory traffic only, never the output. Reset 0 is rejected, so the driver must write it. */
#define PATRM_BLOCK_LEN_OFFSET              0x50U
#define PATRM_BLOCK_LEN_RESET               0x00000000U
#define PATRM_BLOCK_LEN_L_SHIFT            0U
#define PATRM_BLOCK_LEN_L_WIDTH            13U
#define PATRM_BLOCK_LEN_L_MASK             0x00001FFFU   /* RW: 1..BUILD_ID.BLOCK_LEN_MAX */

/* 0x54 CYCLES (RO): Clock cycles from the accepted start to DONE (100 MHz, D8). Cleared at an accepted start, holds its value after DONE. */
#define PATRM_CYCLES_OFFSET                 0x54U
#define PATRM_CYCLES_RESET                  0x00000000U
#define PATRM_CYCLES_COUNT_SHIFT           0U
#define PATRM_CYCLES_COUNT_WIDTH           32U
#define PATRM_CYCLES_COUNT_MASK            0xFFFFFFFFU   /* RO: cycles */

/* 0x58 BYTES_RD (RO): Bytes read on HP0 in this job = 8 x accepted read beats (comparable to the step 1.4 memory model). Cleared at an accepted start. */
#define PATRM_BYTES_RD_OFFSET               0x58U
#define PATRM_BYTES_RD_RESET                0x00000000U
#define PATRM_BYTES_RD_COUNT_SHIFT         0U
#define PATRM_BYTES_RD_COUNT_WIDTH         32U
#define PATRM_BYTES_RD_COUNT_MASK          0xFFFFFFFFU   /* RO: bytes */

/* 0x5C BYTES_WR (RO): Bytes written on HP1 in this job = 8 x accepted write beats, including beats with partial WSTRB (memmodel write_bus_bytes). Cleared at an accepted start. */
#define PATRM_BYTES_WR_OFFSET               0x5CU
#define PATRM_BYTES_WR_RESET                0x00000000U
#define PATRM_BYTES_WR_COUNT_SHIFT         0U
#define PATRM_BYTES_WR_COUNT_WIDTH         32U
#define PATRM_BYTES_WR_COUNT_MASK          0xFFFFFFFFU   /* RO: bytes */

/* 0x60 RD_STALL (RO): Cycles in this job in which the pixel pipeline waited for source data that was not yet in the prefetch buffer. Exact definition in spec/interface.md (step 2.2). Cleared at an accepted start. */
#define PATRM_RD_STALL_OFFSET               0x60U
#define PATRM_RD_STALL_RESET                0x00000000U
#define PATRM_RD_STALL_COUNT_SHIFT         0U
#define PATRM_RD_STALL_COUNT_WIDTH         32U
#define PATRM_RD_STALL_COUNT_MASK          0xFFFFFFFFU   /* RO: cycles */

/* 0x64 WR_STALL (RO): Cycles in this job in which the pixel pipeline waited because the output FIFO was full. Exact definition in spec/interface.md (step 2.2). Cleared at an accepted start. */
#define PATRM_WR_STALL_OFFSET               0x64U
#define PATRM_WR_STALL_RESET                0x00000000U
#define PATRM_WR_STALL_COUNT_SHIFT         0U
#define PATRM_WR_STALL_COUNT_WIDTH         32U
#define PATRM_WR_STALL_COUNT_MASK          0xFFFFFFFFU   /* RO: cycles */

/* 0x68 BUILD_ID (RO): Build identification, constant per bitstream (set from synthesis parameters). The driver reads it before the first job. */
#define PATRM_BUILD_ID_OFFSET               0x68U
#define PATRM_BUILD_ID_VERSION_SHIFT       0U
#define PATRM_BUILD_ID_VERSION_WIDTH       8U
#define PATRM_BUILD_ID_VERSION_MASK        0x000000FFU   /* RO: register map version (constant VERSION) */
#define PATRM_BUILD_ID_BUILD_TYPE_SHIFT    8U
#define PATRM_BUILD_ID_BUILD_TYPE_WIDTH    2U
#define PATRM_BUILD_ID_BUILD_TYPE_MASK     0x00000300U   /* RO: 0 = gray, 1 = Option A, 2 = Option B */
#define PATRM_BUILD_ID_MODES_SHIFT         12U
#define PATRM_BUILD_ID_MODES_WIDTH         3U
#define PATRM_BUILD_ID_MODES_MASK          0x00007000U   /* RO: supported CTRL.MODE values, bit n = mode n supported */
#define PATRM_BUILD_ID_BLOCK_LEN_MAX_SHIFT  16U
#define PATRM_BUILD_ID_BLOCK_LEN_MAX_WIDTH  13U
#define PATRM_BUILD_ID_BLOCK_LEN_MAX_MASK  0x1FFF0000U   /* RO: largest accepted BLOCK_LEN (D13, synthesis parameter chosen in step 2.2) */

#endif /* PATRM_REGS_H */
