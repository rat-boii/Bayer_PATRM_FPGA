// axil_regs: AXI4-Lite register file, start check and interrupt of the PATRM engine (step 3.1).
//
// Spec: spec/interface.md section 1, spec/regs.json (via rtl/patrm_regs.vh), spec/memory_map.md.
// - One transaction at a time. A write is taken when AWVALID and WVALID are both 1 (cycle T), so AW and W may
//   arrive in either order or together; BVALID rises in T+1. A write wins over a read in the same cycle.
//   A read is taken when no write response is pending; RVALID rises the next cycle. BRESP = RRESP = OKAY.
// - Unmapped offsets read 0, writes to them are ignored. Reserved bits read 0. WSTRB is honoured per byte.
// - Configuration registers are locked while STATUS.BUSY = 1 (CTRL.IRQ_EN stays writable).
// - CTRL write with START = 1: the configuration is checked in cycle T (first failing check wins:
//   START_BUSY, BAD_MODE, BAD_SIZE, BAD_ADDR, BAD_BLOCK_LEN). The outcome is in STATUS at the end of T, before
//   BVALID: either ERROR + ERR_CODE, or BUSY (start_accept = 1 in T+1, and STATUS.BUSY = busy | start_accept,
//   so BUSY reads 1 from T+1 even though ctrl_fsm raises `busy` one cycle later).
// - STATUS.DONE is set by done_set (set wins over a W1C clear in the same cycle, so no done is lost).
// - interrupt = CTRL.IRQ_EN & STATUS.DONE, a register loaded from the next-state values, so it always equals
//   the current register bits (no extra cycle of lag after a W1C).
//
// Verilog-2001, non-ANSI ports so that the port widths can use the localparams of patrm_regs.vh.
// Build parameters (VERSION, BUILD_TYPE, MODES, BLOCK_LEN_MAX) set BUILD_ID and the start check.
`timescale 1ns/1ps
module axil_regs (
    aclk, aresetn,
    s_axil_awaddr, s_axil_awprot, s_axil_awvalid, s_axil_awready,
    s_axil_wdata, s_axil_wstrb, s_axil_wvalid, s_axil_wready,
    s_axil_bresp, s_axil_bvalid, s_axil_bready,
    s_axil_araddr, s_axil_arprot, s_axil_arvalid, s_axil_arready,
    s_axil_rdata, s_axil_rresp, s_axil_rvalid, s_axil_rready,
    cfg_mode, cfg_src_addr, cfg_dst_addr, cfg_width, cfg_height,
    cfg_b11, cfg_b12, cfg_b13, cfg_b21, cfg_b22, cfg_b23,
    cfg_t_r_x, cfg_t_r_y, cfg_t_gr_x, cfg_t_gr_y, cfg_t_gb_x, cfg_t_gb_y, cfg_t_b_x, cfg_t_b_y,
    cfg_block_len,
    start_accept, busy, done_set,
    cnt_cycles, cnt_bytes_rd, cnt_bytes_wr, cnt_rd_stall, cnt_wr_stall,
    interrupt
);

`include "patrm_regs.vh"

    // ---- build parameters (spec/interface.md section 0) ----
    parameter VERSION       = PATRM_VERSION;
    parameter BUILD_TYPE    = PATRM_BUILD_TYPE_GRAY;
    parameter MODES         = 1 << PATRM_MODE_GRAY;      // bit n = CTRL.MODE n supported
    parameter BLOCK_LEN_MAX = 64;                        // D15

    localparam DW       = 32;                            // AXI-Lite data width (regs.json data_width)
    localparam AW       = PATRM_ADDR_BITS;
    localparam SB       = PATRM_SIZE_BITS;
    localparam WIDX     = AW - 2;                        // word index bits
    localparam [1:0] AXI_RESP_OKAY = 2'b00;
    localparam MODE_W   = PATRM_CTRL_MODE_W;
    localparam ERR_W    = PATRM_STATUS_ERR_CODE_W;
    localparam NMODES   = 1 << MODE_W;                   // number of MODE encodings (incl. the invalid one)

    // ---- ports ----
    input               aclk;
    input               aresetn;

    input  [AW-1:0]     s_axil_awaddr;
    input  [2:0]        s_axil_awprot;                   // ignored
    input               s_axil_awvalid;
    output              s_axil_awready;
    input  [DW-1:0]     s_axil_wdata;
    input  [DW/8-1:0]   s_axil_wstrb;
    input               s_axil_wvalid;
    output              s_axil_wready;
    output [1:0]        s_axil_bresp;
    output              s_axil_bvalid;
    input               s_axil_bready;
    input  [AW-1:0]     s_axil_araddr;
    input  [2:0]        s_axil_arprot;                   // ignored
    input               s_axil_arvalid;
    output              s_axil_arready;
    output [DW-1:0]     s_axil_rdata;
    output [1:0]        s_axil_rresp;
    output              s_axil_rvalid;
    input               s_axil_rready;

    output [MODE_W-1:0] cfg_mode;
    output [31:0]       cfg_src_addr, cfg_dst_addr;
    output [SB-1:0]     cfg_width, cfg_height;
    output [31:0]       cfg_b11, cfg_b12, cfg_b13, cfg_b21, cfg_b22, cfg_b23;
    output [31:0]       cfg_t_r_x, cfg_t_r_y, cfg_t_gr_x, cfg_t_gr_y, cfg_t_gb_x, cfg_t_gb_y, cfg_t_b_x, cfg_t_b_y;
    output [SB-1:0]     cfg_block_len;

    output              start_accept;
    input               busy;
    input               done_set;
    input  [31:0]       cnt_cycles, cnt_bytes_rd, cnt_bytes_wr, cnt_rd_stall, cnt_wr_stall;
    output              interrupt;

    // ---- registers ----
    reg [MODE_W-1:0]    ctrl_mode;
    reg                 ctrl_irq_en;
    reg                 st_done, st_error;
    reg [ERR_W-1:0]     st_err_code;
    reg [31:0]          r_src_addr, r_dst_addr;
    reg [SB-1:0]        r_width, r_height, r_block_len;
    reg [31:0]          r_b11, r_b12, r_b13, r_b21, r_b22, r_b23;
    reg [31:0]          r_t_r_x, r_t_r_y, r_t_gr_x, r_t_gr_y, r_t_gb_x, r_t_gb_y, r_t_b_x, r_t_b_y;
    reg                 start_accept_r;
    reg                 irq_r;
    reg                 bvalid_r, rvalid_r;
    reg [DW-1:0]        rdata_r;

    // ---- handshake ----
    wire wr_fire = s_axil_awvalid & s_axil_wvalid & ~bvalid_r & ~rvalid_r;
    wire rd_fire = s_axil_arvalid & ~bvalid_r & ~rvalid_r & ~(s_axil_awvalid & s_axil_wvalid);

    assign s_axil_awready = wr_fire;
    assign s_axil_wready  = wr_fire;
    assign s_axil_arready = rd_fire;
    assign s_axil_bvalid  = bvalid_r;
    assign s_axil_bresp   = AXI_RESP_OKAY;
    assign s_axil_rvalid  = rvalid_r;
    assign s_axil_rresp   = AXI_RESP_OKAY;
    assign s_axil_rdata   = rdata_r;

    wire [WIDX-1:0] wr_idx = s_axil_awaddr[AW-1:2];
    wire [WIDX-1:0] rd_idx = s_axil_araddr[AW-1:2];

    // write data merged into the old value byte by byte (WSTRB)
    function [DW-1:0] merge;
        input [DW-1:0]   old_v;
        input [DW-1:0]   new_v;
        input [DW/8-1:0] strb;
        integer k;
        begin
            for (k = 0; k < DW/8; k = k + 1)
                merge[8*k +: 8] = strb[k] ? new_v[8*k +: 8] : old_v[8*k +: 8];
        end
    endfunction

    // STATUS.BUSY as seen by software and by the lock / START_BUSY check
    wire busy_vis = busy | start_accept_r;

    function wr_hit;                                     // write to register at byte offset `off`, unlocked
        input [AW-1:0] off;
        begin
            wr_hit = wr_fire && (wr_idx == off[AW-1:2]) && !busy_vis;
        end
    endfunction

    // ---- CTRL write and START check (cycle T) ----
    wire ctrl_wr     = wr_fire && (wr_idx == PATRM_REG_CTRL[AW-1:2]);
    wire status_wr   = wr_fire && (wr_idx == PATRM_REG_STATUS[AW-1:2]);
    wire start_req   = ctrl_wr && s_axil_wstrb[PATRM_CTRL_START_LSB/8] && s_axil_wdata[PATRM_CTRL_START_LSB];
    wire mode_strb   = s_axil_wstrb[PATRM_CTRL_MODE_LSB/8];
    wire [MODE_W-1:0] new_mode = mode_strb ? s_axil_wdata[PATRM_CTRL_MODE_LSB +: MODE_W] : ctrl_mode;

    wire [NMODES-1:0] modes_ok = MODES;                  // MODE 3 maps to a bit that is always 0
    wire is_gray     = (new_mode == PATRM_MODE_GRAY);
    wire bad_mode    = !modes_ok[new_mode];
    wire size_range  = (r_width == 0) || (r_width > PATRM_MAX_SIZE) ||
                       (r_height == 0) || (r_height > PATRM_MAX_SIZE);
    wire size_d3     = is_gray ? ((r_width % PATRM_GRAY_W_MULT) != 0)
                               : (((r_width % PATRM_BAYER_W_MULT) != 0) || ((r_height % PATRM_BAYER_H_MULT) != 0));
    wire bad_size    = size_range || size_d3;
    wire bad_addr    = ((r_src_addr % PATRM_ADDR_ALIGN) != 0) || ((r_dst_addr % PATRM_ADDR_ALIGN) != 0);
    wire bad_blen    = (r_block_len == 0) || (r_block_len > BLOCK_LEN_MAX);

    reg [ERR_W-1:0] chk_err;
    always @(*) begin
        if (busy_vis)        chk_err = PATRM_ERR_START_BUSY;
