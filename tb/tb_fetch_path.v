// Self-checking testbench for the read path of step 3.6b:
//   block_planner -> coord_gen + prefetch_ctrl -> axi_rd_master -> tb/axi_mem.v -> line_buf -> pixel_fetch
//   -> bilinear_interp
//
// Needs the model vectors (data/vectors/, not tracked). Run from the repo root:
//   python scripts/gen_fetch_path_vectors.py
//   python scripts/sim.py --top tb_fetch_path -f tb/fetch_path.f --plusarg VEC_DIR=data/vectors
// +VEC_DIR=<folder> is the vector folder (default ../../../data/vectors). The case list is
// <VEC_DIR>/fetch_path/cases.txt (format: scripts/gen_fetch_path_vectors.py). Nothing else is hard-coded.
//
// Two block_planner instances (SPAN_MAX 512 and 32, as tb_block_planner); a case uses the one of its S column,
// the other one gets ready = 0. Everything after the planner is one chain.
// Checks (every case, every cycle):
//   commands       each command of prefetch_ctrl equals the next row fetch of the fetch records, computed here:
//                  addr = SRC + row * W + s_col, words, slot; rows with fetch = 0 issue nothing
//   buffer writes  every line_buf write one cycle after its beat: bank / entry by source column (spec 6.2 option A:
//                  slot word (s_col / 8 + beat) mod 64) and the data = the source image word (own copy of the file)
//   slot reuse     a write into a slot is allowed only after every earlier fetching block using that slot has done
//                  its last line_buf read (pixel_fetch F1 -> F2 of its last pixel): catches PATRM_FAULT_SLOT_EARLY
//   aliasing       a write into a slot word that still holds a different (row, column word) needed by a block not
//                  yet read out is an error (option A: at most 64 words per slot)
//   pixel stream   at pixel_fetch's output (ip handshake): valid, x0, y0 (F3 registers inside pixel_fetch), xf, yf,
//                  r1..r4 == the model dump, ip_last on the last pixel only; count == W x H
//   output         at bilinear_interp's output: op_d == the model frame (exp_*.hex), op_last; group b also against
//                  the source image itself (identity / mirror_cols / mirror_rows)
//   BYTES_RD       8 x rd_beat of the frame == memmodel prediction (group c; every complete frame)
//   RD_STALL       pixel_fetch rd_stall == own count per spec 13 (F1 holds a pixel of fetching block k with
//                  k >= blocks_ready and bilinear_interp has no WR_STALL), every cycle (group e)
//   AXI            tb/axi_mem.v protocol checker: 0 violations
// Groups (scripts/gen_fetch_path_vectors.py): a 0, b 1, d 3, f 5, g 6; c and e are the BYTES_RD / RD_STALL checks
// of every case. Option: --define TB_SLOT_BITS=4 runs everything with NSLOT = 16 (default 32).
// Prints one line per case and exactly one final line: "TEST PASS" or "TEST FAIL: <reason>".
`timescale 1ns/1ps
module tb_fetch_path;

    localparam CLK_HALF  = 5;                            // 100 MHz
    localparam SIZE_BITS = 13;
    localparam CNT_BITS  = 7;
`ifdef TB_SLOT_BITS
    localparam SLOT_BITS = `TB_SLOT_BITS;              // --define TB_SLOT_BITS=4: NSLOT = 16 (Q2 data, step 3.6c)
`else
    localparam SLOT_BITS = 5;                            // NSLOT = 32 (build value)
`endif
    localparam WORD_BITS = 6;
    localparam NSLOT     = 1 << SLOT_BITS;
    localparam SW        = 64;                           // slot words
    localparam AW        = SLOT_BITS + 5;                // line_buf entry address: slot, word[5:1]
    localparam [31:0] SRC = 32'h1000_0000;
    localparam MEM_WORDS = 8192;                          // 64 KB source window
    localparam MAXP      = 256 * 192;
    localparam CQ        = 256;                           // expected-command ring
    localparam IQ        = 64;                            // commands in flight ring
    localparam STR       = 8 * 400;
    localparam NGRP      = 7;
    localparam RST_CYC   = 16;
    localparam DRAIN     = 40;
    localparam MAX_PRINT = 20;

`ifdef ALT_SEED
    integer seed = 17;
