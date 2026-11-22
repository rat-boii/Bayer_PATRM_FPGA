// Self-checking testbench for rtl/block_planner.v (step 3.6a).
//
// Needs the model vectors (data/vectors/, not tracked). Run from the repo root:
//   python -m model.gen_vectors
//   python scripts/gen_block_planner_vectors.py
//   python scripts/sim.py --top tb_block_planner -f tb/block_planner.f --plusarg VEC_DIR=data/vectors
// +VEC_DIR=<folder> is the vector folder (default ../../../data/vectors). The case list is
// <VEC_DIR>/block_planner/cases.txt (format: scripts/gen_block_planner_vectors.py). Nothing else is hard-coded.
//
// Two DUT instances: SPAN_MAX = 512 (D16) and SPAN_MAX = 32 (the stress setting of the step 2.2 vectors); each
// case uses the one named in its S column (both see the same inputs). Every record of the model block list
// (sched_blocks_*.txt) is compared, in order and with the count checked:
//   descriptor port   u, v0, n, nrows, slot_top, slot_bot, s_col, last (blocks with nrows = 0: slots and s_col
//                     must be 0, the model writes -1 = none)
//   fetch port        (blocks with nrows > 0, in order) row_top, row_bot, slot_top, slot_bot, fetch_top,
//                     fetch_bot, s_col, words = span / 8
//   inside the DUT    nvalid and the end reason of each block, at the FIFO write (they are not ports)
// While a port holds valid = 1 with ready = 0, its outputs must not change. After the last record of a frame both
// ports must stay empty.
// Groups (letters of the step 3.6a prompt): a every sim size + 208x120 x every transform x both (L, S);
// b BLOCK_LEN 1 / 7 / 63 / 64 / random; c D16 edges (directed); d random back-pressure on both ports;
// e rate with ready = 1 (descriptors per clock); f frames back to back with different cfg, aresetn and
// frame_start in the middle of a frame (the frame after each abort must be correct).
// Every frame starts in the cycle right after the previous one ends, and the cfg_* inputs are scrambled after
// frame_start (the DUT must use the values it latched).
// Prints one line per case for groups c, e, f, the records compared per group, and exactly one final line:
// "TEST PASS" or "TEST FAIL: <reason>".
`timescale 1ns/1ps
module tb_block_planner;

    localparam CLK_HALF  = 5;                            // 100 MHz
    localparam SIZE_BITS = 13;
    localparam CNT_BITS  = 7;
    localparam SLOT_BITS = 5;
    localparam MAXB      = 65536;                        // records per frame
    localparam STR       = 8 * 320;
    localparam NGRP      = 6;
    localparam DRAIN     = 8;                            // cycles both ports must stay empty after a frame
    localparam RST_CYC   = 16;
    localparam MAX_PRINT = 20;

`ifdef ALT_SEED
    integer seed = 11;
