// Self-checking testbench of the whole engine rtl/patrm_top.v (step 3.7; Bayer Option A: step 5.2). It behaves like the ARM driver
// (spec/memory_map.md section 4): programs the registers over AXI-Lite, starts, waits for the interrupt or polls
// STATUS, then checks the output in memory and the counters. One tb/axi_mem.v serves HP0 (reads) and HP1 (writes):
// source image at 0x1000_0000, output at 0x1800_0000.
//
// Needs the model vectors (data/vectors/, not tracked). Run from the repo root:
//   python scripts/gen_patrm_top_vectors.py
//   python scripts/sim.py --top tb_patrm_top -f tb/patrm_top.f --incdir rtl --plusarg VEC_DIR=data/vectors
// +VEC_DIR=<folder> is the vector folder (default ../../../data/vectors); the case list is
// <VEC_DIR>/patrm_top/cases.txt (format and groups: scripts/gen_patrm_top_vectors.py).
//
// Two builds of the same bench (step 5.2):
//   default          gray build, MODES = 3'b001, BUILD_TYPE 0, cases.txt
//   TB_BAYER_A       Option A build, MODES = 3'b011, BUILD_TYPE 1, cases_bayer_a.txt (MODE 1 jobs in every group plus
//                    gray jobs):  python scripts/sim.py --top tb_patrm_top -f tb/patrm_top.f --incdir rtl
//                                 --define TB_BAYER_A --plusarg VEC_DIR=data/vectors
// A MODE 1 job is four plane passes (spec section 18): one START, one DONE, BYTES_WR = 2 x W x H, WSTRB 8'h55 / 8'hAA
// per pass (checked on every W beat against the pass in progress), the output = model mosaic (bayer.warp_bayer).
//
// Checks in every complete frame:
//   output     at the moment DONE is visible: the output region == model frame byte for byte (it was filled with a
//              marker before the frame), guard words on both sides unchanged, source image unchanged
//   bus        every AR burst inside the source image, every AW burst inside the output image, burst and beat counts
//              == memmodel, tb/axi_mem.v protocol checker, unused HP channels at their constants (every cycle)
//   driver     BUSY = 1 inside the engine in the first BVALID cycle of START (AXI-Lite cannot read before the engine
//              has reacted, so this one is read from axil_regs.status_word) and in the first STATUS read
//   counters   CYCLES == cycles from the START handshake to DONE - 2 (S+1 = start_accept, S+2 = first busy cycle, DONE
//              visible one cycle after the last busy cycle), BYTES_RD == memmodel == 8 x R handshakes, BYTES_WR == W x H
//              == 8 x W handshakes, RD_STALL / WR_STALL == own counts per spec section 13, their sum <= CYCLES
// The run stops after the first frame with an error. Prints one line per case, the totals per group and exactly one
// final line: "TEST PASS" or "TEST FAIL: <reason>".
`timescale 1ns/1ps
module tb_patrm_top;

`include "patrm_regs.vh"

    localparam CLK_HALF  = 5;                            // 100 MHz
    localparam [31:0] SRC = 32'h1000_0000;
    localparam [31:0] DST = 32'h1800_0000;
    localparam MAXW      = 256 * 192 / 8;                // words of the largest frame
    localparam GUARD     = 512;                          // guard words checked on each side of the output
    localparam D0        = (DST - SRC) / 8;              // first output word in the memory model
    localparam MEM_WORDS = D0 + MAXW + GUARD + 16;
    localparam STR       = 8 * 400;
    localparam NGRP      = 8;
    localparam RST_CYC   = 16;
    localparam LITE_MAX  = 2000;                         // cycles an AXI-Lite access may take
    localparam [63:0] MARK = 64'hA5C3_5A3C_96E1_690F;

    localparam [31:0] C_START = 32'd1 << PATRM_CTRL_START_LSB;
    localparam [31:0] C_IRQ   = 32'd1 << PATRM_CTRL_IRQ_EN_LSB;
    localparam [31:0] S_BUSY  = 32'd1 << PATRM_STATUS_BUSY_LSB;
    localparam [31:0] S_DONE  = 32'd1 << PATRM_STATUS_DONE_LSB;
    localparam [31:0] S_ERROR = 32'd1 << PATRM_STATUS_ERROR_LSB;
`ifdef TB_BAYER_A
    localparam BUILD_TYPE = 1;                           // Option A build
    localparam MODES      = 3;                           // gray + Bayer A
`else
    localparam BUILD_TYPE = 0;                           // gray build
    localparam MODES      = 1;