`else
    integer seed = 3602;
`endif

    // ---------------- clock, reset, configuration ----------------
    reg aclk = 1'b0;
    reg aresetn = 1'b0;
    always #CLK_HALF aclk = ~aclk;

    reg                 frame_start = 1'b0;
    reg [SIZE_BITS-1:0] cfg_width = 0, cfg_height = 0, cfg_block_len = 0;
    reg [31:0]          cfg_b11 = 0, cfg_b12 = 0, cfg_b13 = 0, cfg_b21 = 0, cfg_b22 = 0, cfg_b23 = 0;
    reg [31:0]          cfg_src = 0;
    reg                 sel32 = 1'b0;
    reg                 op_ready = 1'b1;

    // ---------------- planners ----------------
    wire                 desc_ready, fetch_ready;
    wire                 a_dv, a_fv, b_dv, b_fv;
    wire [SIZE_BITS-1:0] a_du, a_dv0, a_dsc, a_frt, a_frb, a_fsc, b_du, b_dv0, b_dsc, b_frt, b_frb, b_fsc;
    wire [CNT_BITS-1:0]  a_dn, a_fw, b_dn, b_fw;
    wire [1:0]           a_dnr, b_dnr;
    wire [SLOT_BITS-1:0] a_dst, a_dsb, a_fst, a_fsb, b_dst, b_dsb, b_fst, b_fsb;
    wire                 a_dl, a_ft, a_fb, b_dl, b_ft, b_fb;

    block_planner #(.SLOT_BITS(SLOT_BITS), .SPAN_MAX(512)) u_pa (
        .aclk(aclk), .aresetn(aresetn), .frame_start(frame_start),
        .cfg_width(cfg_width), .cfg_height(cfg_height), .cfg_block_len(cfg_block_len),
        .cfg_b11(cfg_b11), .cfg_b12(cfg_b12), .cfg_b13(cfg_b13), .cfg_b21(cfg_b21), .cfg_b22(cfg_b22), .cfg_b23(cfg_b23),
        .desc_valid(a_dv), .desc_ready(desc_ready && !sel32), .desc_u(a_du), .desc_v0(a_dv0), .desc_n(a_dn),
        .desc_nrows(a_dnr), .desc_slot_top(a_dst), .desc_slot_bot(a_dsb), .desc_s_col(a_dsc), .desc_last(a_dl),
        .fetch_valid(a_fv), .fetch_ready(fetch_ready && !sel32), .fetch_row_top(a_frt), .fetch_row_bot(a_frb),
        .fetch_slot_top(a_fst), .fetch_slot_bot(a_fsb), .fetch_top(a_ft), .fetch_bot(a_fb), .fetch_s_col(a_fsc),
        .fetch_words(a_fw));
    block_planner #(.SLOT_BITS(SLOT_BITS), .SPAN_MAX(32)) u_pb (
        .aclk(aclk), .aresetn(aresetn), .frame_start(frame_start),
        .cfg_width(cfg_width), .cfg_height(cfg_height), .cfg_block_len(cfg_block_len),
        .cfg_b11(cfg_b11), .cfg_b12(cfg_b12), .cfg_b13(cfg_b13), .cfg_b21(cfg_b21), .cfg_b22(cfg_b22), .cfg_b23(cfg_b23),
        .desc_valid(b_dv), .desc_ready(desc_ready && sel32), .desc_u(b_du), .desc_v0(b_dv0), .desc_n(b_dn),
        .desc_nrows(b_dnr), .desc_slot_top(b_dst), .desc_slot_bot(b_dsb), .desc_s_col(b_dsc), .desc_last(b_dl),
        .fetch_valid(b_fv), .fetch_ready(fetch_ready && sel32), .fetch_row_top(b_frt), .fetch_row_bot(b_frb),
        .fetch_slot_top(b_fst), .fetch_slot_bot(b_fsb), .fetch_top(b_ft), .fetch_bot(b_fb), .fetch_s_col(b_fsc),
        .fetch_words(b_fw));

    wire                 dv   = sel32 ? b_dv  : a_dv;
    wire [SIZE_BITS-1:0] du   = sel32 ? b_du  : a_du;
    wire [SIZE_BITS-1:0] dv0  = sel32 ? b_dv0 : a_dv0;
    wire [CNT_BITS-1:0]  dn   = sel32 ? b_dn  : a_dn;
    wire [1:0]           dnr  = sel32 ? b_dnr : a_dnr;
    wire [SLOT_BITS-1:0] dst  = sel32 ? b_dst : a_dst;
    wire [SLOT_BITS-1:0] dsb  = sel32 ? b_dsb : a_dsb;
    wire [SIZE_BITS-1:0] dsc  = sel32 ? b_dsc : a_dsc;
    wire                 dl   = sel32 ? b_dl  : a_dl;
    wire                 fv   = sel32 ? b_fv  : a_fv;
    wire [SIZE_BITS-1:0] frt  = sel32 ? b_frt : a_frt;
    wire [SIZE_BITS-1:0] frb  = sel32 ? b_frb : a_frb;
    wire [SLOT_BITS-1:0] fst  = sel32 ? b_fst : a_fst;
    wire [SLOT_BITS-1:0] fsb  = sel32 ? b_fsb : a_fsb;
    wire                 ft   = sel32 ? b_ft  : a_ft;
    wire                 fb   = sel32 ? b_fb  : a_fb;
    wire [SIZE_BITS-1:0] fsc  = sel32 ? b_fsc : a_fsc;
    wire [CNT_BITS-1:0]  fw   = sel32 ? b_fw  : a_fw;

    // ---------------- coord_gen ----------------
    wire                 pix_valid, pix_ready, pix_first, pix_last, pix_frame_last;
    wire signed [31:0]   pix_X, pix_Y;
    wire [1:0]           pix_nrows;
    wire [SLOT_BITS-1:0] pix_st, pix_sb;
    wire [SIZE_BITS-1:0] pix_sc;
    coord_gen #(.SLOT_BITS(SLOT_BITS)) u_cg (
        .aclk(aclk), .aresetn(aresetn), .frame_start(frame_start),
        .cfg_b11(cfg_b11), .cfg_b12(cfg_b12), .cfg_b13(cfg_b13), .cfg_b21(cfg_b21), .cfg_b22(cfg_b22), .cfg_b23(cfg_b23),
        .desc_valid(dv), .desc_ready(desc_ready), .desc_u(du), .desc_v0(dv0), .desc_n(dn), .desc_nrows(dnr),
        .desc_slot_top(dst), .desc_slot_bot(dsb), .desc_s_col(dsc), .desc_last(dl),
        .pix_valid(pix_valid), .pix_ready(pix_ready), .pix_X(pix_X), .pix_Y(pix_Y), .pix_first(pix_first),
        .pix_last(pix_last), .pix_nrows(pix_nrows), .pix_slot_top(pix_st), .pix_slot_bot(pix_sb), .pix_s_col(pix_sc),
        .pix_frame_last(pix_frame_last));

    // ---------------- prefetch_ctrl, axi_rd_master, memory ----------------
    wire                 cmd_valid, cmd_ready;
    wire [31:0]          cmd_addr;
    wire [CNT_BITS-1:0]  cmd_words;
    wire [SLOT_BITS-1:0] cmd_slot;
    wire                 rd_valid, rd_cmd_last, rd_beat, rd_err;
    wire [63:0]          rd_data;
    wire [SLOT_BITS-1:0] rd_slot;
    wire [WORD_BITS-1:0] rd_word;
    wire                 buf_we, buf_wbank, buf_re;
    wire [AW-1:0]        buf_waddr, raddr_te, raddr_to, raddr_be, raddr_bo;
    wire [63:0]          buf_wdata, rdata_te, rdata_to, rdata_be, rdata_bo;
    wire [15:0]          blocks_ready;
    wire                 blk_done;

    prefetch_ctrl #(.SLOT_BITS(SLOT_BITS)) u_pc (
        .aclk(aclk), .aresetn(aresetn), .frame_start(frame_start), .cfg_src_addr(cfg_src), .cfg_width(cfg_width),
        .fetch_valid(fv), .fetch_ready(fetch_ready), .fetch_row_top(frt), .fetch_row_bot(frb),
        .fetch_slot_top(fst), .fetch_slot_bot(fsb), .fetch_top(ft), .fetch_bot(fb), .fetch_s_col(fsc),
        .fetch_words(fw),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_addr(cmd_addr), .cmd_words(cmd_words), .cmd_slot(cmd_slot),
        .rd_valid(rd_valid), .rd_data(rd_data), .rd_slot(rd_slot), .rd_word(rd_word), .rd_cmd_last(rd_cmd_last),
        .buf_we(buf_we), .buf_wbank(buf_wbank), .buf_waddr(buf_waddr), .buf_wdata(buf_wdata),
        .blocks_ready(blocks_ready), .blk_done(blk_done));

    wire [5:0]  arid, rid;
    wire [31:0] araddr;
    wire [3:0]  arlen, arcache, arqos;
    wire [2:0]  arsize, arprot;
    wire [1:0]  arburst, arlock, rresp;
    wire        arvalid, arready, rlast, rvalid, rready;
    wire [63:0] rdata;
    axi_rd_master #(.SLOT_W(SLOT_BITS)) u_rd (
        .aclk(aclk), .aresetn(aresetn),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_addr(cmd_addr), .cmd_words(cmd_words), .cmd_slot(cmd_slot),
        .m_axi_hp0_arid(arid), .m_axi_hp0_araddr(araddr), .m_axi_hp0_arlen(arlen), .m_axi_hp0_arsize(arsize),
        .m_axi_hp0_arburst(arburst), .m_axi_hp0_arlock(arlock), .m_axi_hp0_arcache(arcache),
        .m_axi_hp0_arprot(arprot), .m_axi_hp0_arqos(arqos), .m_axi_hp0_arvalid(arvalid),
        .m_axi_hp0_arready(arready), .m_axi_hp0_rid(rid), .m_axi_hp0_rdata(rdata), .m_axi_hp0_rresp(rresp),
        .m_axi_hp0_rlast(rlast), .m_axi_hp0_rvalid(rvalid), .m_axi_hp0_rready(rready),
        .rd_valid(rd_valid), .rd_data(rd_data), .rd_slot(rd_slot), .rd_word(rd_word), .rd_cmd_last(rd_cmd_last),
        .rd_beat(rd_beat), .rd_err(rd_err));

    wire       awready_nc, wready_nc, bvalid_nc;
    wire [5:0] bid_nc;
    wire [1:0] bresp_nc;
    axi_mem #(.BASE(SRC), .MEM_WORDS(MEM_WORDS), .LAT_MIN(20), .LAT_MAX(20)) u_mem (
        .aclk(aclk), .aresetn(aresetn),
        .s_arid(arid), .s_araddr(araddr), .s_arlen({4'd0, arlen}), .s_arsize(arsize), .s_arburst(arburst),
        .s_arvalid(arvalid), .s_arready(arready),
        .s_rid(rid), .s_rdata(rdata), .s_rresp(rresp), .s_rlast(rlast), .s_rvalid(rvalid), .s_rready(rready),
        .s_awid(6'd0), .s_awaddr(32'd0), .s_awlen(8'd0), .s_awsize(3'd3), .s_awburst(2'b01), .s_awvalid(1'b0),
        .s_awready(awready_nc), .s_wid(6'd0), .s_wdata(64'd0), .s_wstrb(8'd0), .s_wlast(1'b0), .s_wvalid(1'b0),
        .s_wready(wready_nc), .s_bid(bid_nc), .s_bresp(bresp_nc), .s_bvalid(bvalid_nc), .s_bready(1'b1));

    // ---------------- line_buf, pixel_fetch, bilinear_interp ----------------
    line_buf #(.NSLOT(NSLOT), .AW(AW)) u_lb (
        .aclk(aclk), .we(buf_we), .wbank(buf_wbank), .waddr(buf_waddr), .wdata(buf_wdata),
        .re(buf_re), .raddr_te(raddr_te), .raddr_to(raddr_to), .raddr_be(raddr_be), .raddr_bo(raddr_bo),
        .rdata_te(rdata_te), .rdata_to(rdata_to), .rdata_be(rdata_be), .rdata_bo(rdata_bo));

    wire        ip_valid, ip_ready, ip_ok, ip_last, rd_stall;
    wire [15:0] ip_xf, ip_yf;
    wire [7:0]  ip_r1, ip_r2, ip_r3, ip_r4;
    pixel_fetch #(.SLOT_BITS(SLOT_BITS)) u_pf (
        .aclk(aclk), .aresetn(aresetn), .frame_start(frame_start), .cfg_width(cfg_width), .cfg_height(cfg_height),
        .pix_valid(pix_valid), .pix_ready(pix_ready), .pix_X(pix_X), .pix_Y(pix_Y), .pix_first(pix_first),
        .pix_last(pix_last), .pix_nrows(pix_nrows), .pix_slot_top(pix_st), .pix_slot_bot(pix_sb),
        .pix_s_col(pix_sc), .pix_frame_last(pix_frame_last),
        .blocks_ready(blocks_ready), .blk_done(blk_done),
        .buf_re(buf_re), .buf_raddr_te(raddr_te), .buf_raddr_to(raddr_to), .buf_raddr_be(raddr_be),
        .buf_raddr_bo(raddr_bo), .buf_rdata_te(rdata_te), .buf_rdata_to(rdata_to), .buf_rdata_be(rdata_be),
        .buf_rdata_bo(rdata_bo),
        .ip_valid(ip_valid), .ip_ready(ip_ready), .ip_xf(ip_xf), .ip_yf(ip_yf), .ip_r1(ip_r1), .ip_r2(ip_r2),
        .ip_r3(ip_r3), .ip_r4(ip_r4), .ip_ok(ip_ok), .ip_last(ip_last), .rd_stall(rd_stall));

    wire       op_valid, op_last, wr_stall;
    wire [7:0] op_d;
    bilinear_interp u_bi (
        .aclk(aclk), .aresetn(aresetn),
        .ip_valid(ip_valid), .ip_ready(ip_ready), .ip_xf(ip_xf), .ip_yf(ip_yf), .ip_r1(ip_r1), .ip_r2(ip_r2),
        .ip_r3(ip_r3), .ip_r4(ip_r4), .ip_ok(ip_ok), .ip_last(ip_last),
        .op_valid(op_valid), .op_ready(op_ready), .op_d(op_d), .op_last(op_last), .wr_stall(wr_stall));

    // ---------------- case data ----------------
    reg [103:0] dmp  [0:MAXP-1];                         // {valid, x0, y0, xf, yf, r1, r2, r3, r4}
    reg [63:0]  expw [0:MAXP/8-1];
    reg [63:0]  srcw [0:MEM_WORDS-1];                    // own copy of the source image

    reg [STR-1:0] vecdir, path, c_name, c_src, c_dump, c_exp, junk, msgbuf, first_fail;
    integer c_group, c_W, c_H, c_L, c_S, c_lat0, c_lat1, c_arbp, c_rgap, c_opbp, c_seed, c_abort, c_abort_at;
    integer c_check, c_bytes, c_est, c_bursts;
    integer c_b [0:5];
    integer fd_cases, r, i;
    integer npix;

    integer nfail = 0;
    integer n_cases [0:NGRP-1], n_err [0:NGRP-1], n_pix [0:NGRP-1], n_out [0:NGRP-1], n_wbytes [0:NGRP-1];
    integer n_cmd [0:NGRP-1];
    integer mm_cmd = 0, mm_wr = 0, mm_slot = 0, mm_alias = 0, mm_pix = 0, mm_out = 0, mm_src = 0, mm_bytes = 0;
    integer mm_stall = 0, mm_count = 0, mm_extra = 0, mm_flag = 0;
    integer bytes_ok_cases = 0, n_frames = 0;

    task record_fail;
        input [STR-1:0] m;
        begin
            if (nfail == 0) first_fail = m;
            nfail = nfail + 1;
            n_err[c_group] = n_err[c_group] + 1;
            if (nfail <= MAX_PRINT) $display("  FAIL %0s", m);
        end
    endtask

    task fatal;
        input [STR-1:0] m;
        begin
            $display("TEST FAIL: %0s", m);
            $finish;
        end
    endtask

    function integer rnd;
        input integer n;
        begin
            rnd = ($random(seed) & 32'h7FFF_FFFF) % n;
        end
    endfunction

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

    // ---------------- monitor state (one frame) ----------------
    reg     cmp_en = 1'b0;                               // compare events (0 while an aborted frame drains)
    reg     in_frame = 1'b0;
    integer pidx, oidx, skip_old, bi_inflight;
    integer fr_j, tb_done, k_in, f1_k, f1_nr;
    integer lu [0:NSLOT-1];                              // last fetching block using the slot (-1 none)
    // per slot word: (row, column word) held, last block needing it, pending reuse of a word not yet written
    integer cur_tag [0:NSLOT*SW-1], cur_need [0:NSLOT*SW-1], pend_tag [0:NSLOT*SW-1], pend_need [0:NSLOT*SW-1];
    // expected commands
    integer cq_addr [0:CQ-1], cq_words [0:CQ-1], cq_slot [0:CQ-1], cq_j [0:CQ-1], cq_need [0:CQ-1], cq_row [0:CQ-1];
    integer cq_w0 [0:CQ-1];
    integer cq_wr, cq_rd;
    // commands in flight (axi_rd_master)
    integer iq_slot [0:IQ-1], iq_j [0:IQ-1], iq_need [0:IQ-1], iq_row [0:IQ-1], iq_w0 [0:IQ-1], iq_mw [0:IQ-1];
    integer iq_stale [0:IQ-1], iq_beat [0:IQ-1];
    integer iq_wr, iq_rd;
    // expected line_buf write (from the beat of the previous cycle)
    reg     ew_v;
    integer ew_slot, ew_p, ew_tag, ew_j, ew_need, ew_mw;
    reg [63:0] ew_data;
    // counters
    integer beats, rs_dut, rs_tb, cyc, cyc_fs, cyc_last_op, cyc_cmdbp, cyc_slotw, cyc_starve;

    task frame_reset;
        integer q;
        begin
            pidx = 0; oidx = 0; fr_j = 0; tb_done = 0; k_in = 0; f1_k = 0; f1_nr = 0;
            cq_wr = 0; cq_rd = 0;
            beats = 0; rs_dut = 0; rs_tb = 0; cyc_cmdbp = 0; cyc_slotw = 0; cyc_starve = 0;
            for (q = 0; q < NSLOT; q = q + 1) lu[q] = -1;
            for (q = 0; q < NSLOT * SW; q = q + 1) begin
                cur_need[q] = -1; pend_tag[q] = -1; pend_need[q] = -1;
            end
        end
    endtask

    task full_reset;                                     // aresetn: also the memory and the commands in flight
        integer q;
        begin
            frame_reset;
            iq_wr = 0; iq_rd = 0; ew_v = 1'b0; skip_old = 0; bi_inflight = 0;
            for (q = 0; q < NSLOT * SW; q = q + 1) cur_tag[q] = -1;
        end
    endtask

    function [7:0] srcbyte;
        input integer a;
        begin
            srcbyte = srcw[a >> 3][8 * (a & 7) +: 8];
        end
    endfunction

    // ---------------- monitor ----------------
    integer m_row, m_slot, m_w, m_p, m_q, m_tag, m_two, m_k, m_exp, m_u, m_v, m_bi;
    reg [103:0] m_d;
    reg [7:0]   m_srcb;
    reg         m_tbstall;

    always @(posedge aclk) begin
        cyc = cyc + 1;
        if (aresetn && in_frame) begin
            // ---- line_buf write expected from the beat of the previous cycle
            if (ew_v !== buf_we) begin
                if (cmp_en) begin
                    mm_wr = mm_wr + 1;
                    $sformat(msgbuf, "%0s %0dx%0d: buf_we %b, expected %b", c_name, c_W, c_H, buf_we, ew_v);
                    record_fail(msgbuf);
                end
            end else if (ew_v) begin
                m_q = ew_slot * SW + ew_p;
                if (cmp_en && (buf_wbank !== ew_p[0] || buf_waddr !== ew_slot * (SW / 2) + (ew_p >> 1) ||
                               buf_wdata !== ew_data)) begin
                    mm_wr = mm_wr + 1;
                    $sformat(msgbuf, "%0s %0dx%0d block %0d: write bank %0d entry %0d data %h, expected bank %0d entry %0d data %h",
                             c_name, c_W, c_H, ew_j, buf_wbank, buf_waddr, buf_wdata, ew_p[0],
                             ew_slot * (SW / 2) + (ew_p >> 1), ew_data);
                    record_fail(msgbuf);
                end
                // slot reuse: every earlier block using this slot must have done its last read
                if (cmp_en && ew_need >= tb_done) begin
                    mm_slot = mm_slot + 1;
                    $sformat(msgbuf, "%0s %0dx%0d: block %0d writes slot %0d while block %0d (still in use, %0d blocks read out) needs it",
                             c_name, c_W, c_H, ew_j, ew_slot, ew_need, tb_done);
                    record_fail(msgbuf);
                end
                // aliasing: the word holds another (row, column word) still needed
                if (cmp_en && cur_tag[m_q] != ew_tag && cur_need[m_q] >= tb_done) begin
                    mm_alias = mm_alias + 1;
                    $sformat(msgbuf, "%0s %0dx%0d: block %0d overwrites slot %0d word %0d (row %0d word %0d) still needed by block %0d",
                             c_name, c_W, c_H, ew_j, ew_slot, ew_p, cur_tag[m_q] / 1024, cur_tag[m_q] % 1024,
                             cur_need[m_q]);
                    record_fail(msgbuf);
                end
                cur_tag[m_q]  = ew_tag;
                cur_need[m_q] = (pend_tag[m_q] == ew_tag && pend_need[m_q] > ew_j) ? pend_need[m_q] : ew_j;
                pend_tag[m_q] = -1;
                n_wbytes[c_group] = n_wbytes[c_group] + 8;
            end
            ew_v = 1'b0;

            // ---- beats from axi_rd_master -> expected write in the next cycle
            if (rd_valid) begin
                if (iq_rd == iq_wr) begin
                    if (cmp_en) begin
                        mm_extra = mm_extra + 1;
                        $sformat(msgbuf, "%0s %0dx%0d: beat without a command in flight", c_name, c_W, c_H);
                        record_fail(msgbuf);
                    end
                end else begin
                    m_k = iq_rd % IQ;
                    if (!iq_stale[m_k]) begin
                        beats = beats + 1;
                        m_w = iq_w0[m_k] + iq_beat[m_k];             // column word of the source row
                        ew_v = 1'b1;
                        ew_slot = iq_slot[m_k];
                        ew_p = m_w % SW;
                        ew_tag = iq_row[m_k] * 1024 + m_w;
                        ew_j = iq_j[m_k];
                        ew_need = iq_need[m_k];
                        ew_data = srcw[(iq_row[m_k] * c_W) / 8 + m_w];
                    end
                    iq_beat[m_k] = iq_beat[m_k] + 1;
                    if (rd_cmd_last) iq_rd = iq_rd + 1;
                end
            end

            // ---- fetch records (planner -> prefetch_ctrl): expected commands, slot users, reused words
            if (fv && fetch_ready && !frame_start) begin
                m_two = (frb != frt);
                for (m_k = 0; m_k < 1 + m_two; m_k = m_k + 1) begin
                    m_row  = (m_k == 0) ? frt : frb;
                    m_slot = (m_k == 0) ? fst : fsb;
                    if ((m_k == 0) ? ft : fb) begin
                        m_q = cq_wr % CQ;
                        cq_addr[m_q] = SRC + m_row * c_W + fsc; cq_words[m_q] = fw; cq_slot[m_q] = m_slot;
                        cq_j[m_q] = fr_j; cq_need[m_q] = lu[m_slot]; cq_row[m_q] = m_row; cq_w0[m_q] = fsc / 8;
                        cq_wr = cq_wr + 1;
                    end else begin
                        for (m_w = fsc / 8; m_w < fsc / 8 + fw; m_w = m_w + 1) begin
                            m_q = m_slot * SW + m_w % SW;
                            m_tag = m_row * 1024 + m_w;
                            if (cur_tag[m_q] == m_tag) cur_need[m_q] = fr_j;
                            else begin pend_tag[m_q] = m_tag; pend_need[m_q] = fr_j; end
                        end
                    end
                end
                lu[fst] = fr_j;
                lu[fsb] = fr_j;
                fr_j = fr_j + 1;
            end

            // ---- commands (prefetch_ctrl -> axi_rd_master)
            if (cmd_valid && cmd_ready) begin
                m_k = iq_wr % IQ;
                if (frame_start || !cmp_en) begin
                    iq_stale[m_k] = 1;
                end else if (cq_rd == cq_wr) begin
                    mm_cmd = mm_cmd + 1;
                    iq_stale[m_k] = 1;
                    $sformat(msgbuf, "%0s %0dx%0d: command 0x%08h %0d words slot %0d not expected", c_name, c_W, c_H,
                             cmd_addr, cmd_words, cmd_slot);
                    record_fail(msgbuf);
                end else begin
                    m_q = cq_rd % CQ;
                    if (cmd_addr !== cq_addr[m_q] || cmd_words !== cq_words[m_q] || cmd_slot !== cq_slot[m_q]) begin
                        mm_cmd = mm_cmd + 1;
                        $sformat(msgbuf, "%0s %0dx%0d block %0d: command 0x%08h %0d words slot %0d, expected 0x%08h %0d slot %0d",
                                 c_name, c_W, c_H, cq_j[m_q], cmd_addr, cmd_words, cmd_slot, cq_addr[m_q],
                                 cq_words[m_q], cq_slot[m_q]);
                        record_fail(msgbuf);
                    end
                    iq_stale[m_k] = 0;
                    iq_slot[m_k] = cq_slot[m_q]; iq_j[m_k] = cq_j[m_q]; iq_need[m_k] = cq_need[m_q];
                    iq_row[m_k] = cq_row[m_q]; iq_w0[m_k] = cq_w0[m_q];
                    cq_rd = cq_rd + 1;
                    n_cmd[c_group] = n_cmd[c_group] + 1;
                end
                iq_beat[m_k] = 0;
                iq_wr = iq_wr + 1;
            end
            if (cmd_valid && !cmd_ready) cyc_cmdbp = cyc_cmdbp + 1;
            if (u_pc.is_valid && (u_pc.is_nt || u_pc.is_nb) && u_pc.busy[u_pc.cur_slot]) cyc_slotw = cyc_slotw + 1;
            if (!u_pc.is_valid && !u_pc.p3_v && !fv) cyc_starve = cyc_starve + 1;

            // ---- RD_STALL (spec 13), own count: F1 holds a pixel of fetching block f1_k >= blocks_ready, no WR_STALL
            m_tbstall = u_pf.f1_v && (f1_nr != 0) && (f1_k >= blocks_ready) && !wr_stall;
            if (cmp_en && m_tbstall !== rd_stall) begin
                mm_stall = mm_stall + 1;
                $sformat(msgbuf, "%0s %0dx%0d cycle %0d: rd_stall %b, own count %b", c_name, c_W, c_H, cyc - cyc_fs,
                         rd_stall, m_tbstall);
                record_fail(msgbuf);
            end
            if (rd_stall) rs_dut = rs_dut + 1;
            if (m_tbstall) rs_tb = rs_tb + 1;

            // ---- pixels entering pixel_fetch (F1): their fetching block
            if (pix_valid && pix_ready && !frame_start) begin
                f1_k = k_in;
                f1_nr = pix_nrows;
                if (pix_last && pix_nrows != 0) k_in = k_in + 1;
            end

            // ---- last line_buf read of a fetching block (pixel_fetch F1 -> F2)
            if (u_pf.fetch_end) tb_done = tb_done + 1;

            // ---- pixel stream (pixel_fetch -> bilinear_interp)
            if (ip_valid && ip_ready) begin
                bi_inflight = bi_inflight + 1;
                if (cmp_en && !frame_start) begin
                    if (pidx >= npix) begin
                        mm_extra = mm_extra + 1;
                        $sformat(msgbuf, "%0s %0dx%0d: extra pixel at pixel_fetch", c_name, c_W, c_H);
                        record_fail(msgbuf);
                    end else begin
                        m_d = dmp[pidx];
                        if (ip_ok !== m_d[96] || u_pf.f3_x0 !== m_d[95:80] || u_pf.f3_y0 !== m_d[79:64] ||
                            ip_xf !== m_d[63:48] || ip_yf !== m_d[47:32] || ip_r1 !== m_d[31:24] ||
                            ip_r2 !== m_d[23:16] || ip_r3 !== m_d[15:8] || ip_r4 !== m_d[7:0] ||
                            ip_last !== (pidx == npix - 1)) begin
                            mm_pix = mm_pix + 1;
                            $sformat(msgbuf, "%0s %0dx%0d L%0d S%0d pixel %0d (u,v)=(%0d,%0d): got ok %b x0 %0d y0 %0d xf %0d yf %0d r %0d %0d %0d %0d last %b, model ok %b x0 %0d y0 %0d xf %0d yf %0d r %0d %0d %0d %0d",
                                     c_name, c_W, c_H, c_L, c_S, pidx, pidx / c_W, pidx % c_W, ip_ok,
                                     $signed(u_pf.f3_x0), $signed(u_pf.f3_y0), ip_xf, ip_yf, ip_r1, ip_r2, ip_r3, ip_r4,
                                     ip_last, m_d[96], $signed(m_d[95:80]), $signed(m_d[79:64]), m_d[63:48],
                                     m_d[47:32], m_d[31:24], m_d[23:16], m_d[15:8], m_d[7:0]);
                            record_fail(msgbuf);
                        end
                        n_pix[c_group] = n_pix[c_group] + 1;
                    end
                    pidx = pidx + 1;
                end
            end

            // ---- output (bilinear_interp)
            if (op_valid && op_ready) begin
                bi_inflight = bi_inflight - 1;
                if (skip_old > 0) skip_old = skip_old - 1;       // pixel of an aborted frame
                else if (cmp_en && !frame_start) begin
                    if (oidx >= npix) begin
                        mm_extra = mm_extra + 1;
                        $sformat(msgbuf, "%0s %0dx%0d: extra output pixel", c_name, c_W, c_H);
                        record_fail(msgbuf);
                    end else begin
                        m_exp = expw[oidx >> 3][8 * (oidx & 7) +: 8];
                        if (op_d !== m_exp[7:0] || op_last !== (oidx == npix - 1)) begin
                            mm_out = mm_out + 1;
                            $sformat(msgbuf, "%0s %0dx%0d L%0d S%0d output %0d (u,v)=(%0d,%0d): got %0d last %b, model %0d",
                                     c_name, c_W, c_H, c_L, c_S, oidx, oidx / c_W, oidx % c_W, op_d, op_last, m_exp);
                            record_fail(msgbuf);
                        end
                        if (c_check != 0) begin
                            m_u = oidx / c_W; m_v = oidx % c_W;
                            if (c_check == 1)      m_srcb = srcbyte(oidx);
                            else if (c_check == 2) m_srcb = srcbyte(m_u * c_W + c_W - 1 - m_v);
                            else                   m_srcb = srcbyte((c_H - 1 - m_u) * c_W + m_v);
                            if (op_d !== m_srcb) begin
                                mm_src = mm_src + 1;
                                $sformat(msgbuf, "%0s %0dx%0d output (u,v)=(%0d,%0d): %0d, input pixel %0d",
                                         c_name, c_W, c_H, m_u, m_v, op_d, m_srcb);
                                record_fail(msgbuf);
                            end
                        end
                        n_out[c_group] = n_out[c_group] + 1;
                        cyc_last_op = cyc;
                    end
                    oidx = oidx + 1;
                end
            end

            if (rd_beat !== rd_valid) begin
                mm_flag = mm_flag + 1;
                record_fail("rd_beat differs from rd_valid");
            end

            // ---- frame_start: everything after this edge belongs to the new frame
            if (frame_start) begin
                frame_reset;
                cyc_fs = cyc;
                skip_old = bi_inflight;                      // pixels of an aborted frame still in bilinear_interp
                for (m_k = iq_rd; m_k < iq_wr; m_k = m_k + 1) iq_stale[m_k % IQ] = 1;
                for (m_k = 0; m_k < NSLOT * SW; m_k = m_k + 1) cur_tag[m_k] = -1;
            end
        end
    end

    // ---------------- main ----------------
    reg     have_case, done, tmo;
    integer limit, t0, cycles, k2;

    task read_case;
        begin
            r = $fscanf(fd_cases, "%d %s %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %s %s %s",
                        c_group, c_name, c_W, c_H, c_L, c_S, c_b[0], c_b[1], c_b[2], c_b[3], c_b[4], c_b[5],
                        c_lat0, c_lat1, c_arbp, c_rgap, c_opbp, c_seed, c_abort, c_abort_at, c_check,
                        c_bytes, c_est, c_bursts, c_src, c_dump, c_exp);
            have_case = (r == 27);
            if (r != 27 && r != -1 && r != 0) fatal("bad line in cases.txt");
        end
    endtask

    task load_case;
        begin
            if (c_W * c_H > MAXP || c_W * c_H > 8 * MEM_WORDS) fatal("case too large for MAXP / MEM_WORDS");
            if (c_S != 512 && c_S != 32) fatal("cases.txt: S must be 512 or 32");
            npix = c_W * c_H;
            for (k2 = 0; k2 < MEM_WORDS; k2 = k2 + 1) srcw[k2] = 64'bx;
            $sformat(path, "%0s/%0s", vecdir, c_src);
            $readmemh(path, srcw);
            $readmemh(path, u_mem.mem);
            if (srcw[0] === 64'bx || srcw[npix / 8 - 1] === 64'bx) begin
                $sformat(msgbuf, "cannot read %0s (run python scripts/gen_fetch_path_vectors.py, or pass +VEC_DIR)", path);
                fatal(msgbuf);
            end
            $sformat(path, "%0s/%0s", vecdir, c_dump);
            dmp[npix - 1] = 104'bx;
            $readmemh(path, dmp);
            if (dmp[npix - 1] === 104'bx) fatal("cannot read the pixel dump");
            $sformat(path, "%0s/%0s", vecdir, c_exp);
            expw[npix / 8 - 1] = 64'bx;
            $readmemh(path, expw);
            if (expw[npix / 8 - 1] === 64'bx) fatal("cannot read the expected frame");
        end
    endtask

    initial begin
        c_group = 0;
        for (i = 0; i < NGRP; i = i + 1) begin
            n_cases[i] = 0; n_err[i] = 0; n_pix[i] = 0; n_out[i] = 0; n_wbytes[i] = 0; n_cmd[i] = 0;
        end
        cyc = 0; cyc_fs = 0; cyc_last_op = 0;
        full_reset;
        if (!$value$plusargs("VEC_DIR=%s", vecdir)) vecdir = "../../../data/vectors";
        $sformat(path, "%0s/fetch_path/cases.txt", vecdir);
        fd_cases = $fopen(path, "r");
        if (fd_cases == 0) begin
            $sformat(msgbuf, "cannot open %0s (run python scripts/gen_fetch_path_vectors.py, or pass +VEC_DIR)", path);
            fatal(msgbuf);
        end
        skip_comments(fd_cases);

        repeat (RST_CYC) @(negedge aclk);
        aresetn = 1'b1;
        @(negedge aclk);

        read_case;
        while (have_case) begin
            load_case;
            u_mem.lat_min = c_lat0; u_mem.lat_max = c_lat1; u_mem.ar_bp_pct = c_arbp; u_mem.r_gap_pct = c_rgap;
            u_mem.seed = c_seed;
            sel32 = (c_S == 32);
            cfg_width = c_W; cfg_height = c_H; cfg_block_len = c_L; cfg_src = SRC;
            cfg_b11 = c_b[0]; cfg_b12 = c_b[1]; cfg_b13 = c_b[2]; cfg_b21 = c_b[3]; cfg_b22 = c_b[4]; cfg_b23 = c_b[5];
            op_ready = (rnd(100) >= c_opbp);
            frame_start = 1'b1;
            in_frame = 1'b1;
            cmp_en = 1'b1;
            @(negedge aclk);
            frame_start = 1'b0;
            cfg_width = rnd(8192); cfg_height = rnd(8192); cfg_block_len = rnd(8192); cfg_src = $random(seed);
            cfg_b11 = $random(seed); cfg_b12 = $random(seed); cfg_b13 = $random(seed);
            cfg_b21 = $random(seed); cfg_b22 = $random(seed); cfg_b23 = $random(seed);
            limit = 60 * npix + 20000;
            t0 = cyc;
            done = 1'b0;
            tmo = 1'b0;
            while (!done) begin
                op_ready = (rnd(100) >= c_opbp);
                if (c_abort != 0 && pidx >= c_abort_at) done = 1'b1;
                else if (oidx >= npix) done = 1'b1;
                else if (cyc - t0 > limit) begin
                    $sformat(msgbuf, "%0s %0dx%0d L%0d S%0d: timeout, %0d of %0d pixels at pixel_fetch, %0d outputs, blocks_ready %0d, fetch records %0d",
                             c_name, c_W, c_H, c_L, c_S, pidx, npix, oidx, blocks_ready, fr_j);
                    record_fail(msgbuf);
                    done = 1'b1;
                    tmo = 1'b1;
                end
                if (!done) @(negedge aclk);
            end
            n_cases[c_group] = n_cases[c_group] + 1;
            n_frames = n_frames + 1;
            cycles = cyc_last_op - cyc_fs + 1;
            if (tmo || c_abort == 1) begin
                if (c_abort == 1) $display("  g %0s %0dx%0d: aresetn after %0d pixels", c_name, c_W, c_H, pidx);
                cmp_en = 1'b0;
                aresetn = 1'b0;
                repeat (RST_CYC) @(negedge aclk);
                full_reset;
                aresetn = 1'b1;
                @(negedge aclk);
                if (pix_valid || ip_valid || op_valid || cmd_valid || rd_valid || buf_we || fetch_ready === 1'bx)
                    record_fail("valid after aresetn");
            end else if (c_abort == 2) begin
                $display("  g %0s %0dx%0d: next frame_start after %0d pixels (%0d outputs)", c_name, c_W, c_H, pidx, oidx);
                cmp_en = 1'b0;                           // the old frame drains while the next one starts
            end else begin
                // BYTES_RD (group c) and RD_STALL (group e)
                if (beats * 8 != c_bytes) begin
                    mm_bytes = mm_bytes + 1;
                    $sformat(msgbuf, "%0s %0dx%0d L%0d S%0d: BYTES_RD %0d, memmodel %0d", c_name, c_W, c_H, c_L, c_S,
                             beats * 8, c_bytes);
                    record_fail(msgbuf);
                end else bytes_ok_cases = bytes_ok_cases + 1;
                if (pidx != npix || cq_rd != cq_wr) begin
                    mm_count = mm_count + 1;
                    $sformat(msgbuf, "%0s %0dx%0d: %0d pixels, %0d expected commands not issued", c_name, c_W, c_H,
                             pidx, cq_wr - cq_rd);
                    record_fail(msgbuf);
                end
                $display("  %0s %0s %0dx%0d L%0d S%0d mem %0d-%0d bp %0d/%0d/%0d: %0d px, BYTES_RD %0d (memmodel %0d), RD_STALL %0d (own %0d), %0d cycles (est %0d), cmd wait %0d, slot wait %0d",
                         (c_group == 0) ? "a" : (c_group == 1) ? "b" : (c_group == 3) ? "d" : (c_group == 5) ? "f" : "g",
                         c_name, c_W, c_H, c_L, c_S, c_lat0, c_lat1, c_arbp, c_rgap, c_opbp, oidx, beats * 8, c_bytes,
                         rs_dut, rs_tb, cycles, c_est, cyc_cmdbp, cyc_slotw);
                // nothing more may come out
                op_ready = 1'b1;
                repeat (DRAIN) @(negedge aclk);
                if (iq_rd != iq_wr) record_fail("commands still in flight after the frame");
            end
            read_case;
        end

        $display("compared per group (cases / pixels at pixel_fetch / output bytes / line_buf bytes written / commands):");
        $display("  a %0d / %0d / %0d / %0d / %0d", n_cases[0], n_pix[0], n_out[0], n_wbytes[0], n_cmd[0]);
        $display("  b %0d / %0d / %0d / %0d / %0d", n_cases[1], n_pix[1], n_out[1], n_wbytes[1], n_cmd[1]);
        $display("  d %0d / %0d / %0d / %0d / %0d", n_cases[3], n_pix[3], n_out[3], n_wbytes[3], n_cmd[3]);
        $display("  f %0d / %0d / %0d / %0d / %0d", n_cases[5], n_pix[5], n_out[5], n_wbytes[5], n_cmd[5]);
        $display("  g %0d / %0d / %0d / %0d / %0d", n_cases[6], n_pix[6], n_out[6], n_wbytes[6], n_cmd[6]);
        $display("  total %0d frames, %0d pixels, %0d output bytes, %0d line_buf bytes, %0d commands", n_frames,
                 n_pix[0] + n_pix[1] + n_pix[3] + n_pix[5] + n_pix[6], n_out[0] + n_out[1] + n_out[3] + n_out[5] + n_out[6],
                 n_wbytes[0] + n_wbytes[1] + n_wbytes[3] + n_wbytes[5] + n_wbytes[6],
                 n_cmd[0] + n_cmd[1] + n_cmd[3] + n_cmd[5] + n_cmd[6]);
        $display("  c BYTES_RD == memmodel in %0d complete frames", bytes_ok_cases);
        u_mem.report;
        $display("mismatches: command %0d, buffer write %0d, slot reuse %0d, aliasing %0d, pixel stream %0d, output %0d, input (b) %0d, BYTES_RD %0d, RD_STALL %0d, count %0d, extra %0d, flags %0d, AXI %0d",
                 mm_cmd, mm_wr, mm_slot, mm_alias, mm_pix, mm_out, mm_src, mm_bytes, mm_stall, mm_count, mm_extra,
                 mm_flag, u_mem.viol_total);
        $display("errors per group: a %0d, b %0d, d %0d, f %0d, g %0d", n_err[0], n_err[1], n_err[3], n_err[5], n_err[6]);
        if (u_mem.viol_total != 0 && nfail == 0) first_fail = "AXI protocol violations (axi_mem checker)";
        if (nfail == 0 && u_mem.viol_total == 0) $display("TEST PASS");
        else $display("TEST FAIL: %0d errors, first: %0s", nfail + u_mem.viol_total, first_fail);
        $finish;
    end

endmodule