`else
    integer seed = 3601;
`endif

    // ---------------- clock, reset, DUTs ----------------
    reg aclk = 1'b0;
    reg aresetn = 1'b0;
    always #CLK_HALF aclk = ~aclk;

    reg                  frame_start = 1'b0;
    reg [SIZE_BITS-1:0]  cfg_width = 0, cfg_height = 0, cfg_block_len = 0;
    reg [31:0]           cfg_b11 = 0, cfg_b12 = 0, cfg_b13 = 0, cfg_b21 = 0, cfg_b22 = 0, cfg_b23 = 0;
    reg                  desc_ready = 1'b0, fetch_ready = 1'b0;
    reg                  sel32 = 1'b0;                   // 1: check the SPAN_MAX = 32 instance

    wire                 a_dv, a_fv, b_dv, b_fv;
    wire [SIZE_BITS-1:0] a_du, a_dv0, a_dsc, a_frt, a_frb, a_fsc, b_du, b_dv0, b_dsc, b_frt, b_frb, b_fsc;
    wire [CNT_BITS-1:0]  a_dn, a_fw, b_dn, b_fw;
    wire [1:0]           a_dnr, b_dnr;
    wire [SLOT_BITS-1:0] a_dst, a_dsb, a_fst, a_fsb, b_dst, b_dsb, b_fst, b_fsb;
    wire                 a_dl, a_ft, a_fb, b_dl, b_ft, b_fb;

    block_planner #(.SIZE_BITS(SIZE_BITS), .CNT_BITS(CNT_BITS), .SLOT_BITS(SLOT_BITS), .SPAN_MAX(512)) dut_a (
        .aclk(aclk), .aresetn(aresetn), .frame_start(frame_start),
        .cfg_width(cfg_width), .cfg_height(cfg_height), .cfg_block_len(cfg_block_len),
        .cfg_stride2(1'b0), .cfg_o_row(1'b0), .cfg_o_col(1'b0),                // gray (Option A: tb_patrm_top)
        .cfg_b11(cfg_b11), .cfg_b12(cfg_b12), .cfg_b13(cfg_b13), .cfg_b21(cfg_b21), .cfg_b22(cfg_b22), .cfg_b23(cfg_b23),
        .desc_valid(a_dv), .desc_ready(desc_ready), .desc_u(a_du), .desc_v0(a_dv0), .desc_n(a_dn),
        .desc_nrows(a_dnr), .desc_slot_top(a_dst), .desc_slot_bot(a_dsb), .desc_s_col(a_dsc), .desc_last(a_dl),
        .fetch_valid(a_fv), .fetch_ready(fetch_ready), .fetch_row_top(a_frt), .fetch_row_bot(a_frb),
        .fetch_slot_top(a_fst), .fetch_slot_bot(a_fsb), .fetch_top(a_ft), .fetch_bot(a_fb), .fetch_s_col(a_fsc),
        .fetch_words(a_fw));

    block_planner #(.SIZE_BITS(SIZE_BITS), .CNT_BITS(CNT_BITS), .SLOT_BITS(SLOT_BITS), .SPAN_MAX(32)) dut_b (
        .aclk(aclk), .aresetn(aresetn), .frame_start(frame_start),
        .cfg_width(cfg_width), .cfg_height(cfg_height), .cfg_block_len(cfg_block_len),
        .cfg_stride2(1'b0), .cfg_o_row(1'b0), .cfg_o_col(1'b0),                // gray (Option A: tb_patrm_top)
        .cfg_b11(cfg_b11), .cfg_b12(cfg_b12), .cfg_b13(cfg_b13), .cfg_b21(cfg_b21), .cfg_b22(cfg_b22), .cfg_b23(cfg_b23),
        .desc_valid(b_dv), .desc_ready(desc_ready), .desc_u(b_du), .desc_v0(b_dv0), .desc_n(b_dn),
        .desc_nrows(b_dnr), .desc_slot_top(b_dst), .desc_slot_bot(b_dsb), .desc_s_col(b_dsc), .desc_last(b_dl),
        .fetch_valid(b_fv), .fetch_ready(fetch_ready), .fetch_row_top(b_frt), .fetch_row_bot(b_frb),
        .fetch_slot_top(b_fst), .fetch_slot_bot(b_fsb), .fetch_top(b_ft), .fetch_bot(b_fb), .fetch_s_col(b_fsc),
        .fetch_words(b_fw));

    // selected instance
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
    // not ports: FIFO write, end reason and valid-pixel count of the block being written
    wire                 w_push   = sel32 ? dut_b.d_push   : dut_a.d_push;
    wire [1:0]           w_reason = sel32 ? dut_b.d_reason : dut_a.d_reason;
    wire [CNT_BITS-1:0]  w_nvalid = sel32 ? dut_b.d_nvalid : dut_a.d_nvalid;

    wire [3*SIZE_BITS+CNT_BITS+2+2*SLOT_BITS:0] d_bundle = {du, dv0, dn, dnr, dst, dsb, dsc, dl};
    wire [3*SIZE_BITS+2*SLOT_BITS+2+CNT_BITS-1:0] f_bundle = {frt, frb, fst, fsb, ft, fb, fsc, fw};

    // ---------------- expected records of the current frame ----------------
    integer e_u [0:MAXB-1], e_v0 [0:MAXB-1], e_n [0:MAXB-1], e_nvalid [0:MAXB-1], e_reason [0:MAXB-1];
    integer e_nrows [0:MAXB-1], e_rt [0:MAXB-1], e_rb [0:MAXB-1], e_scol [0:MAXB-1], e_span [0:MAXB-1];
    integer e_ft [0:MAXB-1], e_fb [0:MAXB-1], e_st [0:MAXB-1], e_sb [0:MAXB-1];
    integer e_fidx [0:MAXB-1];                           // block id of fetch record k

    // ---------------- case ----------------
    reg [STR-1:0] vecdir, path, c_name, c_file, junk, msgbuf, first_fail;
    integer c_group, c_W, c_H, c_L, c_S, c_nblk, c_nfetch, c_bp, c_abort, c_abort_at;
    integer c_b [0:5];
    integer fd_cases, fd_blk;

    integer n_desc [0:NGRP-1], n_fetch [0:NGRP-1], n_cases [0:NGRP-1], n_err [0:NGRP-1];
    integer nfail = 0;
    integer mm_desc = 0, mm_fetch = 0, mm_int = 0, mm_hold = 0, mm_extra = 0, mm_count = 0;
    integer n_abort_rst = 0, n_abort_fs = 0, n_frames = 0;
    integer i, r;

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

    task load_blocks;
        integer k, nf, id;
        begin
            $sformat(path, "%0s/%0s", vecdir, c_file);
            fd_blk = $fopen(path, "r");
            if (fd_blk == 0) begin
                $sformat(msgbuf, "cannot open %0s (run python -m model.gen_vectors and python scripts/gen_block_planner_vectors.py, or pass +VEC_DIR)", path);
                fatal(msgbuf);
            end
            skip_comments(fd_blk);
            if (c_nblk > MAXB) fatal("block list longer than MAXB");
            nf = 0;
            for (k = 0; k < c_nblk; k = k + 1) begin
                r = $fscanf(fd_blk, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d", id, e_u[k], e_v0[k], e_n[k],
                            e_nvalid[k], e_reason[k], e_nrows[k], e_rt[k], e_rb[k], e_scol[k], e_span[k], e_ft[k],
                            e_fb[k], e_st[k], e_sb[k]);
                if (r != 15 || id != k) begin
                    $sformat(msgbuf, "%0s: bad block list line %0d", c_file, k);
                    fatal(msgbuf);
                end
                if (e_nrows[k] > 0) begin
                    e_fidx[nf] = k;
                    nf = nf + 1;
                end
            end
            $fclose(fd_blk);
            if (nf != c_nfetch) fatal("cases.txt nfetch does not match the block list");
        end
    endtask

    // ---------------- monitors ----------------
    reg     mon_en = 1'b0;
    integer di = 0, fi = 0, wi = 0;
    integer cyc = 0, cyc_fs = 0, cyc_last = 0;
    reg                  prev_dhold = 1'b0, prev_fhold = 1'b0;
    reg [3*SIZE_BITS+CNT_BITS+2+2*SLOT_BITS:0]    prev_d = 0;
    reg [3*SIZE_BITS+2*SLOT_BITS+2+CNT_BITS-1:0]  prev_f = 0;
    integer k_, ed_st, ed_sb, ed_sc;

    always @(posedge aclk) begin
        cyc <= cyc + 1;
        if (mon_en && aresetn) begin
            // held outputs stay stable
            if (prev_dhold && (!dv || d_bundle != prev_d)) begin
                mm_hold = mm_hold + 1;
                $sformat(msgbuf, "%0s %0dx%0d: descriptor port changed while held (record %0d)", c_name, c_W, c_H, di);
                record_fail(msgbuf);
            end
            if (prev_fhold && (!fv || f_bundle != prev_f)) begin
                mm_hold = mm_hold + 1;
                $sformat(msgbuf, "%0s %0dx%0d: fetch port changed while held (record %0d)", c_name, c_W, c_H, fi);
                record_fail(msgbuf);
            end
            prev_dhold <= dv && !desc_ready;
            prev_fhold <= fv && !fetch_ready;
            prev_d <= d_bundle;
            prev_f <= f_bundle;
            // descriptor port
            if (dv && desc_ready) begin
                if (di >= c_nblk) begin
                    mm_extra = mm_extra + 1;
                    $sformat(msgbuf, "%0s %0dx%0d L%0d S%0d: extra descriptor after %0d", c_name, c_W, c_H, c_L, c_S, c_nblk);
                    record_fail(msgbuf);
                end else begin
                    ed_st = (e_nrows[di] > 0) ? e_st[di] : 0;
                    ed_sb = (e_nrows[di] > 0) ? e_sb[di] : 0;
                    ed_sc = (e_nrows[di] > 0) ? e_scol[di] : 0;
                    if (du !== e_u[di] || dv0 !== e_v0[di] || dn !== e_n[di] || dnr !== e_nrows[di] ||
                        dst !== ed_st || dsb !== ed_sb || dsc !== ed_sc || dl !== (di == c_nblk - 1)) begin
                        mm_desc = mm_desc + 1;
                        $sformat(msgbuf, "%0s %0dx%0d L%0d S%0d desc %0d: got u %0d v0 %0d n %0d nrows %0d slots %0d %0d s_col %0d last %0d, model u %0d v0 %0d n %0d nrows %0d slots %0d %0d s_col %0d",
                                 c_name, c_W, c_H, c_L, c_S, di, du, dv0, dn, dnr, dst, dsb, dsc, dl,
                                 e_u[di], e_v0[di], e_n[di], e_nrows[di], ed_st, ed_sb, ed_sc);
                        record_fail(msgbuf);
                    end
                    n_desc[c_group] = n_desc[c_group] + 1;
                end
                di = di + 1;
                cyc_last = cyc;
            end
            // fetch port
            if (fv && fetch_ready) begin
                if (fi >= c_nfetch) begin
                    mm_extra = mm_extra + 1;
                    $sformat(msgbuf, "%0s %0dx%0d L%0d S%0d: extra fetch record after %0d", c_name, c_W, c_H, c_L, c_S, c_nfetch);
                    record_fail(msgbuf);
                end else begin
                    k_ = e_fidx[fi];
                    if (frt !== e_rt[k_] || frb !== e_rb[k_] || fst !== e_st[k_] || fsb !== e_sb[k_] ||
                        ft !== e_ft[k_] || fb !== e_fb[k_] || fsc !== e_scol[k_] || fw !== e_span[k_] / 8) begin
                        mm_fetch = mm_fetch + 1;
                        $sformat(msgbuf, "%0s %0dx%0d L%0d S%0d fetch %0d (block %0d): got rows %0d %0d slots %0d %0d fetch %0d %0d s_col %0d words %0d, model rows %0d %0d slots %0d %0d fetch %0d %0d s_col %0d words %0d",
                                 c_name, c_W, c_H, c_L, c_S, fi, k_, frt, frb, fst, fsb, ft, fb, fsc, fw,
                                 e_rt[k_], e_rb[k_], e_st[k_], e_sb[k_], e_ft[k_], e_fb[k_], e_scol[k_], e_span[k_] / 8);
                        record_fail(msgbuf);
                    end
                    n_fetch[c_group] = n_fetch[c_group] + 1;
                end
                fi = fi + 1;
            end
            // FIFO write: end reason and valid-pixel count (not ports)
            if (w_push) begin
                if (wi < c_nblk && (w_reason !== e_reason[wi] || w_nvalid !== e_nvalid[wi])) begin
                    mm_int = mm_int + 1;
                    $sformat(msgbuf, "%0s %0dx%0d L%0d S%0d block %0d: reason %0d nvalid %0d, model reason %0d nvalid %0d",
                             c_name, c_W, c_H, c_L, c_S, wi, w_reason, w_nvalid, e_reason[wi], e_nvalid[wi]);
                    record_fail(msgbuf);
                end
                wi = wi + 1;
            end
        end else begin
            prev_dhold <= 1'b0;
            prev_fhold <= 1'b0;
        end
    end

    // ---------------- main ----------------
    reg     have_case, done, tmo;
    integer limit, t0;
    real    rate;

    task drive_ready;
        begin
            desc_ready  = (rnd(100) >= c_bp);
            fetch_ready = (rnd(100) >= c_bp);
        end
    endtask

    task read_case;
        begin
            r = $fscanf(fd_cases, "%d %s %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %s", c_group, c_name, c_W, c_H,
                        c_L, c_S, c_b[0], c_b[1], c_b[2], c_b[3], c_b[4], c_b[5], c_nblk, c_nfetch, c_bp,
                        c_abort, c_abort_at, c_file);
            have_case = (r == 18);
            if (r != 18 && r != -1 && r != 0) fatal("bad line in cases.txt");
        end
    endtask

    initial begin
        c_group = 0;
        for (i = 0; i < NGRP; i = i + 1) begin
            n_desc[i] = 0; n_fetch[i] = 0; n_cases[i] = 0; n_err[i] = 0;
        end
        if (!$value$plusargs("VEC_DIR=%s", vecdir)) vecdir = "../../../data/vectors";
        $sformat(path, "%0s/block_planner/cases.txt", vecdir);
        fd_cases = $fopen(path, "r");
        if (fd_cases == 0) begin
            $sformat(msgbuf, "cannot open %0s (run python scripts/gen_block_planner_vectors.py, or pass +VEC_DIR)", path);
            fatal(msgbuf);
        end
        skip_comments(fd_cases);

        repeat (RST_CYC) @(negedge aclk);
        aresetn = 1'b1;
        @(negedge aclk);

        read_case;
        while (have_case) begin
            if (c_S != 512 && c_S != 32) fatal("cases.txt: S must be 512 or 32");
            load_blocks;
            // frame_start in this cycle (right after the previous frame / abort)
            sel32 = (c_S == 32);
            cfg_width = c_W; cfg_height = c_H; cfg_block_len = c_L;
            cfg_b11 = c_b[0]; cfg_b12 = c_b[1]; cfg_b13 = c_b[2]; cfg_b21 = c_b[3]; cfg_b22 = c_b[4]; cfg_b23 = c_b[5];
            di = 0; fi = 0; wi = 0;
            frame_start = 1'b1;
            drive_ready;
            mon_en = 1'b1;
            cyc_fs = cyc + 1;                            // the cycle of the frame_start edge
            @(negedge aclk);
            frame_start = 1'b0;
            cfg_width = rnd(8192); cfg_height = rnd(8192); cfg_block_len = rnd(8192);
            cfg_b11 = $random(seed); cfg_b12 = $random(seed); cfg_b13 = $random(seed);
            cfg_b21 = $random(seed); cfg_b22 = $random(seed); cfg_b23 = $random(seed);
            limit = 4 * c_W * c_H + 2000;
            t0 = cyc;
            done = 1'b0;
            tmo = 1'b0;
            while (!done) begin
                drive_ready;
                if (c_abort != 0 && di >= c_abort_at) done = 1'b1;
                else if (di >= c_nblk && fi >= c_nfetch) done = 1'b1;
                else if (cyc - t0 > limit) begin
                    // recorded, then aresetn so that the next case starts clean
                    $sformat(msgbuf, "%0s %0dx%0d L%0d S%0d: timeout, %0d of %0d descriptors, %0d of %0d fetch records",
                             c_name, c_W, c_H, c_L, c_S, di, c_nblk, fi, c_nfetch);
                    record_fail(msgbuf);
                    done = 1'b1;
                    tmo = 1'b1;
                end
                if (!done) @(negedge aclk);
            end
            n_cases[c_group] = n_cases[c_group] + 1;
            n_frames = n_frames + 1;
            if (tmo) begin
                mon_en = 1'b0;
                aresetn = 1'b0;
                repeat (RST_CYC) @(negedge aclk);
                aresetn = 1'b1;
                @(negedge aclk);
            end else if (c_abort == 0) begin
                if (wi != c_nblk) begin
                    mm_count = mm_count + 1;
                    $sformat(msgbuf, "%0s %0dx%0d L%0d S%0d: %0d blocks written, model %0d", c_name, c_W, c_H, c_L, c_S, wi, c_nblk);
                    record_fail(msgbuf);
                end
                if (c_group == 4) begin
                    rate = c_nblk * 1.0 / (cyc_last - cyc_fs + 1);
                    $display("  e %0s %0dx%0d L%0d: %0d descriptors in %0d cycles from frame_start = %0.4f descriptors/clock (%0d pixels, %0.4f pixels/clock)",
                             c_name, c_W, c_H, c_L, c_nblk, cyc_last - cyc_fs + 1, rate, c_W * c_H,
                             c_W * c_H * 1.0 / (cyc_last - cyc_fs + 1));
                end
                if (c_group == 2 || c_group == 5)
                    $display("  %0s %0s %0dx%0d L%0d S%0d: %0d descriptors, %0d fetch records compared",
                             (c_group == 2) ? "c" : "f", c_name, c_W, c_H, c_L, c_S, di, fi);
                // both ports stay empty
                desc_ready = 1'b1; fetch_ready = 1'b1;
                repeat (DRAIN) @(negedge aclk);          // the monitor flags any extra record
            end else if (c_abort == 1) begin
                $display("  f %0s %0dx%0d: aresetn after %0d descriptors", c_name, c_W, c_H, di);
                n_abort_rst = n_abort_rst + 1;
                mon_en = 1'b0;
                aresetn = 1'b0;
                repeat (RST_CYC) @(negedge aclk);
                aresetn = 1'b1;
                @(negedge aclk);
                if (a_dv || a_fv || b_dv || b_fv) record_fail("valid after aresetn");
            end else begin
                $display("  f %0s %0dx%0d: next frame_start after %0d descriptors", c_name, c_W, c_H, di);
                n_abort_fs = n_abort_fs + 1;
            end
            read_case;
        end

        $display("records compared per group (descriptors / fetch records / cases):");
        $display("  a %0d / %0d / %0d", n_desc[0], n_fetch[0], n_cases[0]);
        $display("  b %0d / %0d / %0d", n_desc[1], n_fetch[1], n_cases[1]);
        $display("  c %0d / %0d / %0d", n_desc[2], n_fetch[2], n_cases[2]);
        $display("  d %0d / %0d / %0d", n_desc[3], n_fetch[3], n_cases[3]);
        $display("  e %0d / %0d / %0d", n_desc[4], n_fetch[4], n_cases[4]);
        $display("  f %0d / %0d / %0d (aborts: %0d aresetn, %0d frame_start)", n_desc[5], n_fetch[5], n_cases[5],
                 n_abort_rst, n_abort_fs);
        $display("  total %0d descriptors, %0d fetch records, %0d frames",
                 n_desc[0] + n_desc[1] + n_desc[2] + n_desc[3] + n_desc[4] + n_desc[5],
                 n_fetch[0] + n_fetch[1] + n_fetch[2] + n_fetch[3] + n_fetch[4] + n_fetch[5], n_frames);
        $display("mismatches: descriptor %0d, fetch %0d, reason/nvalid %0d, held-output %0d, extra %0d, count %0d",
                 mm_desc, mm_fetch, mm_int, mm_hold, mm_extra, mm_count);
        $display("errors per group: a %0d, b %0d, c %0d, d %0d, e %0d, f %0d",
                 n_err[0], n_err[1], n_err[2], n_err[3], n_err[4], n_err[5]);
        if (nfail == 0) $display("TEST PASS");
        else $display("TEST FAIL: %0d errors, first: %0s", nfail, first_fail);
        $finish;
    end

endmodule