`endif
    localparam [31:0] BUILD_ID_EXP = (32'd1 << PATRM_BUILD_ID_VERSION_LSB) |
                                     (BUILD_TYPE << PATRM_BUILD_ID_BUILD_TYPE_LSB) |
                                     (MODES << PATRM_BUILD_ID_MODES_LSB) | (32'd64 << PATRM_BUILD_ID_BLOCK_LEN_MAX_LSB);

    // ---------------- clock, reset ----------------
    reg aclk = 1'b0;
    reg aresetn = 1'b0;
    always #CLK_HALF aclk = ~aclk;

    // ---------------- AXI-Lite master signals ----------------
    reg  [6:0]  awaddr = 0, araddr = 0;
    reg  [31:0] wdata = 0;
    reg  [3:0]  wstrb = 0;
    reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [1:0]  bresp, rresp;
    wire [31:0] rdata;
    wire        interrupt;

    // ---------------- HP ports ----------------
    wire [5:0]  h0_awid, h0_wid, h0_arid, h0_rid;
    wire [31:0] h0_awaddr, h0_araddr;
    wire [3:0]  h0_awlen, h0_awcache, h0_awqos, h0_arlen, h0_arcache, h0_arqos;
    wire [2:0]  h0_awsize, h0_awprot, h0_arsize, h0_arprot;
    wire [1:0]  h0_awburst, h0_awlock, h0_arburst, h0_arlock, h0_rresp;
    wire        h0_awvalid, h0_wlast, h0_wvalid, h0_bready, h0_arvalid, h0_arready, h0_rlast, h0_rvalid, h0_rready;
    wire [63:0] h0_wdata, h0_rdata;
    wire [7:0]  h0_wstrb;
    wire [5:0]  h1_awid, h1_wid, h1_arid, h1_bid;
    wire [31:0] h1_awaddr, h1_araddr;
    wire [3:0]  h1_awlen, h1_awcache, h1_awqos, h1_arlen, h1_arcache, h1_arqos;
    wire [2:0]  h1_awsize, h1_awprot, h1_arsize, h1_arprot;
    wire [1:0]  h1_awburst, h1_awlock, h1_arburst, h1_arlock, h1_bresp;
    wire        h1_awvalid, h1_awready, h1_wlast, h1_wvalid, h1_wready, h1_bvalid, h1_bready, h1_arvalid, h1_rready;
    wire [63:0] h1_wdata;
    wire [7:0]  h1_wstrb;

    patrm_top #(.BUILD_TYPE(BUILD_TYPE), .MODES(MODES)) dut (
        .aclk(aclk), .aresetn(aresetn), .interrupt(interrupt),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b000), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b000), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .m_axi_hp0_awid(h0_awid), .m_axi_hp0_awaddr(h0_awaddr), .m_axi_hp0_awlen(h0_awlen),
        .m_axi_hp0_awsize(h0_awsize), .m_axi_hp0_awburst(h0_awburst), .m_axi_hp0_awlock(h0_awlock),
        .m_axi_hp0_awcache(h0_awcache), .m_axi_hp0_awprot(h0_awprot), .m_axi_hp0_awqos(h0_awqos),
        .m_axi_hp0_awvalid(h0_awvalid), .m_axi_hp0_awready(1'b0),
        .m_axi_hp0_wid(h0_wid), .m_axi_hp0_wdata(h0_wdata), .m_axi_hp0_wstrb(h0_wstrb), .m_axi_hp0_wlast(h0_wlast),
        .m_axi_hp0_wvalid(h0_wvalid), .m_axi_hp0_wready(1'b0),
        .m_axi_hp0_bid(6'd0), .m_axi_hp0_bresp(2'b00), .m_axi_hp0_bvalid(1'b0), .m_axi_hp0_bready(h0_bready),
        .m_axi_hp0_arid(h0_arid), .m_axi_hp0_araddr(h0_araddr), .m_axi_hp0_arlen(h0_arlen),
        .m_axi_hp0_arsize(h0_arsize), .m_axi_hp0_arburst(h0_arburst), .m_axi_hp0_arlock(h0_arlock),
        .m_axi_hp0_arcache(h0_arcache), .m_axi_hp0_arprot(h0_arprot), .m_axi_hp0_arqos(h0_arqos),
        .m_axi_hp0_arvalid(h0_arvalid), .m_axi_hp0_arready(h0_arready),
        .m_axi_hp0_rid(h0_rid), .m_axi_hp0_rdata(h0_rdata), .m_axi_hp0_rresp(h0_rresp), .m_axi_hp0_rlast(h0_rlast),
        .m_axi_hp0_rvalid(h0_rvalid), .m_axi_hp0_rready(h0_rready),
        .m_axi_hp1_awid(h1_awid), .m_axi_hp1_awaddr(h1_awaddr), .m_axi_hp1_awlen(h1_awlen),
        .m_axi_hp1_awsize(h1_awsize), .m_axi_hp1_awburst(h1_awburst), .m_axi_hp1_awlock(h1_awlock),
        .m_axi_hp1_awcache(h1_awcache), .m_axi_hp1_awprot(h1_awprot), .m_axi_hp1_awqos(h1_awqos),
        .m_axi_hp1_awvalid(h1_awvalid), .m_axi_hp1_awready(h1_awready),
        .m_axi_hp1_wid(h1_wid), .m_axi_hp1_wdata(h1_wdata), .m_axi_hp1_wstrb(h1_wstrb), .m_axi_hp1_wlast(h1_wlast),
        .m_axi_hp1_wvalid(h1_wvalid), .m_axi_hp1_wready(h1_wready),
        .m_axi_hp1_bid(h1_bid), .m_axi_hp1_bresp(h1_bresp), .m_axi_hp1_bvalid(h1_bvalid), .m_axi_hp1_bready(h1_bready),
        .m_axi_hp1_arid(h1_arid), .m_axi_hp1_araddr(h1_araddr), .m_axi_hp1_arlen(h1_arlen),
        .m_axi_hp1_arsize(h1_arsize), .m_axi_hp1_arburst(h1_arburst), .m_axi_hp1_arlock(h1_arlock),
        .m_axi_hp1_arcache(h1_arcache), .m_axi_hp1_arprot(h1_arprot), .m_axi_hp1_arqos(h1_arqos),
        .m_axi_hp1_arvalid(h1_arvalid), .m_axi_hp1_arready(1'b0),
        .m_axi_hp1_rid(6'd0), .m_axi_hp1_rdata(64'd0), .m_axi_hp1_rresp(2'b00), .m_axi_hp1_rlast(1'b0),
        .m_axi_hp1_rvalid(1'b0), .m_axi_hp1_rready(h1_rready));

    axi_mem #(.BASE(SRC), .MEM_WORDS(MEM_WORDS), .LAT_MIN(20), .LAT_MAX(20)) u_mem (
        .aclk(aclk), .aresetn(aresetn),
        .s_arid(h0_arid), .s_araddr(h0_araddr), .s_arlen({4'd0, h0_arlen}), .s_arsize(h0_arsize),
        .s_arburst(h0_arburst), .s_arvalid(h0_arvalid), .s_arready(h0_arready),
        .s_rid(h0_rid), .s_rdata(h0_rdata), .s_rresp(h0_rresp), .s_rlast(h0_rlast), .s_rvalid(h0_rvalid),
        .s_rready(h0_rready),
        .s_awid(h1_awid), .s_awaddr(h1_awaddr), .s_awlen({4'd0, h1_awlen}), .s_awsize(h1_awsize),
        .s_awburst(h1_awburst), .s_awvalid(h1_awvalid), .s_awready(h1_awready),
        .s_wid(h1_wid), .s_wdata(h1_wdata), .s_wstrb(h1_wstrb), .s_wlast(h1_wlast), .s_wvalid(h1_wvalid),
        .s_wready(h1_wready),
        .s_bid(h1_bid), .s_bresp(h1_bresp), .s_bvalid(h1_bvalid), .s_bready(h1_bready));

    // ---------------- case data ----------------
    reg [63:0] srcw [0:MAXW-1];
    reg [63:0] expw [0:MAXW-1];
    reg [STR-1:0] vecdir, path, c_name, c_src, c_exp, junk, msgbuf, first_fail;
    integer c_group, c_op, c_W, c_H, c_L, c_lat0, c_lat1, c_arbp, c_rgap, c_awbp, c_wbp, c_blat0, c_blat1;
    integer c_seed, c_irq, c_arg, c_bytes, c_rb, c_wb, c_mode, wfac;
    integer c_b [0:5];
    integer c_t [0:7];                                   // T_R_X .. T_B_Y (MODE 1; 0 in gray)
    integer fd_cases, r, npix, nwords;
    reg     have_case;

    // ---------------- results ----------------
    integer nfail = 0;
    integer n_frames [0:NGRP-1], n_bytes [0:NGRP-1];
    integer n_counter_frames = 0, n_bad_starts = 0, n_resets = 0, n_lock = 0, n_poll = 0, n_buserr = 0;
    integer n_rs_frames = 0, n_ws_frames = 0;            // frames with RD_STALL / WR_STALL != 0
    integer tie_err = 0, ar_err = 0, aw_err = 0, irq_err = 0, strb_err = 0;

    function [7:0] grp_letter;
        input integer g;
        begin
            grp_letter = "a" + g;
        end
    endfunction

    task record_fail;
        input [STR-1:0] m;
        begin
            if (nfail == 0) first_fail = m;
            nfail = nfail + 1;
            if (nfail <= 20) $display("  FAIL %0s", m);
        end
    endtask

    task fatal;
        input [STR-1:0] m;
        begin
            $display("TEST FAIL: %0s", m);
            $finish;
        end
    endtask

    task chk_eq;
        input [31:0] got, exp;
        input [8*80-1:0] what;
        begin
            if (got !== exp) begin
                $sformat(msgbuf, "(%c) %0s %0dx%0d L%0d: %0s = 0x%08h (%0d), expected 0x%08h (%0d)", grp_letter(c_group),
                         c_name, c_W, c_H, c_L, what, got, got, exp, exp);
                record_fail(msgbuf);
            end
        end
    endtask

    task chk;
        input ok;
        input [8*80-1:0] what;
        begin
            if (ok !== 1'b1) begin
                $sformat(msgbuf, "(%c) %0s %0dx%0d L%0d: %0s", grp_letter(c_group), c_name, c_W, c_H, c_L, what);
                record_fail(msgbuf);
            end
        end
    endtask

    // ---------------- monitor (sampled at the clock edge, before this edge's register updates) ----------------
    integer cyc = 0, lite_cnt = 0;
    reg     lite_busy = 1'b0;
    reg     arm_start = 1'b0, in_frame = 1'b0, done_seen = 1'b0, irq_seen = 1'b0;
    integer t_start = 0, t_done = 0, t_irq = 0, fs_count = 0, sa_count = 0;
    integer rs_tb = 0, ws_tb = 0, k_in = 0, f1_k = 0, f1_nr = 0;
    reg     m_stall;

    always @(posedge aclk) begin
        cyc = cyc + 1;
        if (lite_busy) begin
            lite_cnt = lite_cnt + 1;
            if (lite_cnt > LITE_MAX) fatal("AXI-Lite access does not complete");
        end else lite_cnt = 0;
        if (aresetn === 1'b1) begin
            // unused HP channels (spec sections 10, 11)
            if (h0_awvalid !== 1'b0 || h0_wvalid !== 1'b0 || h0_bready !== 1'b1 ||
                h1_arvalid !== 1'b0 || h1_rready !== 1'b1) tie_err = tie_err + 1;
            if (dut.frame_start === 1'b1) fs_count = fs_count + 1;
            if (dut.start_accept === 1'b1) sa_count = sa_count + 1;
            // bursts stay inside the images of the current frame
            if (h0_arvalid === 1'b1 && h0_arready === 1'b1 &&
                (h0_araddr < SRC || h0_araddr + 8 * (h0_arlen + 1) > SRC + npix)) ar_err = ar_err + 1;
            if (h1_awvalid === 1'b1 && h1_awready === 1'b1 &&
                (h1_awaddr < DST || h1_awaddr + 8 * (h1_awlen + 1) > DST + npix)) aw_err = aw_err + 1;
            // WSTRB: 8'hFF in gray, 8'h55 (R, Gb) / 8'hAA (Gr, B) in the pass in progress of a MODE 1 job
            if (h1_wvalid === 1'b1 && h1_wready === 1'b1 &&
                h1_wstrb !== ((c_mode == 1) ? (dut.pass_index[0] ? 8'hAA : 8'h55) : 8'hFF)) strb_err = strb_err + 1;
            // the START of a frame: AW and W handshake of CTRL with START = 1
            if (arm_start && awvalid && awready && wvalid && wready && awaddr[6:2] == (PATRM_REG_CTRL >> 2) &&
                wstrb[0] && wdata[PATRM_CTRL_START_LSB]) begin
                arm_start = 1'b0; in_frame = 1'b1; done_seen = 1'b0; irq_seen = 1'b0;
                t_start = cyc; t_done = 0; t_irq = 0;
                rs_tb = 0; ws_tb = 0; k_in = 0; f1_k = 0; f1_nr = 0;
            end else if (in_frame) begin
                if (!done_seen && dut.u_regs.st_done === 1'b1) begin done_seen = 1'b1; t_done = cyc; end
                if (!irq_seen && interrupt === 1'b1) begin irq_seen = 1'b1; t_irq = cyc; end
                if (c_irq == 0 && interrupt !== 1'b0) irq_err = irq_err + 1;
                // spec section 13, own counts
                if (dut.busy === 1'b1) begin
                    m_stall = dut.u_fetch.f1_v && (f1_nr != 0) && (f1_k >= dut.blocks_ready) && !dut.wr_stall;
                    if (m_stall) rs_tb = rs_tb + 1;
                    if (dut.op_valid && !dut.op_ready) ws_tb = ws_tb + 1;
                end
                if (dut.frame_start === 1'b1) begin     // a new pass: pixel_fetch and prefetch_ctrl restart at block 0
                    k_in = 0; f1_k = 0; f1_nr = 0;
                end
                if (dut.pix_valid && dut.pix_ready && !dut.frame_start) begin
                    f1_k = k_in;
                    f1_nr = dut.pix_nrows;
                    if (dut.pix_last && dut.pix_nrows != 0) k_in = k_in + 1;
                end
            end
        end
    end

    // ---------------- AXI-Lite master (driven 1 ns after the clock edge) ----------------
    reg [31:0] b_status;                                 // axil_regs.status_word in the first BVALID cycle

    task lite_write;
        input [6:0]  addr;
        input [31:0] data;
        reg done;
        begin
            lite_busy = 1'b1; lite_cnt = 0;
            awaddr = addr; wdata = data; wstrb = 4'hF; awvalid = 1'b1; wvalid = 1'b1; bready = 1'b1;
            done = 1'b0;
            while (!done) begin
                @(posedge aclk);
                done = awready && wready;
            end
            #1 awvalid = 1'b0; wvalid = 1'b0;
            done = 1'b0;
            while (!done) begin
                @(posedge aclk);
                if (bvalid) begin
                    done = 1'b1;
                    b_status = dut.u_regs.status_word;
                    if (bresp !== 2'b00) record_fail("BRESP != OKAY on AXI-Lite");
                end
            end
            #1 bready = 1'b0;
            lite_busy = 1'b0;
        end
    endtask

    task lite_read;
        input  [6:0]  addr;
        output [31:0] data;
        reg done;
        begin
            lite_busy = 1'b1; lite_cnt = 0;
            araddr = addr; arvalid = 1'b1; rready = 1'b1;
            done = 1'b0;
            while (!done) begin
                @(posedge aclk);
                done = arready;
            end
            #1 arvalid = 1'b0;
            done = 1'b0;
            while (!done) begin
                @(posedge aclk);
                if (rvalid) begin
                    done = 1'b1;
                    data = rdata;
                    if (rresp !== 2'b00) record_fail("RRESP != OKAY on AXI-Lite");
                end
            end
            #1 rready = 1'b0;
            lite_busy = 1'b0;
        end
    endtask

    task idle;
        input integer n;
        begin
            repeat (n) @(posedge aclk);
            #1;
        end
    endtask

    // ---------------- case file ----------------
    task skip_comments;
        input integer fd;
        integer ch, rr;
        reg more;
        begin
            more = 1'b1;
            while (more) begin
                ch = $fgetc(fd);
                if (ch == "#") rr = $fgets(junk, fd);
                else if (ch == "\n" || ch == "\r") more = 1'b1;
                else begin
                    if (ch != -1) rr = $ungetc(ch, fd);
                    more = 1'b0;
                end
            end
        end
    endtask

    task read_case;
        begin
            r = $fscanf(fd_cases, "%d %d %s %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %s %s %d %d %d %d %d %d %d %d %d",
                        c_group, c_op, c_name, c_W, c_H, c_L, c_b[0], c_b[1], c_b[2], c_b[3], c_b[4], c_b[5],
                        c_lat0, c_lat1, c_arbp, c_rgap, c_awbp, c_wbp, c_blat0, c_blat1, c_seed, c_irq, c_arg,
                        c_bytes, c_rb, c_wb, c_src, c_exp, c_mode, c_t[0], c_t[1], c_t[2], c_t[3], c_t[4], c_t[5],
                        c_t[6], c_t[7]);
            have_case = (r == 37);
            if (r != 37 && r != -1 && r != 0) fatal("bad line in the case file (rerun gen_patrm_top_vectors.py)");
            wfac = (c_mode == 1) ? 2 : 1;                // bus bytes written per output byte
        end
    endtask

    function [63:0] mark_of;                             // marker of memory word k
        input integer k;
        begin
            mark_of = MARK ^ k;
        end
    endfunction

    integer lk;
    task load_case;                                      // source image, expected frame, marker in the output area
        begin
            npix = c_W * c_H;
            nwords = npix / 8;
            if (nwords > MAXW) fatal("case too large for MAXW");
            srcw[nwords - 1] = 64'bx;
            expw[nwords - 1] = 64'bx;
            $sformat(path, "%0s/%0s", vecdir, c_src);
            $readmemh(path, srcw);
            if (srcw[nwords - 1] === 64'bx) begin
                $sformat(msgbuf, "cannot read %0s (run python scripts/gen_patrm_top_vectors.py, or pass +VEC_DIR)", path);
                fatal(msgbuf);
            end
            $sformat(path, "%0s/%0s", vecdir, c_exp);
            $readmemh(path, expw);
            if (expw[nwords - 1] === 64'bx) fatal("cannot read the expected frame");
            for (lk = 0; lk < nwords; lk = lk + 1) u_mem.mem[lk] = srcw[lk];
            for (lk = D0 - GUARD; lk < D0 + MAXW + GUARD; lk = lk + 1) u_mem.mem[lk] = mark_of(lk);
            u_mem.lat_min = c_lat0; u_mem.lat_max = c_lat1; u_mem.ar_bp_pct = c_arbp; u_mem.r_gap_pct = c_rgap;
            u_mem.aw_bp_pct = c_awbp; u_mem.w_bp_pct = c_wbp; u_mem.b_lat_min = c_blat0; u_mem.b_lat_max = c_blat1;
            u_mem.seed = c_seed;
            u_mem.err_burst   = (c_op == 2) ? u_mem.ar_count + c_arg : -1;
            u_mem.b_err_burst = (c_op == 3) ? u_mem.aw_count + c_arg : -1;
        end
    endtask

    task program_regs;                                   // driver steps 5 and 6
        integer q;
        begin
            lite_write(PATRM_REG_STATUS, S_DONE | S_ERROR);
            lite_write(PATRM_REG_SRC_ADDR, SRC);
            lite_write(PATRM_REG_DST_ADDR, DST);
            lite_write(PATRM_REG_WIDTH, c_W);
            lite_write(PATRM_REG_HEIGHT, c_H);
            lite_write(PATRM_REG_B11, c_b[0]);
            lite_write(PATRM_REG_B12, c_b[1]);
            lite_write(PATRM_REG_B13, c_b[2]);
            lite_write(PATRM_REG_B21, c_b[3]);
            lite_write(PATRM_REG_B22, c_b[4]);
            lite_write(PATRM_REG_B23, c_b[5]);
            for (q = 0; q < 8; q = q + 1) lite_write(PATRM_REG_T_R_X + 4 * q, c_t[q]);
            lite_write(PATRM_REG_BLOCK_LEN, c_L);
        end
    endtask

    // ---------------- output and source memory after a frame ----------------
    integer mk, m_bad, m_first;
    task check_memory;
        begin
            m_bad = 0; m_first = -1;
            for (mk = 0; mk < nwords; mk = mk + 1)
                if (u_mem.mem[D0 + mk] !== expw[mk]) begin
                    m_bad = m_bad + 1;
                    if (m_first < 0) m_first = mk;
                end
            if (m_bad != 0) begin
                $sformat(msgbuf, "(%c) %0s %0dx%0d L%0d: %0d of %0d output words differ from the model, first word %0d: %h, expected %h",
                         grp_letter(c_group), c_name, c_W, c_H, c_L, m_bad, nwords, m_first, u_mem.mem[D0 + m_first],
                         expw[m_first]);
                record_fail(msgbuf);
            end
            m_bad = 0;
            for (mk = 1; mk <= GUARD; mk = mk + 1) begin
                if (u_mem.mem[D0 - mk] !== mark_of(D0 - mk)) m_bad = m_bad + 1;
                if (u_mem.mem[D0 + nwords - 1 + mk] !== mark_of(D0 + nwords - 1 + mk)) m_bad = m_bad + 1;
            end
            chk_eq(m_bad, 0, "guard words changed around the output");
            m_bad = 0;
            for (mk = 0; mk < nwords; mk = mk + 1)
                if (u_mem.mem[mk] !== srcw[mk]) m_bad = m_bad + 1;
            chk_eq(m_bad, 0, "source words changed");
        end
    endtask

    // ---------------- one frame ----------------
    reg [31:0] rv, rv2, st_exp, ctrl_v;
    integer r0, w0, ar0, aw0, b0, fs0, poll, limit, t_wait, cycles;
    real    ppc;

    task reset_engine;                                   // aresetn low, then everything must be idle
        begin
            aresetn = 1'b0;
            in_frame = 1'b0; arm_start = 1'b0;
            idle(RST_CYC);
            aresetn = 1'b1;
            idle(2);
            chk(interrupt === 1'b0, "interrupt = 0 after aresetn");
            lite_read(PATRM_REG_STATUS, rv);    chk_eq(rv, 0, "STATUS after aresetn");
            lite_read(PATRM_REG_WIDTH, rv);     chk_eq(rv, PATRM_WIDTH_RESET, "WIDTH after aresetn");
            lite_read(PATRM_REG_B11, rv);       chk_eq(rv, PATRM_B11_RESET, "B11 after aresetn");
            lite_read(PATRM_REG_CYCLES, rv);    chk_eq(rv, 0, "CYCLES after aresetn");
            lite_read(PATRM_REG_BUILD_ID, rv);  chk_eq(rv, BUILD_ID_EXP, "BUILD_ID after aresetn");
            idle(100);
            chk(dut.busy === 1'b0, "busy = 0 after aresetn");
            chk_eq(u_mem.ar_count, 0, "AR handshakes after aresetn");
            chk_eq(u_mem.aw_count, 0, "AW handshakes after aresetn");
        end
    endtask

    task run_frame;
        begin
            load_case;
            r0 = u_mem.rbeats; w0 = u_mem.wbeats; ar0 = u_mem.log_n; aw0 = u_mem.wlog_n; b0 = u_mem.bcount;
            fs0 = fs_count;
            program_regs;
            ctrl_v = C_START | (c_irq ? C_IRQ : 32'd0) | (c_mode << PATRM_CTRL_MODE_LSB);
            arm_start = 1'b1;
            lite_write(PATRM_REG_CTRL, ctrl_v);          // driver step 7
            chk_eq(b_status & (S_BUSY | S_ERROR | S_DONE), S_BUSY, "STATUS in the first BVALID cycle of START");
            lite_read(PATRM_REG_STATUS, rv);             // driver step 8
            chk_eq(rv, S_BUSY, "first STATUS read after START");

            if (c_op == 1) begin                         // configuration writes while BUSY are ignored
                lite_write(PATRM_REG_SRC_ADDR, SRC + 4096);
                lite_write(PATRM_REG_DST_ADDR, DST + 4096);
                lite_write(PATRM_REG_WIDTH, c_W + 8);
                lite_write(PATRM_REG_HEIGHT, c_H + 1);
                lite_write(PATRM_REG_B11, ~c_b[0]);
                lite_write(PATRM_REG_B22, ~c_b[4]);
                lite_write(PATRM_REG_B23, ~c_b[5]);
                lite_write(PATRM_REG_BLOCK_LEN, 1);
                lite_write(PATRM_REG_CTRL, ((c_mode ^ 1) << PATRM_CTRL_MODE_LSB) | C_IRQ);
                lite_write(PATRM_REG_T_B_Y, ~c_t[7]);
                lite_read(PATRM_REG_SRC_ADDR, rv);  chk_eq(rv, SRC, "SRC_ADDR locked while busy");
                lite_read(PATRM_REG_DST_ADDR, rv);  chk_eq(rv, DST, "DST_ADDR locked while busy");
                lite_read(PATRM_REG_WIDTH, rv);     chk_eq(rv, c_W, "WIDTH locked while busy");
                lite_read(PATRM_REG_HEIGHT, rv);    chk_eq(rv, c_H, "HEIGHT locked while busy");
                lite_read(PATRM_REG_B11, rv);       chk_eq(rv, c_b[0], "B11 locked while busy");
                lite_read(PATRM_REG_B22, rv);       chk_eq(rv, c_b[4], "B22 locked while busy");
                lite_read(PATRM_REG_B23, rv);       chk_eq(rv, c_b[5], "B23 locked while busy");
                lite_read(PATRM_REG_BLOCK_LEN, rv); chk_eq(rv, c_L, "BLOCK_LEN locked while busy");
                lite_read(PATRM_REG_T_B_Y, rv);     chk_eq(rv, c_t[7], "T_B_Y locked while busy");
                lite_read(PATRM_REG_CTRL, rv);
                chk_eq(rv, C_IRQ | (c_mode << PATRM_CTRL_MODE_LSB), "CTRL: MODE locked, IRQ_EN stays writable");
                n_lock = n_lock + 1;
            end
            if (c_op == 5) begin                         // START while busy: rejected, the frame continues
                rv2 = sa_count;
                lite_write(PATRM_REG_CTRL, ctrl_v);
                lite_read(PATRM_REG_STATUS, rv);
                chk_eq(rv, S_BUSY | S_ERROR | (PATRM_ERR_START_BUSY << PATRM_STATUS_ERR_CODE_LSB), "START while busy");
                chk_eq(sa_count, rv2, "no second start_accept");
                n_bad_starts = n_bad_starts + 1;
            end
            if (c_op == 4) begin                         // aresetn in the middle of the frame
                while (cyc - t_start < c_arg) idle(1);
                $display("  g %0s %0dx%0d: aresetn %0d cycles after START (%0d R beats, %0d W beats so far)", c_name,
                         c_W, c_H, cyc - t_start, u_mem.rbeats - r0, u_mem.wbeats - w0);
                reset_engine;
                n_resets = n_resets + 1;
            end else begin
                // ---- wait for the end of the frame ----
                limit = 200 * npix + 200000;
                t_wait = cyc;
                if (c_irq) begin
                    while (interrupt !== 1'b1) begin
                        if (cyc - t_wait > limit) timeout;
                        idle(1);
                    end
                end else begin                           // polling
                    rv = S_BUSY; poll = 0;
                    while (!(rv & S_DONE)) begin
                        if (cyc - t_wait > limit) timeout;
                        lite_read(PATRM_REG_STATUS, rv);
                        if (!(rv & S_DONE)) chk_eq(rv & S_BUSY, S_BUSY, "BUSY while polling");
                        poll = poll + 1;
                    end
                    n_poll = n_poll + 1;
                end

                // ---- output in memory, at once ----
                check_memory;
                chk_eq(u_mem.log_n - ar0, c_rb, "AR bursts vs memmodel");
                chk_eq(u_mem.wlog_n - aw0, c_wb, "AW bursts vs memmodel");
                chk_eq(u_mem.bcount - b0, c_wb, "B responses at DONE");
                chk_eq(fs_count - fs0, (c_mode == 1) ? 4 : 1, "frame_start pulses (passes) of the job");
                n_frames[c_group] = n_frames[c_group] + 1;
                n_bytes[c_group]  = n_bytes[c_group] + npix;

                // ---- STATUS ----
                st_exp = S_DONE;
                if (c_op == 2 || c_op == 3) begin
                    st_exp = S_DONE | S_ERROR | (PATRM_ERR_BUS_ERROR << PATRM_STATUS_ERR_CODE_LSB);
                    n_buserr = n_buserr + 1;
                end
                if (c_op == 5) st_exp = S_DONE | S_ERROR | (PATRM_ERR_START_BUSY << PATRM_STATUS_ERR_CODE_LSB);
                idle(1);                                 // the monitor has seen DONE at this edge
                lite_read(PATRM_REG_STATUS, rv);
                chk_eq(rv, st_exp, "STATUS after the frame");
                chk(done_seen === 1'b1, "DONE seen by the monitor");
                if (c_irq) begin
                    chk(interrupt === 1'b1, "interrupt high until W1C");
                    chk_eq(t_irq, t_done, "cycle of the interrupt vs DONE");
                end else chk(interrupt === 1'b0, "no interrupt with IRQ_EN = 0");

                // ---- counters (group e) ----
                lite_read(PATRM_REG_CYCLES, rv);
                cycles = rv;
                chk_eq(rv, t_done - t_start - 2, "CYCLES vs START to DONE");
                lite_read(PATRM_REG_BYTES_RD, rv);
                chk_eq(rv, c_bytes, "BYTES_RD vs memmodel");
                chk_eq(rv, 8 * (u_mem.rbeats - r0), "BYTES_RD vs R handshakes");
                lite_read(PATRM_REG_BYTES_WR, rv);
                chk_eq(rv, wfac * npix, "BYTES_WR vs W x H (x 2 in MODE 1)");
                chk_eq(rv, 8 * (u_mem.wbeats - w0), "BYTES_WR vs W handshakes");
                lite_read(PATRM_REG_RD_STALL, rv);
                chk_eq(rv, rs_tb, "RD_STALL vs own count");
                lite_read(PATRM_REG_WR_STALL, rv2);
                chk_eq(rv2, ws_tb, "WR_STALL vs own count");
                chk(rv + rv2 <= cycles, "RD_STALL + WR_STALL <= CYCLES");
                n_counter_frames = n_counter_frames + 1;
                if (rv != 0)  n_rs_frames = n_rs_frames + 1;
                if (rv2 != 0) n_ws_frames = n_ws_frames + 1;
                ppc = (1.0 * npix) / cycles;
                $display("  %c %0s %0s %0dx%0d L%0d op %0d mem %0d-%0d bp %0d/%0d/%0d/%0d B %0d-%0d: CYCLES %0d, %0.3f px/clk, BYTES_RD %0d, RD_STALL %0d, WR_STALL %0d",
                         grp_letter(c_group), (c_mode == 1) ? "A" : "gray", c_name, c_W, c_H, c_L, c_op, c_lat0, c_lat1, c_arbp, c_rgap, c_awbp,
                         c_wbp, c_blat0, c_blat1, cycles, ppc, c_bytes, rv, rv2);
                if (c_group == 7)
                    $display("SPEED %0s %0s %0dx%0d latency %0d: CYCLES %0d, %0.3f px/clk, RD_STALL %0d, WR_STALL %0d",
                             (c_mode == 1) ? "A" : "gray", c_name, c_W, c_H, c_lat0, cycles, ppc, rv, rv2);

                // ---- clear DONE / ERROR ----
                if (c_op == 1) begin
                    lite_write(PATRM_REG_STATUS, 32'd0);
                    lite_read(PATRM_REG_STATUS, rv);
                    chk_eq(rv, S_DONE, "writing 0 to STATUS changes nothing");
                    chk(interrupt === 1'b1, "interrupt still high after writing 0");
                    lite_write(PATRM_REG_STATUS, S_DONE);
                    chk(interrupt === 1'b0, "W1C DONE clears the interrupt");
                end
                if (c_op == 2 || c_op == 3) begin
                    lite_write(PATRM_REG_STATUS, S_DONE);
                    if (c_irq) chk(interrupt === 1'b0, "W1C DONE clears the interrupt (bus error frame)");
                    lite_read(PATRM_REG_STATUS, rv);
                    chk_eq(rv, S_ERROR | (PATRM_ERR_BUS_ERROR << PATRM_STATUS_ERR_CODE_LSB), "ERROR sticky after W1C DONE");
                end
                lite_write(PATRM_REG_STATUS, S_DONE | S_ERROR);
                chk(interrupt === 1'b0, "interrupt low after clearing DONE");
                lite_read(PATRM_REG_STATUS, rv);
                chk_eq(rv, 0, "STATUS after W1C");
                chk_eq(u_mem.rbeats - r0, c_bytes / 8, "no R beat after DONE");
                chk_eq(u_mem.wbeats - w0, wfac * npix / 8, "no W beat after DONE");
                chk_eq(u_mem.log_n - ar0, c_rb, "no AR after DONE");
                chk_eq(u_mem.wlog_n - aw0, c_wb, "no AW after DONE");
                in_frame = 1'b0;
            end
            u_mem.err_burst = -1;
            u_mem.b_err_burst = -1;
        end
    endtask

    task timeout;
        begin
            $sformat(msgbuf, "(%c) %0s %0dx%0d L%0d: frame did not finish in %0d cycles (busy %b, output handshakes %0d words)",
                     grp_letter(c_group), c_name, c_W, c_H, c_L, limit, dut.busy, u_mem.wbeats - w0);
            fatal(msgbuf);
        end
    endtask

    // ---------------- rejected starts (group c) ----------------
    integer s_r0, s_w0, s_a0, s_w1, s_fs;

    task bad_start;                                      // CTRL write must be rejected with code `code`
        input [31:0] ctrl;
        input [3:0]  code;
        input [8*40-1:0] what;
        begin
            s_r0 = u_mem.rbeats; s_w0 = u_mem.wbeats; s_a0 = u_mem.log_n; s_w1 = u_mem.wlog_n; s_fs = fs_count;
            lite_write(PATRM_REG_CTRL, ctrl | C_START | C_IRQ);
            lite_read(PATRM_REG_STATUS, rv);
            $sformat(msgbuf, "%0s: STATUS", what);
            chk_eq(rv, S_ERROR | (code << PATRM_STATUS_ERR_CODE_LSB), msgbuf);
            idle(64);
            $sformat(msgbuf, "%0s: frame_start pulses", what);
            chk_eq(fs_count, s_fs, msgbuf);
            chk(dut.busy === 1'b0, "busy = 0 after a rejected start");
            chk(interrupt === 1'b0, "no interrupt after a rejected start");
            chk_eq(u_mem.rbeats, s_r0, "no R beat after a rejected start");
            chk_eq(u_mem.wbeats, s_w0, "no W beat after a rejected start");
            chk_eq(u_mem.log_n, s_a0, "no AR after a rejected start");
            chk_eq(u_mem.wlog_n, s_w1, "no AW after a rejected start");
            lite_write(PATRM_REG_STATUS, S_ERROR);
            lite_read(PATRM_REG_STATUS, rv);
            chk_eq(rv, 0, "W1C ERROR after a rejected start");
            n_bad_starts = n_bad_starts + 1;
        end
    endtask

    task bad_starts;
        integer q, bad;
        begin
            load_case;
            program_regs;
            lite_write(PATRM_REG_WIDTH, 0);      bad_start(0, PATRM_ERR_BAD_SIZE, "W = 0");
            lite_write(PATRM_REG_WIDTH, 100);    bad_start(0, PATRM_ERR_BAD_SIZE, "W not a multiple of 8");
            lite_write(PATRM_REG_WIDTH, 4104);   bad_start(0, PATRM_ERR_BAD_SIZE, "W = 4104");
            lite_write(PATRM_REG_WIDTH, c_W);
            lite_write(PATRM_REG_HEIGHT, 0);     bad_start(0, PATRM_ERR_BAD_SIZE, "H = 0");
            lite_write(PATRM_REG_HEIGHT, 4097);  bad_start(0, PATRM_ERR_BAD_SIZE, "H = 4097");
            lite_write(PATRM_REG_HEIGHT, c_H);
`ifdef TB_BAYER_A
            // Option A build: MODE 1 is accepted only with the Bayer size rules (D3: W multiple of 16, H even)
            lite_write(PATRM_REG_WIDTH, c_W - 8);
            bad_start(PATRM_MODE_BAYER_A << PATRM_CTRL_MODE_LSB, PATRM_ERR_BAD_SIZE, "MODE 1, W not a multiple of 16");
            lite_write(PATRM_REG_WIDTH, c_W);
            lite_write(PATRM_REG_HEIGHT, c_H - 1);
            bad_start(PATRM_MODE_BAYER_A << PATRM_CTRL_MODE_LSB, PATRM_ERR_BAD_SIZE, "MODE 1, H odd");
            lite_write(PATRM_REG_HEIGHT, c_H);
            bad_start(PATRM_MODE_BAYER_B << PATRM_CTRL_MODE_LSB, PATRM_ERR_BAD_MODE, "MODE 2 in the Option A build");