`ifdef PATRM_FAULT_ERR_PRIO                              // fault injection for the testbench only
        else if (bad_size)   chk_err = PATRM_ERR_BAD_SIZE;
        else if (bad_mode)   chk_err = PATRM_ERR_BAD_MODE;
`else
        else if (bad_mode)   chk_err = PATRM_ERR_BAD_MODE;
        else if (bad_size)   chk_err = PATRM_ERR_BAD_SIZE;
`endif
        else if (bad_addr)   chk_err = PATRM_ERR_BAD_ADDR;
        else if (bad_blen)   chk_err = PATRM_ERR_BAD_BLOCK_LEN;
        else                 chk_err = PATRM_ERR_NONE;
    end

    wire start_ok  = start_req && (chk_err == PATRM_ERR_NONE);
    wire start_bad = start_req && (chk_err != PATRM_ERR_NONE);

    // ---- next state of the bits that feed the interrupt ----
    wire status_b0  = status_wr && s_axil_wstrb[PATRM_STATUS_DONE_LSB/8];
    wire done_w1c   = status_b0 && s_axil_wdata[PATRM_STATUS_DONE_LSB];
    wire error_w1c  = status_wr && s_axil_wstrb[PATRM_STATUS_ERROR_LSB/8] && s_axil_wdata[PATRM_STATUS_ERROR_LSB];
    wire irq_en_nxt = (ctrl_wr && s_axil_wstrb[PATRM_CTRL_IRQ_EN_LSB/8]) ? s_axil_wdata[PATRM_CTRL_IRQ_EN_LSB]
                                                                          : ctrl_irq_en;
    wire done_nxt   = done_set | (st_done & ~done_w1c & ~start_ok);

    // ---- register writes ----
    always @(posedge aclk) begin
        if (!aresetn) begin
            ctrl_mode      <= PATRM_CTRL_RESET[PATRM_CTRL_MODE_LSB +: MODE_W];
            ctrl_irq_en    <= PATRM_CTRL_RESET[PATRM_CTRL_IRQ_EN_LSB];
            st_done        <= PATRM_STATUS_RESET[PATRM_STATUS_DONE_LSB];
            st_error       <= PATRM_STATUS_RESET[PATRM_STATUS_ERROR_LSB];
            st_err_code    <= PATRM_STATUS_RESET[PATRM_STATUS_ERR_CODE_LSB +: ERR_W];
            r_src_addr     <= PATRM_SRC_ADDR_RESET;
            r_dst_addr     <= PATRM_DST_ADDR_RESET;
            r_width        <= PATRM_WIDTH_RESET[SB-1:0];
            r_height       <= PATRM_HEIGHT_RESET[SB-1:0];
            r_b11          <= PATRM_B11_RESET;
            r_b12          <= PATRM_B12_RESET;
            r_b13          <= PATRM_B13_RESET;
            r_b21          <= PATRM_B21_RESET;
            r_b22          <= PATRM_B22_RESET;
            r_b23          <= PATRM_B23_RESET;
            r_t_r_x        <= PATRM_T_R_X_RESET;
            r_t_r_y        <= PATRM_T_R_Y_RESET;
            r_t_gr_x       <= PATRM_T_GR_X_RESET;
            r_t_gr_y       <= PATRM_T_GR_Y_RESET;
            r_t_gb_x       <= PATRM_T_GB_X_RESET;
            r_t_gb_y       <= PATRM_T_GB_Y_RESET;
            r_t_b_x        <= PATRM_T_B_X_RESET;
            r_t_b_y        <= PATRM_T_B_Y_RESET;
            r_block_len    <= PATRM_BLOCK_LEN_RESET[SB-1:0];
            start_accept_r <= 1'b0;
            irq_r          <= 1'b0;
        end else begin
            // CTRL: IRQ_EN always, MODE only while idle
            ctrl_irq_en <= irq_en_nxt;
            if (ctrl_wr && mode_strb && !busy_vis)
                ctrl_mode <= s_axil_wdata[PATRM_CTRL_MODE_LSB +: MODE_W];

            // STATUS: W1C, start outcome, done (done_set wins)
            if (error_w1c) begin
                st_error    <= 1'b0;
                st_err_code <= PATRM_ERR_NONE;
            end
            if (start_bad) begin
                st_error    <= 1'b1;
                st_err_code <= chk_err;
            end
            if (start_ok) begin
                st_error    <= 1'b0;
                st_err_code <= PATRM_ERR_NONE;
            end
            st_done        <= done_nxt;
            start_accept_r <= start_ok;
            irq_r          <= irq_en_nxt & done_nxt;

            // configuration registers (locked while busy)
            if (wr_hit(PATRM_REG_SRC_ADDR))  r_src_addr  <= merge(r_src_addr,  s_axil_wdata, s_axil_wstrb);
            if (wr_hit(PATRM_REG_DST_ADDR))  r_dst_addr  <= merge(r_dst_addr,  s_axil_wdata, s_axil_wstrb);
            if (wr_hit(PATRM_REG_WIDTH))     r_width     <= merge({{(DW-SB){1'b0}}, r_width},     s_axil_wdata, s_axil_wstrb) >> PATRM_WIDTH_W_LSB;
            if (wr_hit(PATRM_REG_HEIGHT))    r_height    <= merge({{(DW-SB){1'b0}}, r_height},    s_axil_wdata, s_axil_wstrb) >> PATRM_HEIGHT_H_LSB;
            if (wr_hit(PATRM_REG_B11))       r_b11       <= merge(r_b11,       s_axil_wdata, s_axil_wstrb);
            if (wr_hit(PATRM_REG_B12))       r_b12       <= merge(r_b12,       s_axil_wdata, s_axil_wstrb);
            if (wr_hit(PATRM_REG_B13))       r_b13       <= merge(r_b13,       s_axil_wdata, s_axil_wstrb);
            if (wr_hit(PATRM_REG_B21))       r_b21       <= merge(r_b21,       s_axil_wdata, s_axil_wstrb);
            if (wr_hit(PATRM_REG_B22))       r_b22       <= merge(r_b22,       s_axil_wdata, s_axil_wstrb);
            if (wr_hit(PATRM_REG_B23))       r_b23       <= merge(r_b23,       s_axil_wdata, s_axil_wstrb);
            if (wr_hit(PATRM_REG_T_R_X))     r_t_r_x     <= merge(r_t_r_x,     s_axil_wdata, s_axil_wstrb);
            if (wr_hit(PATRM_REG_T_R_Y))     r_t_r_y     <= merge(r_t_r_y,     s_axil_wdata, s_axil_wstrb);
            if (wr_hit(PATRM_REG_T_GR_X))    r_t_gr_x    <= merge(r_t_gr_x,    s_axil_wdata, s_axil_wstrb);
            if (wr_hit(PATRM_REG_T_GR_Y))    r_t_gr_y    <= merge(r_t_gr_y,    s_axil_wdata, s_axil_wstrb);
            if (wr_hit(PATRM_REG_T_GB_X))    r_t_gb_x    <= merge(r_t_gb_x,    s_axil_wdata, s_axil_wstrb);
            if (wr_hit(PATRM_REG_T_GB_Y))    r_t_gb_y    <= merge(r_t_gb_y,    s_axil_wdata, s_axil_wstrb);
            if (wr_hit(PATRM_REG_T_B_X))     r_t_b_x     <= merge(r_t_b_x,     s_axil_wdata, s_axil_wstrb);
            if (wr_hit(PATRM_REG_T_B_Y))     r_t_b_y     <= merge(r_t_b_y,     s_axil_wdata, s_axil_wstrb);
            if (wr_hit(PATRM_REG_BLOCK_LEN)) r_block_len <= merge({{(DW-SB){1'b0}}, r_block_len}, s_axil_wdata, s_axil_wstrb) >> PATRM_BLOCK_LEN_L_LSB;
        end
    end

`ifdef PATRM_FAULT_START_2CYC                            // fault injection for the testbench only
    reg start_accept_d;
    always @(posedge aclk) start_accept_d <= aresetn & start_accept_r;
    assign start_accept = start_accept_r | start_accept_d;
