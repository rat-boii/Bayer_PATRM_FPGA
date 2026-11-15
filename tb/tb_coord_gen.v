// Self-checking testbench for rtl/coord_gen.v (step 3.2).
//
// Needs the model vectors (data/vectors/, not tracked). Run from the repo root:
//   python -m model.gen_vectors
//   python scripts/gen_coord_gen_vectors.py
//   python scripts/sim.py --top tb_coord_gen -f tb/coord_gen.f --plusarg VEC_DIR=data/vectors
// +VEC_DIR=<folder> is the vector folder (default ../../../data/vectors = the repo folder seen from
// build/sim/tb_coord_gen/). The case list is <VEC_DIR>/coord_gen/cases.txt; its format and the file formats are
// described in scripts/gen_coord_gen_vectors.py and README.md. Nothing else is hard-coded.
// Prints one line per case, the pixels compared per group and exactly one final line:
// "TEST PASS" or "TEST FAIL: <reason>".
//
// The testbench plays block_planner: it sends the block descriptors of the model block list
// (sched_blocks_*.txt) and compares every pixel of the stream with the model coordinate dump
// (coord_vectors_*.txt), line k of the dump against pixel k of the stream:
//   X, Y                       coord_gen outputs pix_X, pix_Y
//   u, v                       (desc_u, desc_v0 + index in the block) of the descriptor the pixel belongs to
//   valid, x0, y0, xf, yf      not ports of coord_gen (spec section 7: pixel_fetch F1 computes them); derived
//                              here from pix_X / pix_Y with the spec expressions and compared all the same
//   first, last, nrows, slots, s_col, frame_last   against the descriptor that was sent
// Groups (letters as in the step 3.2 prompt; b = block planner, not part of this module, see section 3):
//   a  every transform x sim size, pix_ready = 1, descriptors always available: 1 pixel per clock,
//      cycles = W*H + 4 exactly
//   c  the same frames cut differently (L32/S32 block lists), pix_ready low 0..30 % of the cycles, late
//      descriptors: nothing lost, duplicated or reordered; held outputs stay stable
//   d  worked example: pixel (3,2) gives X = 209715, Y = 288360, x0 = 3, xf = 13107, y0 = 4, yf = 26216
//   e  32-bit wrap: the step 1.1 wrap case, and random descriptors with full-range 32-bit coefficients
//   f  start / restart: frames back to back with different transforms and sizes, aresetn and frame_start in the
//      middle of a frame; the frame after each abort must be correct
// Every frame starts in the cycle right after the previous one ends (no idle cycle in between), and the cfg_b*
// inputs are scrambled after frame_start (the module must use the values it latched).
`timescale 1ns/1ps
module tb_coord_gen;

    localparam CLK_HALF  = 5;                            // 100 MHz
    localparam SIZE_BITS = 13;
    localparam CNT_BITS  = 7;
    localparam SLOT_BITS = 5;
    localparam LATENCY   = 4;                            // descriptor taken -> first pixel (spec section 4)
    localparam SB_N      = 64;                           // scoreboard entries (>= 4 descriptors in flight)
    localparam STR       = 8 * 320;
    localparam BUNDLE_W  = 64 + 2 + 2 + 2 * SLOT_BITS + SIZE_BITS + 1;
    localparam G_A = 0, G_C = 2, G_D = 3, G_E = 4, G_F = 5, NGRP = 6;
    localparam MAX_PRINT = 20;

`ifdef ALT_SEED                                          // second seed: --define ALT_SEED
    integer seed = 7;