`else
            bad_start(PATRM_MODE_BAYER_A << PATRM_CTRL_MODE_LSB, PATRM_ERR_BAD_MODE, "MODE 1 in the gray build");
            bad_start(PATRM_MODE_BAYER_B << PATRM_CTRL_MODE_LSB, PATRM_ERR_BAD_MODE, "MODE 2 in the gray build");
`endif
            bad_start(3 << PATRM_CTRL_MODE_LSB, PATRM_ERR_BAD_MODE, "MODE 3");
            lite_write(PATRM_REG_SRC_ADDR, SRC + 8);   bad_start(0, PATRM_ERR_BAD_ADDR, "SRC_ADDR not 4 KB aligned");
            lite_write(PATRM_REG_SRC_ADDR, SRC);
            lite_write(PATRM_REG_DST_ADDR, DST + 2048); bad_start(0, PATRM_ERR_BAD_ADDR, "DST_ADDR not 4 KB aligned");
            lite_write(PATRM_REG_DST_ADDR, DST);
            lite_write(PATRM_REG_BLOCK_LEN, 0);  bad_start(0, PATRM_ERR_BAD_BLOCK_LEN, "BLOCK_LEN 0");
            lite_write(PATRM_REG_BLOCK_LEN, 65); bad_start(0, PATRM_ERR_BAD_BLOCK_LEN, "BLOCK_LEN 65");
            lite_write(PATRM_REG_BLOCK_LEN, c_L);
            lite_write(PATRM_REG_CTRL, 32'd0);
            // the output area still holds only the marker
            bad = 0;
            for (q = D0 - GUARD; q < D0 + nwords + GUARD; q = q + 1)
                if (u_mem.mem[q] !== mark_of(q)) bad = bad + 1;
            chk_eq(bad, 0, "output area written by a rejected start");
            $display("  c %0d rejected starts checked", n_bad_starts);
        end
    endtask

    // ---------------- main ----------------
    integer i, tot_f, tot_b;

    initial begin
        npix = 0; c_group = 0; c_irq = 1; c_W = 0; c_H = 0; c_L = 0; c_name = "init"; c_mode = 0; wfac = 1;
        for (i = 0; i < NGRP; i = i + 1) begin n_frames[i] = 0; n_bytes[i] = 0; end
        if (!$value$plusargs("VEC_DIR=%s", vecdir)) vecdir = "../../../data/vectors";
`ifdef TB_BAYER_A
        $sformat(path, "%0s/patrm_top/cases_bayer_a.txt", vecdir);
`else
        $sformat(path, "%0s/patrm_top/cases.txt", vecdir);
`endif
        fd_cases = $fopen(path, "r");
        if (fd_cases == 0) begin
            $sformat(msgbuf, "cannot open %0s (run python scripts/gen_patrm_top_vectors.py, or pass +VEC_DIR)", path);
            fatal(msgbuf);
        end
        skip_comments(fd_cases);

        idle(RST_CYC);
        aresetn = 1'b1;
        idle(2);
        c_group = 1;
        lite_read(PATRM_REG_BUILD_ID, rv);
        chk_eq(rv, BUILD_ID_EXP, "BUILD_ID (VERSION 1, BUILD_TYPE, MODES, BLOCK_LEN_MAX 64)");
        lite_read(PATRM_REG_STATUS, rv);
        chk_eq(rv, 0, "STATUS after reset");

        read_case;
        while (have_case && nfail == 0) begin
            if (c_op == 6) bad_starts;
            else           run_frame;
            read_case;
        end

        idle(10);
        tot_f = 0; tot_b = 0;
        $display("compared per group (frames / output bytes):");
        for (i = 0; i < NGRP; i = i + 1) if (i != 4) begin
            $display("  %c %0d / %0d", grp_letter(i), n_frames[i], n_bytes[i]);
            tot_f = tot_f + n_frames[i];
            tot_b = tot_b + n_bytes[i];
        end
        $display("  total %0d frames, %0d output bytes compared with the model", tot_f, tot_b);
        $display("  b: %0d lock / W1C frames, %0d polled frames; c: %0d rejected starts; d: %0d bus-error frames; e: counters checked in %0d frames (RD_STALL != 0 in %0d, WR_STALL != 0 in %0d); g: %0d resets",
                 n_lock, n_poll, n_bad_starts, n_buserr, n_counter_frames, n_rs_frames, n_ws_frames, n_resets);
        // a complete run must have exercised both stall counters
        if (nfail == 0 && !have_case && (n_rs_frames == 0 || n_ws_frames == 0))
            record_fail("the run never produced a non-zero RD_STALL and WR_STALL");
        u_mem.report;
        $display("errors: checks %0d, unused HP channels %0d, AR outside source %0d, AW outside output %0d, WSTRB %0d, interrupt with IRQ_EN = 0 %0d, AXI %0d",
                 nfail, tie_err, ar_err, aw_err, strb_err, irq_err, u_mem.viol_total);
        if (nfail == 0 && tie_err != 0) first_fail = "unused HP channels not at their constants";
        if (nfail == 0 && ar_err != 0)  first_fail = "AR burst outside the source image";
        if (nfail == 0 && aw_err != 0)  first_fail = "AW burst outside the output image";
        if (nfail == 0 && strb_err != 0) first_fail = "WSTRB not 8'hFF (gray) / 8'h55, 8'hAA (Option A pass)";
        if (nfail == 0 && irq_err != 0) first_fail = "interrupt with IRQ_EN = 0";
        if (nfail == 0 && u_mem.viol_total != 0) first_fail = "AXI protocol violations (axi_mem checker)";
        if (nfail == 0 && tie_err == 0 && ar_err == 0 && aw_err == 0 && strb_err == 0 && irq_err == 0 &&
            u_mem.viol_total == 0)
            $display("TEST PASS");
        else
            $display("TEST FAIL: %0d check errors, first: %0s", nfail, first_fail);
        $finish;
    end

endmodule