`else
    assign start_accept = start_accept_r;
`endif
    assign interrupt = irq_r;

    // ---- read data (registered in the AR handshake cycle) ----
    wire [DW-1:0] ctrl_word = ({{(DW-MODE_W){1'b0}}, ctrl_mode} << PATRM_CTRL_MODE_LSB) |
                              ({{(DW-1){1'b0}}, ctrl_irq_en}    << PATRM_CTRL_IRQ_EN_LSB);
    wire [DW-1:0] status_word = ({{(DW-1){1'b0}}, busy_vis}       << PATRM_STATUS_BUSY_LSB) |
                                ({{(DW-1){1'b0}}, st_done}        << PATRM_STATUS_DONE_LSB) |
                                ({{(DW-1){1'b0}}, st_error}       << PATRM_STATUS_ERROR_LSB) |
                                ({{(DW-ERR_W){1'b0}}, st_err_code} << PATRM_STATUS_ERR_CODE_LSB);
    wire [DW-1:0] build_id_word =
        ((VERSION       & ((1 << PATRM_BUILD_ID_VERSION_W) - 1))       << PATRM_BUILD_ID_VERSION_LSB) |
        ((BUILD_TYPE    & ((1 << PATRM_BUILD_ID_BUILD_TYPE_W) - 1))    << PATRM_BUILD_ID_BUILD_TYPE_LSB) |
        ((MODES         & ((1 << PATRM_BUILD_ID_MODES_W) - 1))         << PATRM_BUILD_ID_MODES_LSB) |
        ((BLOCK_LEN_MAX & ((1 << PATRM_BUILD_ID_BLOCK_LEN_MAX_W) - 1)) << PATRM_BUILD_ID_BLOCK_LEN_MAX_LSB);

    reg [DW-1:0] rd_mux;
    always @(*) begin
        case (rd_idx)
            PATRM_REG_CTRL[AW-1:2]:      rd_mux = ctrl_word;
            PATRM_REG_STATUS[AW-1:2]:    rd_mux = status_word;
            PATRM_REG_SRC_ADDR[AW-1:2]:  rd_mux = r_src_addr;
            PATRM_REG_DST_ADDR[AW-1:2]:  rd_mux = r_dst_addr;
            PATRM_REG_WIDTH[AW-1:2]:     rd_mux = {{(DW-SB){1'b0}}, r_width}     << PATRM_WIDTH_W_LSB;
            PATRM_REG_HEIGHT[AW-1:2]:    rd_mux = {{(DW-SB){1'b0}}, r_height}    << PATRM_HEIGHT_H_LSB;
            PATRM_REG_B11[AW-1:2]:       rd_mux = r_b11;
            PATRM_REG_B12[AW-1:2]:       rd_mux = r_b12;
            PATRM_REG_B13[AW-1:2]:       rd_mux = r_b13;
            PATRM_REG_B21[AW-1:2]:       rd_mux = r_b21;
            PATRM_REG_B22[AW-1:2]:       rd_mux = r_b22;
            PATRM_REG_B23[AW-1:2]:       rd_mux = r_b23;
            PATRM_REG_T_R_X[AW-1:2]:     rd_mux = r_t_r_x;
            PATRM_REG_T_R_Y[AW-1:2]:     rd_mux = r_t_r_y;
            PATRM_REG_T_GR_X[AW-1:2]:    rd_mux = r_t_gr_x;
            PATRM_REG_T_GR_Y[AW-1:2]:    rd_mux = r_t_gr_y;
            PATRM_REG_T_GB_X[AW-1:2]:    rd_mux = r_t_gb_x;
            PATRM_REG_T_GB_Y[AW-1:2]:    rd_mux = r_t_gb_y;
            PATRM_REG_T_B_X[AW-1:2]:     rd_mux = r_t_b_x;
            PATRM_REG_T_B_Y[AW-1:2]:     rd_mux = r_t_b_y;
            PATRM_REG_BLOCK_LEN[AW-1:2]: rd_mux = {{(DW-SB){1'b0}}, r_block_len} << PATRM_BLOCK_LEN_L_LSB;
            PATRM_REG_CYCLES[AW-1:2]:    rd_mux = cnt_cycles;
            PATRM_REG_BYTES_RD[AW-1:2]:  rd_mux = cnt_bytes_rd;
            PATRM_REG_BYTES_WR[AW-1:2]:  rd_mux = cnt_bytes_wr;
            PATRM_REG_RD_STALL[AW-1:2]:  rd_mux = cnt_rd_stall;
            PATRM_REG_WR_STALL[AW-1:2]:  rd_mux = cnt_wr_stall;
            PATRM_REG_BUILD_ID[AW-1:2]:  rd_mux = build_id_word;
            default:                     rd_mux = {DW{1'b0}};
        endcase
    end

    // ---- response channels ----
    always @(posedge aclk) begin
        if (!aresetn) begin
            bvalid_r <= 1'b0;
            rvalid_r <= 1'b0;
            rdata_r  <= {DW{1'b0}};
        end else begin
            if (wr_fire)
                bvalid_r <= 1'b1;
            else if (s_axil_bready)
                bvalid_r <= 1'b0;
            if (rd_fire) begin
                rvalid_r <= 1'b1;
                rdata_r  <= rd_mux;
            end else if (s_axil_rready) begin
                rvalid_r <= 1'b0;
            end
        end
    end

    // ---- configuration outputs ----
    assign cfg_mode      = ctrl_mode;
    assign cfg_src_addr  = r_src_addr;
    assign cfg_dst_addr  = r_dst_addr;
    assign cfg_width     = r_width;
    assign cfg_height    = r_height;
    assign cfg_b11       = r_b11;
    assign cfg_b12       = r_b12;
    assign cfg_b13       = r_b13;
    assign cfg_b21       = r_b21;
    assign cfg_b22       = r_b22;
    assign cfg_b23       = r_b23;
    assign cfg_t_r_x     = r_t_r_x;
    assign cfg_t_r_y     = r_t_r_y;
    assign cfg_t_gr_x    = r_t_gr_x;
    assign cfg_t_gr_y    = r_t_gr_y;
    assign cfg_t_gb_x    = r_t_gb_x;
    assign cfg_t_gb_y    = r_t_gb_y;
    assign cfg_t_b_x     = r_t_b_x;
    assign cfg_t_b_y     = r_t_b_y;
    assign cfg_block_len = r_block_len;

endmodule