`else
    integer seed = 31;
`endif

    // ---------------- clock, reset, DUT ----------------
    reg aclk = 1'b0;
    reg aresetn = 1'b0;
    always #CLK_HALF aclk = ~aclk;

    reg                    frame_start = 1'b0;
    reg  [31:0]            cfg_b11 = 0, cfg_b12 = 0, cfg_b13 = 0, cfg_b21 = 0, cfg_b22 = 0, cfg_b23 = 0;
    reg                    desc_valid = 1'b0;
    wire                   desc_ready;
    reg  [SIZE_BITS-1:0]   desc_u = 0, desc_v0 = 0, desc_s_col = 0;
    reg  [CNT_BITS-1:0]    desc_n = 0;
    reg  [1:0]             desc_nrows = 0;
    reg  [SLOT_BITS-1:0]   desc_slot_top = 0, desc_slot_bot = 0;
    reg                    desc_last = 1'b0;
    wire                   pix_valid;
    reg                    pix_ready = 1'b0;
    wire signed [31:0]     pix_X, pix_Y;
    wire                   pix_first, pix_last, pix_frame_last;
    wire [1:0]             pix_nrows;
    wire [SLOT_BITS-1:0]   pix_slot_top, pix_slot_bot;
    wire [SIZE_BITS-1:0]   pix_s_col;

    coord_gen #(.SIZE_BITS(SIZE_BITS), .CNT_BITS(CNT_BITS), .SLOT_BITS(SLOT_BITS)) dut (
        .aclk(aclk), .aresetn(aresetn), .frame_start(frame_start),
        .cfg_b11(cfg_b11), .cfg_b12(cfg_b12), .cfg_b13(cfg_b13),
        .cfg_b21(cfg_b21), .cfg_b22(cfg_b22), .cfg_b23(cfg_b23),
        .desc_valid(desc_valid), .desc_ready(desc_ready),
        .desc_u(desc_u), .desc_v0(desc_v0), .desc_n(desc_n), .desc_nrows(desc_nrows),
        .desc_slot_top(desc_slot_top), .desc_slot_bot(desc_slot_bot), .desc_s_col(desc_s_col),
        .desc_last(desc_last),
        .pix_valid(pix_valid), .pix_ready(pix_ready), .pix_X(pix_X), .pix_Y(pix_Y),
        .pix_first(pix_first), .pix_last(pix_last), .pix_nrows(pix_nrows),
        .pix_slot_top(pix_slot_top), .pix_slot_bot(pix_slot_bot), .pix_s_col(pix_s_col),
        .pix_frame_last(pix_frame_last)
    );

    wire [BUNDLE_W-1:0] pix_bundle = {pix_X, pix_Y, pix_first, pix_last, pix_nrows, pix_slot_top, pix_slot_bot,
                                      pix_s_col, pix_frame_last};

    // ---------------- current case (one line of cases.txt) ----------------
    reg [STR-1:0] vecdir, path, c_name, c_fblk, c_fcrd, junk;
    integer c_group, c_W, c_H, c_nblk, c_npix, c_bp, c_gap, c_abort, c_abort_at;
    integer c_b [0:5];
    integer fd_cases, fd_blk, fd_crd;

    // ---------------- bookkeeping ----------------
    integer n_pix   [0:NGRP-1];                          // pixels compared per group
    integer n_cases [0:NGRP-1];
    integer nfail = 0;
    reg [STR-1:0] first_fail, msgbuf;
    integer mm_x = 0, mm_y = 0, mm_uv = 0, mm_valid = 0, mm_int = 0, mm_frac = 0, mm_side = 0, mm_hold = 0;
    integer n_side = 0, n_hold = 0;
    integer n_frames = 0, n_abort_rst = 0, n_abort_fs = 0, n_ii1 = 0;
    integer n_blk1 = 0;                                  // 1-pixel blocks sent
    integer tot_stall = 0, tot_cycles = 0, d_seen = 0, wrap_valid = 0;
    integer i;

    task record_fail;
        input [STR-1:0] m;
        begin
            if (nfail == 0) first_fail = m;
            nfail = nfail + 1;
            if (nfail <= MAX_PRINT) $display("  FAIL %0s", m);
        end
    endtask

    task fatal;                                          // cannot continue (missing / broken vector files)
        input [STR-1:0] m;
        begin
            $display("TEST FAIL: %0s", m);
            $finish;
        end
    endtask

    function integer rnd;                                // 0 .. n-1
        input integer n;
        begin
            rnd = ($random(seed) & 32'h7FFF_FFFF) % n;
        end
    endfunction

    task skip_comments;                                  // '#' lines at the top of a vector file
        input integer fd;
        integer ch, r;
        reg more;
        begin
            more = 1'b1;
            while (more) begin
                ch = $fgetc(fd);
                if (ch == "#") r = $fgets(junk, fd);
                else begin
                    if (ch != -1) r = $ungetc(ch, fd);
                    more = 1'b0;
                end
            end
        end
    endtask

    task open_vec;
        input  [STR-1:0] name;
        output integer   fd;
        begin
            $sformat(path, "%0s/%0s", vecdir, name);
            fd = $fopen(path, "r");
            if (fd == 0) begin
                $sformat(msgbuf, "cannot open %0s (run python -m model.gen_vectors and python scripts/gen_coord_gen_vectors.py, or pass +VEC_DIR)", path);
                fatal(msgbuf);
            end
            skip_comments(fd);
        end
    endtask

    // ---------------- scoreboard: descriptors taken by the DUT, in order ----------------
    reg [SIZE_BITS-1:0] sb_u [0:SB_N-1], sb_v0 [0:SB_N-1], sb_s_col [0:SB_N-1];
    reg [CNT_BITS-1:0]  sb_n [0:SB_N-1];
    reg [1:0]           sb_nrows [0:SB_N-1];
    reg [SLOT_BITS-1:0] sb_st [0:SB_N-1], sb_sbot [0:SB_N-1];
    reg                 sb_last [0:SB_N-1];
    integer sb_wr = 0, sb_rd = 0, mon_j = 0;

    // ---------------- per-frame state shared by driver, monitor and the main thread ----------------
    reg     run_en = 1'b0;                               // driver sends descriptors
    reg     mon_en = 1'b0;                               // monitor checks the pixel stream
    reg     desc_fired = 1'b0;
    integer blk_loaded = 0, blk_fired = 0, pix_seen = 0, gap_cnt = 0, case_stall = 0, frame_last_seen = 0;
    integer cyc = 0, cyc_first_desc = 0, cyc_first_pix = 0, cyc_last_pix = 0;
    reg                prev_v = 1'b0, prev_r = 1'b0;
    reg [BUNDLE_W-1:0] prev_bundle = 0;

    // ---------------- driver (negedge): descriptors and pix_ready for the next cycle ----------------
    integer f_id, f_u, f_v0, f_n, f_nvalid, f_reason, f_nrows, f_rt, f_rb, f_scol, f_span, f_ft, f_fb, f_st, f_sb;
    task load_desc;
        integer r;
        begin
            r = $fscanf(fd_blk, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d", f_id, f_u, f_v0, f_n, f_nvalid,
                        f_reason, f_nrows, f_rt, f_rb, f_scol, f_span, f_ft, f_fb, f_st, f_sb);
            if (r != 15 || f_id != blk_loaded) begin
                $sformat(msgbuf, "%0s: bad block list line %0d", c_fblk, blk_loaded);
                fatal(msgbuf);
            end
            desc_u     = f_u;
            desc_v0    = f_v0;
            desc_n     = f_n;
            desc_nrows = f_nrows;
            if (f_nrows == 0) begin                      // block without valid pixels: fields are don't-care
                desc_slot_top = rnd(1 << SLOT_BITS);
                desc_slot_bot = rnd(1 << SLOT_BITS);
                desc_s_col    = rnd(1 << SIZE_BITS);
            end else begin
                desc_slot_top = f_st;
                desc_slot_bot = f_sb;
                desc_s_col    = f_scol;
            end
            desc_last  = (blk_loaded == c_nblk - 1);
            desc_valid = 1'b1;
            if (f_n == 1) n_blk1 = n_blk1 + 1;
            blk_loaded = blk_loaded + 1;
        end
    endtask

    always @(negedge aclk) begin
        if (!run_en) begin
            desc_valid = 1'b0;
            desc_fired = 1'b0;
        end else begin
            if (desc_fired) begin
                desc_valid = 1'b0;
                desc_fired = 1'b0;
            end
            if (!desc_valid && blk_loaded < c_nblk) begin
                if (gap_cnt > 0) gap_cnt = gap_cnt - 1;
                else begin
                    load_desc;
                    if (rnd(100) < c_gap) gap_cnt = (rnd(16) == 0) ? 20 + rnd(40) : 1 + rnd(6);
                end
            end
        end
        pix_ready = (c_bp == 0) ? 1'b1 : (rnd(100) >= c_bp);
    end

    // ---------------- monitor (posedge) ----------------
    integer e_u, e_v, e_X, e_Y, e_valid, e_x0, e_y0, e_xf, e_yf;
    integer d_x0, d_y0, d_xf, d_yf, d_valid, sbi, exp_last;
    reg signed [31:0] sX, sY;

    task check_pixel;                                    // one transferred pixel against the next dump line
        integer r;
        begin
            r = $fscanf(fd_crd, "%d %d %d %d %d %d %d %d %d", e_u, e_v, e_X, e_Y, e_valid, e_x0, e_y0, e_xf, e_yf);
            if (r != 9) begin
                $sformat(msgbuf, "%0s: no line for pixel %0d", c_fcrd, pix_seen);
                fatal(msgbuf);
            end
            sbi = sb_rd % SB_N;
            sX = pix_X;  sY = pix_Y;
            d_x0 = sX >>> 16;  d_y0 = sY >>> 16;
            d_xf = pix_X[15:0];  d_yf = pix_Y[15:0];
            d_valid = (sX >= 0) && (sX <= (c_H - 1) * 65536) && (sY >= 0) && (sY <= (c_W - 1) * 65536);
            exp_last = (mon_j == sb_n[sbi] - 1);

            n_pix[c_group] = n_pix[c_group] + 1;
            if (pix_X !== e_X) begin
                mm_x = mm_x + 1;
                $sformat(msgbuf, "%0s %0dx%0d pixel %0d (u,v)=(%0d,%0d): X = %0d, model %0d", c_name, c_W, c_H,
                         pix_seen, e_u, e_v, pix_X, e_X);
                record_fail(msgbuf);
            end
            if (pix_Y !== e_Y) begin
                mm_y = mm_y + 1;
                $sformat(msgbuf, "%0s %0dx%0d pixel %0d (u,v)=(%0d,%0d): Y = %0d, model %0d", c_name, c_W, c_H,
                         pix_seen, e_u, e_v, pix_Y, e_Y);
                record_fail(msgbuf);
            end
            if (sb_u[sbi] != e_u || sb_v0[sbi] + mon_j != e_v) begin
                mm_uv = mm_uv + 1;
                $sformat(msgbuf, "%0s %0dx%0d pixel %0d: descriptor order gives (u,v)=(%0d,%0d), model (%0d,%0d)",
                         c_name, c_W, c_H, pix_seen, sb_u[sbi], sb_v0[sbi] + mon_j, e_u, e_v);
                record_fail(msgbuf);
            end
            if (d_valid != e_valid) begin
                mm_valid = mm_valid + 1;
                $sformat(msgbuf, "%0s pixel %0d: D1 valid = %0d, model %0d", c_name, pix_seen, d_valid, e_valid);
                record_fail(msgbuf);
            end
            if (d_x0 != e_x0 || d_y0 != e_y0) begin
                mm_int = mm_int + 1;
                $sformat(msgbuf, "%0s pixel %0d: (x0,y0) = (%0d,%0d), model (%0d,%0d)", c_name, pix_seen,
                         d_x0, d_y0, e_x0, e_y0);
                record_fail(msgbuf);
            end
            if (d_xf != e_xf || d_yf != e_yf) begin
                mm_frac = mm_frac + 1;
                $sformat(msgbuf, "%0s pixel %0d: (xf,yf) = (%0d,%0d), model (%0d,%0d)", c_name, pix_seen,
                         d_xf, d_yf, e_xf, e_yf);
                record_fail(msgbuf);
            end
            n_side = n_side + 1;
            if (pix_first !== (mon_j == 0) || pix_last !== exp_last[0] || pix_nrows !== sb_nrows[sbi] ||
                pix_slot_top !== sb_st[sbi] || pix_slot_bot !== sb_sbot[sbi] || pix_s_col !== sb_s_col[sbi] ||
                pix_frame_last !== (exp_last[0] && sb_last[sbi])) begin
                mm_side = mm_side + 1;
                $sformat(msgbuf, "%0s pixel %0d (index %0d of a %0d-pixel block): first/last/nrows/slots/s_col/frame_last = %0d/%0d/%0d/%0d/%0d/%0d/%0d do not match the descriptor",
                         c_name, pix_seen, mon_j, sb_n[sbi], pix_first, pix_last, pix_nrows, pix_slot_top,
                         pix_slot_bot, pix_s_col, pix_frame_last);
                record_fail(msgbuf);
            end
            if (pix_frame_last === 1'b1) frame_last_seen = frame_last_seen + 1;
            if (c_group == G_E && d_valid != 0) wrap_valid = wrap_valid + 1;

            // d. worked example of CLAUDE.md: numbers written here, not taken from the vector file
            if (c_group == G_D && e_u == 3 && e_v == 2) begin
                d_seen = d_seen + 1;
                if (pix_X !== 32'sd209715 || pix_Y !== 32'sd288360 || d_x0 != 3 || d_xf != 13107 ||
                    d_y0 != 4 || d_yf != 26216) begin
                    $sformat(msgbuf, "(d) worked example (3,2): X=%0d Y=%0d x0=%0d xf=%0d y0=%0d yf=%0d, expected 209715 288360 3 13107 4 26216",
                             pix_X, pix_Y, d_x0, d_xf, d_y0, d_yf);
                    record_fail(msgbuf);
                end else
                    $display("  (d) worked example (u,v)=(3,2): X=%0d Y=%0d x0=%0d xf=%0d y0=%0d yf=%0d  OK",
                             pix_X, pix_Y, d_x0, d_xf, d_y0, d_yf);
            end

            if (exp_last != 0) begin
                sb_rd = sb_rd + 1;
                mon_j = 0;
            end else
                mon_j = mon_j + 1;
            cyc_last_pix = cyc;
            pix_seen = pix_seen + 1;
        end
    endtask

    always @(posedge aclk) begin
        cyc = cyc + 1;
        if (aresetn && desc_valid && desc_ready === 1'b1) begin          // descriptor taken
            sbi = sb_wr % SB_N;
            sb_u[sbi]    = desc_u;         sb_v0[sbi]   = desc_v0;        sb_n[sbi]     = desc_n;
            sb_nrows[sbi] = desc_nrows;    sb_st[sbi]   = desc_slot_top;  sb_sbot[sbi]  = desc_slot_bot;
            sb_s_col[sbi] = desc_s_col;    sb_last[sbi] = desc_last;
            sb_wr = sb_wr + 1;
            if (blk_fired == 0) cyc_first_desc = cyc;
            blk_fired  = blk_fired + 1;
            desc_fired = 1'b1;
        end
        if (mon_en) begin
            if (prev_v && !prev_r) begin                 // a held pixel must stay valid and unchanged
                n_hold = n_hold + 1;
                if (pix_valid !== 1'b1 || pix_bundle !== prev_bundle) begin
                    mm_hold = mm_hold + 1;
                    $sformat(msgbuf, "%0s pixel %0d: output changed while pix_ready = 0", c_name, pix_seen);
                    record_fail(msgbuf);
                end
            end
            if (pix_valid === 1'b1) begin
                if (pix_seen == 0 && !prev_v) cyc_first_pix = cyc;   // first cycle with pix_valid = 1 (ready or not)
                if (sb_rd == sb_wr) begin
                    $sformat(msgbuf, "%0s: pix_valid = 1 after pixel %0d with no descriptor left (extra pixel)",
                             c_name, pix_seen);
                    record_fail(msgbuf);
                end else if (pix_ready) check_pixel;
                else case_stall = case_stall + 1;
            end else if (pix_valid !== 1'b0) begin
                $sformat(msgbuf, "%0s: pix_valid is X", c_name);
                record_fail(msgbuf);
            end
            prev_v      = (pix_valid === 1'b1);
            prev_r      = pix_ready;
            prev_bundle = pix_bundle;
        end else
            prev_v = 1'b0;
    end

    // ---------------- main thread: acts 1 ns after the clock edge ----------------
    task tick;
        begin
            @(posedge aclk);
            #1;
        end
    endtask

    task run_case;
        integer target, t, limit, total;
        begin
            open_vec(c_fblk, fd_blk);
            open_vec(c_fcrd, fd_crd);
            blk_loaded = 0;  blk_fired = 0;  pix_seen = 0;  sb_wr = 0;  sb_rd = 0;  mon_j = 0;  gap_cnt = 0;
            case_stall = 0;  frame_last_seen = 0;  cyc_first_pix = 0;
            // frame_start with the new coefficients; mon_en is still 1 after a complete frame (the stream must be
            // idle in this cycle) and 0 after an abort (the old frame may still show a pixel)
            run_en  = 1'b0;
            cfg_b11 = c_b[0];  cfg_b12 = c_b[1];  cfg_b13 = c_b[2];
            cfg_b21 = c_b[3];  cfg_b22 = c_b[4];  cfg_b23 = c_b[5];
            frame_start = 1'b1;
            tick;
            frame_start = 1'b0;
            cfg_b11 = $random(seed);  cfg_b12 = $random(seed);  cfg_b13 = $random(seed);   // must not matter
            cfg_b21 = $random(seed);  cfg_b22 = $random(seed);  cfg_b23 = $random(seed);
            prev_v  = 1'b0;
            mon_en  = 1'b1;
            run_en  = 1'b1;

            target = (c_abort != 0) ? c_abort_at : c_npix;
            limit  = 16 * c_npix + 100000;
            t = 0;
            while (pix_seen < target && t < limit) begin
                tick;
                t = t + 1;
            end
            if (pix_seen < target) begin
                $sformat(msgbuf, "%0s %0dx%0d: timeout after %0d of %0d pixels", c_name, c_W, c_H, pix_seen, target);
                fatal(msgbuf);
            end
            run_en = 1'b0;
            total  = cyc_last_pix - cyc_first_desc + 1;  // descriptor cycle .. last pixel cycle, inclusive
            n_cases[c_group] = n_cases[c_group] + 1;
            tot_stall  = tot_stall + case_stall;
            tot_cycles = tot_cycles + total;
            if (cyc_first_pix - cyc_first_desc != LATENCY) begin
                $sformat(msgbuf, "%0s %0dx%0d: first pixel %0d cycles after the first descriptor, expected %0d",
                         c_name, c_W, c_H, cyc_first_pix - cyc_first_desc, LATENCY);
                record_fail(msgbuf);
            end
            if (c_abort == 0) begin
                n_frames = n_frames + 1;
                if (blk_fired != c_nblk || sb_rd != sb_wr || mon_j != 0 || frame_last_seen != 1) begin
                    $sformat(msgbuf, "%0s %0dx%0d: frame end: %0d of %0d descriptors taken, %0d not finished, frame_last seen %0d times",
                             c_name, c_W, c_H, blk_fired, c_nblk, sb_wr - sb_rd, frame_last_seen);
                    record_fail(msgbuf);
                end
                if (c_bp == 0 && c_gap == 0) begin       // 1 pixel per clock, also for 1-pixel blocks
                    n_ii1 = n_ii1 + 1;
                    if (total != c_npix + LATENCY) begin
                        $sformat(msgbuf, "%0s %0dx%0d: %0d cycles for %0d pixels, expected pixels + %0d",
                                 c_name, c_W, c_H, total, c_npix, LATENCY);
                        record_fail(msgbuf);
                    end
                end
                $display("  %c %0s %0dx%0d: %0d blocks, %0d pixels, %0d cycles (pixels + %0d), ready low %0d cycles",
                         "a" + c_group, c_name, c_W, c_H, c_nblk, c_npix, total, total - c_npix, case_stall);
            end else if (c_abort == 1) begin             // reset in the middle of the frame
                n_abort_rst = n_abort_rst + 1;
                mon_en  = 1'b0;
                aresetn = 1'b0;
                repeat (3) tick;
                if (pix_valid !== 1'b0) record_fail("pix_valid not 0 during reset");
                aresetn = 1'b1;
                $display("  %c %0s %0dx%0d: aresetn low after %0d of %0d pixels", "a" + c_group, c_name, c_W, c_H,
                         pix_seen, c_npix);
            end else begin                               // the next frame_start comes right now
                n_abort_fs = n_abort_fs + 1;
                mon_en = 1'b0;
                $display("  %c %0s %0dx%0d: frame_start of the next frame after %0d of %0d pixels", "a" + c_group,
                         c_name, c_W, c_H, pix_seen, c_npix);
            end
            $fclose(fd_blk);
            $fclose(fd_crd);
        end
    endtask

    integer r, total_pix;
    initial begin
        for (i = 0; i < NGRP; i = i + 1) begin
            n_pix[i] = 0;
            n_cases[i] = 0;
        end
        first_fail = 0;
        c_bp = 0;  c_gap = 0;  c_nblk = 0;
        if (!$value$plusargs("VEC_DIR=%s", vecdir)) vecdir = "../../../data/vectors";
        $display("vectors: %0s", vecdir);
        open_vec("coord_gen/cases.txt", fd_cases);

        repeat (16) @(posedge aclk);
        #1 aresetn = 1'b1;
        tick;
        if (pix_valid !== 1'b0) record_fail("pix_valid not 0 after reset");
        if (desc_ready !== 1'b1) record_fail("desc_ready not 1 after reset");

        r = 18;
        while (r == 18) begin
            r = $fscanf(fd_cases, "%d %s %d %d %d %d %d %d %d %d %d %d %d %d %d %d %s %s", c_group, c_name, c_W, c_H,
                        c_b[0], c_b[1], c_b[2], c_b[3], c_b[4], c_b[5], c_nblk, c_npix, c_bp, c_gap, c_abort,
                        c_abort_at, c_fblk, c_fcrd);
            if (r == 18) begin
                if (c_group < 0 || c_group >= NGRP) fatal("cases.txt: bad group");
                run_case;
            end else if (r != -1) fatal("cases.txt: bad line");
        end
        c_bp = 0;
        $sformat(c_name, "after the last frame");
        repeat (20) tick;                                // the stream must stay idle (monitor still on)

        total_pix = 0;
        for (i = 0; i < NGRP; i = i + 1) total_pix = total_pix + n_pix[i];
        if (total_pix == 0 || n_pix[G_A] == 0 || n_pix[G_C] == 0 || n_pix[G_E] == 0 || n_pix[G_F] == 0)
            record_fail("a group has no pixels (empty case list?)");
        if (d_seen != 1) record_fail("(d) worked-example pixel (3,2) not seen exactly once");
        if (tot_stall == 0) record_fail("(c) no cycle with pix_ready = 0 was exercised");
        if (n_blk1 == 0) record_fail("no 1-pixel block was exercised");
        if (n_abort_rst == 0 || n_abort_fs == 0) record_fail("(f) no reset / frame_start abort was exercised");

        $display("pixels compared: a=%0d c=%0d d=%0d e=%0d f=%0d total=%0d   (cases a=%0d c=%0d d=%0d e=%0d f=%0d; b = block planner, not in this module)",
                 n_pix[G_A], n_pix[G_C], n_pix[G_D], n_pix[G_E], n_pix[G_F], total_pix,
                 n_cases[G_A], n_cases[G_C], n_cases[G_D], n_cases[G_E], n_cases[G_F]);
        $display("mismatches: X=%0d Y=%0d (u,v)=%0d valid=%0d (x0,y0)=%0d (xf,yf)=%0d block fields=%0d (of %0d) held output=%0d (of %0d held cycles)",
                 mm_x, mm_y, mm_uv, mm_valid, mm_int, mm_frac, mm_side, n_side, mm_hold, n_hold);
        $display("frames: %0d complete, %0d aborted by aresetn, %0d aborted by frame_start; %0d frames with pix_ready = 1 and no late descriptor, all at pixels + %0d cycles; 1-pixel blocks sent: %0d; cycles with pix_ready = 0 on a valid pixel: %0d; (e) D1-valid pixels: %0d",
                 n_frames, n_abort_rst, n_abort_fs, n_ii1, LATENCY, n_blk1, tot_stall, wrap_valid);
        if (nfail == 0) $display("TEST PASS");
        else            $display("TEST FAIL: %0d failed checks, first: %0s", nfail, first_fail);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("TEST FAIL: timeout");
        $finish;
    end

endmodule
