// Self-checking testbench for rtl/bilinear_interp.v (step 3.3).
//
// Needs the model vectors (data/vectors/, not tracked). Run from the repo root:
//   python -m model.gen_vectors
//   python scripts/sim.py --top tb_bilinear_interp -f tb/bilinear_interp.f --plusarg VEC_DIR=data/vectors
// +VEC_DIR=<folder> is the vector folder (default ../../../data/vectors = the repo folder seen from
// build/sim/tb_bilinear_interp/). The file read is <VEC_DIR>/interp_vectors.txt (format: README.md).
// Prints the rows compared per group and exactly one final line: "TEST PASS" or "TEST FAIL: <reason>".
//
// Every pixel that leaves the module is compared (op_d, op_last), and for every pixel the four weights
// w1..w4 are compared inside the module (stage 2 registers, by hierarchical name).
// Groups (letters as in the step 3.3 prompt):
//   a  every row of interp_vectors.txt: D and w1..w4 against the model values in the file
//   b  worked example: xf = 13107, yf = 26216, r = (100,140,120,160) -> w = (31458,20972,7863,5243), D = 120
//   c  corners: xf = yf = 0 (D = r1), xf = 0, yf = 0, xf = yf = 65535, all r = 255 (D = 255), all r = 0 (D = 0),
//      one neighbour 255 and the others 0; the 24-bit sum never exceeds 255 * 65536
//   d  ip_ok = 0 (pixel out of range, D1): op_d = 0 whatever the fractions and neighbours are
//   e  op_ready always 1: N pixels take N + 4 cycles; random back-pressure (op_ready low 0..30 %) and random
//      input gaps: stream equals the reference, outputs hold while stalled
//   f  aresetn in the middle of a stream (running, and while stalled); the next stream is correct
// Checked on every pixel of every group: latency = exactly 4 cycles plus the cycles the pipeline was frozen;
// ip_ready = !(op_valid & !op_ready); wr_stall = op_valid & !op_ready.
// Expected values outside group a come from the D10 formula written out in set_entry; that formula is itself
// compared with every row of the model file (group a load), and the literal expectations (b, D = r1, 255, 0)
// are set as literals on top of it.
`timescale 1ns/1ps
module tb_bilinear_interp;

    localparam CLK_HALF  = 5;                            // 100 MHz
    localparam LATENCY   = 4;                            // spec section 8
    localparam MAXN      = 131072;                       // stimulus entries per stream
    localparam QN        = 16;                           // scoreboard entries (>= 4 pixels in flight)
    localparam STR       = 8 * 320;
    localparam MAX_PRINT = 20;
    localparam NTAG      = 14;
    localparam T_A = 0, T_B = 1, T_C_ZERO = 2, T_C_XF0 = 3, T_C_YF0 = 4, T_C_MAX = 5, T_C_255 = 6, T_C_R0 = 7,
               T_C_ONE = 8, T_D_INV = 9, T_D_OK = 10, T_E_FREE = 11, T_E_BP = 12, T_F = 13;

`ifdef ALT_SEED                                          // second seed: --define ALT_SEED
    localparam SEED0 = 7;
`else
    localparam SEED0 = 31;
`endif
    integer seed = SEED0;

    // ---------------- clock, reset, DUT ----------------
    reg aclk = 1'b0;
    reg aresetn = 1'b0;
    always #CLK_HALF aclk = ~aclk;

    reg         ip_valid = 1'b0;
    wire        ip_ready;
    reg  [15:0] ip_xf = 0, ip_yf = 0;
    reg  [7:0]  ip_r1 = 0, ip_r2 = 0, ip_r3 = 0, ip_r4 = 0;
    reg         ip_ok = 1'b0, ip_last = 1'b0;
    wire        op_valid;
    reg         op_ready = 1'b0;
    wire [7:0]  op_d;
    wire        op_last, wr_stall;

    bilinear_interp dut (
        .aclk(aclk), .aresetn(aresetn),
        .ip_valid(ip_valid), .ip_ready(ip_ready), .ip_xf(ip_xf), .ip_yf(ip_yf),
        .ip_r1(ip_r1), .ip_r2(ip_r2), .ip_r3(ip_r3), .ip_r4(ip_r4), .ip_ok(ip_ok), .ip_last(ip_last),
        .op_valid(op_valid), .op_ready(op_ready), .op_d(op_d), .op_last(op_last), .wr_stall(wr_stall)
    );

    // ---------------- stimulus and expected values of the current stream ----------------
    reg [15:0] s_xf [0:MAXN-1], s_yf [0:MAXN-1];
    reg [31:0] s_r  [0:MAXN-1];                          // {r4, r3, r2, r1}
    reg        s_ok [0:MAXN-1], s_last [0:MAXN-1];
    reg [3:0]  s_tag [0:MAXN-1];
    reg [16:0] e_w1 [0:MAXN-1];
    reg [15:0] e_w2 [0:MAXN-1], e_w3 [0:MAXN-1], e_w4 [0:MAXN-1];
    reg [7:0]  e_d  [0:MAXN-1];                          // expected op_d (0 when ip_ok = 0)

    // ---------------- bookkeeping ----------------
    integer n_d [0:NTAG-1], mm_d [0:NTAG-1], n_w [0:NTAG-1], mm_w [0:NTAG-1];
    integer nfail = 0;
    reg [STR-1:0] first_fail, msgbuf, vecdir, path, junk;
    integer mm_last = 0, mm_lat = 0, mm_hold = 0, mm_proto = 0, mm_acc = 0, mm_ref = 0, mm_cyc = 0, mm_rst = 0;
    integer n_hold = 0, n_acc = 0, n_lat = 0, n_streams = 0, n_resets = 0, n_free = 0, n_file = 0;
    integer tot_cyc = 0, tot_stall = 0;
    integer i, k;

    task record_fail;
        input [STR-1:0] m;
        begin
            if (nfail == 0) first_fail = m;
            nfail = nfail + 1;
            if (nfail <= MAX_PRINT) $display("  FAIL %0s", m);
        end
    endtask

    task fatal;                                          // cannot continue (missing / broken vector file)
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

    // D10 written out (model/patrm.py interp_d10); fills entry i. ok = 0 -> expected output 0 (D1).
    task set_entry;
        input integer i;
        input [15:0]  xf, yf;
        input [7:0]   r1, r2, r3, r4;
        input         ok, last;
        input integer tag;
        reg [16:0] nx, ny, v1;
        reg [31:0] a2, a3, a4, sum;
        reg [15:0] v2, v3, v4;
        begin
            nx = 17'd65536 - {1'b0, xf};
            ny = 17'd65536 - {1'b0, yf};
            a2 = nx * yf;
            a3 = xf * ny;
            a4 = xf * yf;
            v2 = a2[31:16];
            v3 = a3[31:16];
            v4 = a4[31:16];
            v1 = 17'd65536 - ({1'b0, v2} + {1'b0, v3} + {1'b0, v4});
            sum = v1 * r1 + v2 * r2 + v3 * r3 + v4 * r4;
            s_xf[i] = xf;  s_yf[i] = yf;  s_r[i] = {r4, r3, r2, r1};
            s_ok[i] = ok;  s_last[i] = last;  s_tag[i] = tag;
            e_w1[i] = v1;  e_w2[i] = v2;  e_w3[i] = v3;  e_w4[i] = v4;
            e_d[i]  = ok ? sum[23:16] : 8'd0;
            if (sum[31:16] > 255) begin
                mm_ref = mm_ref + 1;
                record_fail("tb reference: D above 255");
            end
        end
    endtask

    task expect_d;                                       // literal expectation on top of the formula
        input integer i;
        input [7:0]   d;
        begin
            if (e_d[i] !== d) begin
                mm_ref = mm_ref + 1;
                $sformat(msgbuf, "tb reference: entry %0d (xf %0d yf %0d) gives D %0d, literal expectation %0d",
                         i, s_xf[i], s_yf[i], e_d[i], d);
                record_fail(msgbuf);
            end
            e_d[i] = d;
        end
    endtask

    // ---------------- scoreboard: pixels taken by the DUT, in order ----------------
    integer q_idx [0:QN-1], q_cyc [0:QN-1], q_stall [0:QN-1];
    integer wp = 0, rp = 0, rp2 = 0;                     // write, output read, weight read
    integer cyc = 0, stall_cnt = 0, out_cnt = 0, in_cnt = 0, drv_idx = 0;
    integer cyc_first_in = 0, cyc_last_out = 0;
    reg       in_acc = 1'b0;                             // the pixel on ip_* was taken at the last clock edge
    reg       prev_stalled = 1'b0;
    reg [8:0] prev_out = 0;
    integer   mj, mt;

    // ---------------- monitor (posedge: values of the cycle that ends here) ----------------
    always @(posedge aclk) begin
        cyc = cyc + 1;
        if (!aresetn) begin
            wp = 0;  rp = 0;  rp2 = 0;
            in_acc = 1'b0;
            prev_stalled = 1'b0;
        end else begin
            // handshake rules (spec sections 0 and 8, 13)
            if (ip_ready !== !(op_valid && !op_ready) || wr_stall !== (op_valid && !op_ready)
                || op_valid === 1'bx) begin
                mm_proto = mm_proto + 1;
                $sformat(msgbuf, "cycle %0d: op_valid %b op_ready %b -> ip_ready %b wr_stall %b", cyc, op_valid,
                         op_ready, ip_ready, wr_stall);
                record_fail(msgbuf);
            end
            if (prev_stalled) begin                      // a stalled output must still be there, unchanged
                n_hold = n_hold + 1;
                if (op_valid !== 1'b1 || {op_d, op_last} !== prev_out) begin
                    mm_hold = mm_hold + 1;
                    $sformat(msgbuf, "cycle %0d: output changed while stalled", cyc);
                    record_fail(msgbuf);
                end
            end
            prev_stalled = op_valid && !op_ready;
            prev_out     = {op_d, op_last};
            if (prev_stalled) stall_cnt = stall_cnt + 1;

            // weights: the pixel in stage 2 moves on at this edge
            if (dut.vld[1] && dut.ce) begin
                if (rp2 == wp) begin
                    mm_proto = mm_proto + 1;
                    record_fail("stage 2 holds a pixel that was never sent");
                end else begin
                    mj = q_idx[rp2 % QN];
                    mt = s_tag[mj];
                    n_w[mt] = n_w[mt] + 1;
                    if (dut.w1 !== e_w1[mj] || dut.w2 !== e_w2[mj] || dut.w3 !== e_w3[mj] || dut.w4 !== e_w4[mj]) begin
                        mm_w[mt] = mm_w[mt] + 1;
                        $sformat(msgbuf, "tag %0d entry %0d (xf %0d yf %0d): w = (%0d,%0d,%0d,%0d), expected (%0d,%0d,%0d,%0d)",
                                 mt, mj, s_xf[mj], s_yf[mj], dut.w1, dut.w2, dut.w3, dut.w4,
                                 e_w1[mj], e_w2[mj], e_w3[mj], e_w4[mj]);
                        record_fail(msgbuf);
                    end
                    rp2 = rp2 + 1;
                end
            end
            // 24-bit sum of the four products: never above 255 * 65536
            if (dut.vld[2] && dut.ce) begin
                n_acc = n_acc + 1;
                if (!(dut.acc <= 24'hFF0000)) begin
                    mm_acc = mm_acc + 1;
                    $sformat(msgbuf, "cycle %0d: sum %0d exceeds 255 * 65536", cyc, dut.acc);
                    record_fail(msgbuf);
                end
            end

            // output transfer
            if (op_valid && op_ready) begin
                if (rp == wp) begin
                    mm_proto = mm_proto + 1;
                    $sformat(msgbuf, "cycle %0d: output pixel without an input pixel (duplicate?)", cyc);
                    record_fail(msgbuf);
                end else begin
                    mj = q_idx[rp % QN];
                    mt = s_tag[mj];
                    n_d[mt] = n_d[mt] + 1;
                    if (op_d !== e_d[mj]) begin
                        mm_d[mt] = mm_d[mt] + 1;
                        $sformat(msgbuf, "tag %0d entry %0d (xf %0d yf %0d r %0d %0d %0d %0d ok %0d): D = %0d, expected %0d",
                                 mt, mj, s_xf[mj], s_yf[mj], s_r[mj][7:0], s_r[mj][15:8], s_r[mj][23:16],
                                 s_r[mj][31:24], s_ok[mj], op_d, e_d[mj]);
                        record_fail(msgbuf);
                    end
                    if (op_last !== s_last[mj]) begin
                        mm_last = mm_last + 1;
                        $sformat(msgbuf, "entry %0d: op_last = %b, expected %b", mj, op_last, s_last[mj]);
                        record_fail(msgbuf);
                    end
                    n_lat = n_lat + 1;                   // 4 cycles + the cycles the pipeline was frozen
                    if (cyc - q_cyc[rp % QN] - (stall_cnt - q_stall[rp % QN]) != LATENCY) begin
                        mm_lat = mm_lat + 1;
                        $sformat(msgbuf, "entry %0d: latency %0d cycles with %0d stall cycles (expected %0d + stalls)",
                                 mj, cyc - q_cyc[rp % QN], stall_cnt - q_stall[rp % QN], LATENCY);
                        record_fail(msgbuf);
                    end
                    rp = rp + 1;
                    out_cnt = out_cnt + 1;
                    cyc_last_out = cyc;
                end
            end

            // input transfer
            if (ip_valid && ip_ready) begin
                if (wp - rp >= LATENCY + 1) begin
                    mm_proto = mm_proto + 1;
                    record_fail("more than 4 pixels inside the module");
                end
                q_idx[wp % QN]   = drv_idx;
                q_cyc[wp % QN]   = cyc;
                q_stall[wp % QN] = stall_cnt;
                wp = wp + 1;
                if (in_cnt == 0) cyc_first_in = cyc;
                in_cnt = in_cnt + 1;
                in_acc = 1'b1;
            end else begin
                in_acc = 1'b0;
            end
        end
    end

    // ---------------- driver (negedge) ----------------
    task drive_idle;                                     // no pixel offered: data lines unknown on purpose
        begin
            ip_valid = 1'b0;
            ip_xf = 16'hxxxx;  ip_yf = 16'hxxxx;
            ip_r1 = 8'hxx;  ip_r2 = 8'hxx;  ip_r3 = 8'hxx;  ip_r4 = 8'hxx;
            ip_ok = 1'bx;  ip_last = 1'bx;
        end
    endtask

    task do_reset;                                       // called at a negedge
        begin
            aresetn = 1'b0;
            drive_idle;
            @(negedge aclk);
            if (op_valid !== 1'b0 || wr_stall !== 1'b0) begin
                mm_rst = mm_rst + 1;
                record_fail("op_valid / wr_stall not 0 after one reset cycle");
            end
            op_ready = rnd(2);
            repeat (2) @(negedge aclk);
            if (op_valid !== 1'b0) begin
                mm_rst = mm_rst + 1;
                record_fail("op_valid not 0 during reset");
            end
            aresetn = 1'b1;
            n_resets = n_resets + 1;
        end
    endtask

    // Send entries 0 .. n-1. bp = percent of cycles with op_ready = 0, gap = percent of cycles in which a
    // waiting pixel is not offered. abort: 0 = whole stream; 1 = aresetn after abort_at output pixels;
    // 2 = the same, but op_ready is held low first so that the reset hits a full, stalled pipeline.
    // free = 1 (needs bp = gap = 0): checks that the n pixels take exactly n + 4 cycles.
    task run_stream;
        input integer n, bp, gap, abort, abort_at, free;
        integer idx, hold_left, c0, s0;
        reg     done;
        begin
            idx = 0;  out_cnt = 0;  in_cnt = 0;  done = 1'b0;  hold_left = 6;
            c0 = cyc;  s0 = stall_cnt;
            while (!done) begin
                @(negedge aclk);
                if (ip_valid && in_acc) begin
                    idx = idx + 1;
                    drive_idle;
                end
                if (out_cnt == n) begin
                    done = 1'b1;
                end else if (abort != 0 && out_cnt >= abort_at && (abort == 1 || hold_left == 0)) begin
                    if (abort == 2 && !(op_valid && wr_stall)) begin
                        mm_rst = mm_rst + 1;
                        record_fail("reset-while-stalled case: the pipeline was not stalled");
                    end
                    do_reset;
                    done = 1'b1;
                end else begin
                    if (!ip_valid && idx < n && (gap == 0 || rnd(100) >= gap)) begin
                        ip_xf = s_xf[idx];  ip_yf = s_yf[idx];
                        ip_r1 = s_r[idx][7:0];    ip_r2 = s_r[idx][15:8];
                        ip_r3 = s_r[idx][23:16];  ip_r4 = s_r[idx][31:24];
                        ip_ok = s_ok[idx];  ip_last = s_last[idx];
                        drv_idx  = idx;
                        ip_valid = 1'b1;
                    end
                    op_ready = (bp == 0) || (rnd(100) >= bp);
                    if (abort == 2 && out_cnt >= abort_at) begin
                        op_ready  = 1'b0;
                        hold_left = hold_left - 1;
                    end
                end
            end
            if (abort == 0) begin
                if (in_cnt != n) begin
                    mm_proto = mm_proto + 1;
                    record_fail("pixels sent and pixels received differ");
                end
                if (free) begin
                    n_free = n_free + 1;
                    if (cyc_last_out - cyc_first_in + 1 != n + LATENCY) begin
                        mm_cyc = mm_cyc + 1;
                        $sformat(msgbuf, "%0d pixels took %0d cycles, expected %0d", n,
                                 cyc_last_out - cyc_first_in + 1, n + LATENCY);
                        record_fail(msgbuf);
                    end
                end
            end
            n_streams = n_streams + 1;
            $display("  stream %0d: %0d pixels out, op_ready low %0d %%, gaps %0d %%, abort %0d: %0d cycles, %0d stalled",
                     n_streams, out_cnt, bp, gap, abort, cyc - c0, stall_cnt - s0);
        end
    endtask

    // ---------------- stimulus builders ----------------
    integer fd, f_xf, f_yf, f_r1, f_r2, f_r3, f_r4, f_w1, f_w2, f_w3, f_w4, f_d, r, ch;

    task load_file;                                      // interp_vectors.txt -> entries 0 .. n_file-1
        input integer tag;
        reg more;
        begin
            $sformat(path, "%0s/interp_vectors.txt", vecdir);
            fd = $fopen(path, "r");
            if (fd == 0) begin
                $sformat(msgbuf, "cannot open %0s (run python -m model.gen_vectors, or pass +VEC_DIR)", path);
                fatal(msgbuf);
            end
            more = 1'b1;
            while (more) begin                           // '#' lines at the top
                ch = $fgetc(fd);
                if (ch == "#") r = $fgets(junk, fd);
                else begin
                    if (ch != -1) r = $ungetc(ch, fd);
                    more = 1'b0;
                end
            end
            n_file = 0;
            r = 11;
            while (r == 11) begin
                r = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d", f_xf, f_yf, f_r1, f_r2, f_r3, f_r4,
                            f_w1, f_w2, f_w3, f_w4, f_d);
                if (r == 11) begin
                    if (n_file >= MAXN) fatal("interp_vectors.txt has more rows than MAXN");
                    set_entry(n_file, f_xf, f_yf, f_r1, f_r2, f_r3, f_r4, 1'b1, 1'b0, tag);
                    if (e_w1[n_file] != f_w1 || e_w2[n_file] != f_w2 || e_w3[n_file] != f_w3
                        || e_w4[n_file] != f_w4 || e_d[n_file] != f_d) begin
                        mm_ref = mm_ref + 1;
                        $sformat(msgbuf, "tb reference differs from the model, interp_vectors.txt row %0d", n_file + 1);
                        record_fail(msgbuf);
                    end
                    e_w1[n_file] = f_w1;  e_w2[n_file] = f_w2;  e_w3[n_file] = f_w3;  e_w4[n_file] = f_w4;
                    e_d[n_file]  = f_d;                  // the model values are what the DUT is compared with
                    n_file = n_file + 1;
                end
            end
            if (r != -1) begin
                $sformat(msgbuf, "%0s: bad line after row %0d", path, n_file);
                fatal(msgbuf);
            end
            $fclose(fd);
            if (n_file < 100000) fatal("interp_vectors.txt has fewer than 100000 rows");
            s_last[n_file-1] = 1'b1;
        end
    endtask

    task fill_random;                                    // n random pixels; ok_pct = percent with ip_ok = 1
        input integer n, ok_pct, tag_ok, tag_inv;
        integer j;
        reg     ok;
        begin
            for (j = 0; j < n; j = j + 1) begin
                ok = rnd(100) < ok_pct;
                set_entry(j, rnd(65536), rnd(65536), rnd(256), rnd(256), rnd(256), rnd(256), ok,
                          (j == n - 1) || (rnd(50) == 0), ok ? tag_ok : tag_inv);
                if (!ok) expect_d(j, 8'd0);
            end
        end
    endtask

    integer nc;
    reg [15:0] edge_v [0:4];
    task fill_corners;                                   // group c -> entries 0 .. nc-1
        integer j, m, t;
        reg [7:0] a;
        begin
            nc = 0;
            for (j = 0; j < 2000; j = j + 1) begin       // xf = yf = 0: D = r1 exactly, every r1
                a = (j < 256) ? j : rnd(256);
                set_entry(nc, 16'd0, 16'd0, a, rnd(256), rnd(256), rnd(256), 1'b1, 1'b0, T_C_ZERO);
                expect_d(nc, a);
                nc = nc + 1;
            end
            for (j = 0; j < 5000; j = j + 1) begin       // xf = 0 edge: only r1 and r2 count
                set_entry(nc, 16'd0, rnd(65536), rnd(256), rnd(256), rnd(256), rnd(256), 1'b1, 1'b0, T_C_XF0);
                if (e_w3[nc] !== 16'd0 || e_w4[nc] !== 16'd0) begin
                    mm_ref = mm_ref + 1;
                    record_fail("tb reference: xf = 0 but w3 or w4 not 0");
                end
                nc = nc + 1;
            end
            for (j = 0; j < 5000; j = j + 1) begin       // yf = 0 edge: only r1 and r3 count
                set_entry(nc, rnd(65536), 16'd0, rnd(256), rnd(256), rnd(256), rnd(256), 1'b1, 1'b0, T_C_YF0);
                if (e_w2[nc] !== 16'd0 || e_w4[nc] !== 16'd0) begin
                    mm_ref = mm_ref + 1;
                    record_fail("tb reference: yf = 0 but w2 or w4 not 0");
                end
                nc = nc + 1;
            end
            for (j = 0; j < 1000; j = j + 1) begin       // xf = yf = 65535
                set_entry(nc, 16'hFFFF, 16'hFFFF, rnd(256), rnd(256), rnd(256), rnd(256), 1'b1, 1'b0, T_C_MAX);
                nc = nc + 1;
            end
            edge_v[0] = 16'd0;  edge_v[1] = 16'd1;  edge_v[2] = 16'd32768;  edge_v[3] = 16'hFFFE;  edge_v[4] = 16'hFFFF;
            for (j = 0; j < 10000; j = j + 1) begin      // flat 255 stays 255 (weights sum to exactly 65536)
                if (j < 25) set_entry(nc, edge_v[j / 5], edge_v[j % 5], 8'd255, 8'd255, 8'd255, 8'd255, 1'b1, 1'b0, T_C_255);
                else        set_entry(nc, rnd(65536), rnd(65536), 8'd255, 8'd255, 8'd255, 8'd255, 1'b1, 1'b0, T_C_255);
                expect_d(nc, 8'd255);
                nc = nc + 1;
            end
            for (j = 0; j < 2000; j = j + 1) begin       // flat 0 stays 0
                set_entry(nc, rnd(65536), rnd(65536), 8'd0, 8'd0, 8'd0, 8'd0, 1'b1, 1'b0, T_C_R0);
                expect_d(nc, 8'd0);
                nc = nc + 1;
            end
            for (m = 0; m < 4; m = m + 1)                // one neighbour 255, the others 0 (and the edge fractions)
                for (j = 0; j < 2000; j = j + 1) begin
                    t = (j < 25);
                    set_entry(nc, t ? edge_v[j / 5] : rnd(65536), t ? edge_v[j % 5] : rnd(65536),
                              (m == 0) ? 8'd255 : 8'd0, (m == 1) ? 8'd255 : 8'd0,
                              (m == 2) ? 8'd255 : 8'd0, (m == 3) ? 8'd255 : 8'd0, 1'b1, 1'b0, T_C_ONE);
                    nc = nc + 1;
                end
            s_last[nc-1] = 1'b1;
        end
    endtask

    function integer grp_d;                              // rows compared in tags lo .. hi
        input integer lo, hi;
        integer j;
        begin
            grp_d = 0;
            for (j = lo; j <= hi; j = j + 1) grp_d = grp_d + n_d[j];
        end
    endfunction

    // ---------------- main ----------------
    integer tot_d, tot_w, tot_mm_d, tot_mm_w, bp_i;
    initial begin
        for (i = 0; i < NTAG; i = i + 1) begin
            n_d[i] = 0;  mm_d[i] = 0;  n_w[i] = 0;  mm_w[i] = 0;
        end
        if (!$value$plusargs("VEC_DIR=%s", vecdir)) vecdir = "../../../data/vectors";
        drive_idle;
        repeat (16) @(negedge aclk);
        aresetn = 1'b1;

        // a: every model row, one pixel per clock
        load_file(T_A);
        $display("group a: %0d rows from %0s", n_file, path);
        run_stream(n_file, 0, 0, 0, 0, 1);

        // b: worked example
        set_entry(0, 16'd13107, 16'd26216, 8'd100, 8'd140, 8'd120, 8'd160, 1'b1, 1'b1, T_B);
        if (e_w1[0] !== 17'd31458 || e_w2[0] !== 16'd20972 || e_w3[0] !== 16'd7863 || e_w4[0] !== 16'd5243) begin
            mm_ref = mm_ref + 1;
            record_fail("tb reference: worked example weights");
        end
        e_w1[0] = 17'd31458;  e_w2[0] = 16'd20972;  e_w3[0] = 16'd7863;  e_w4[0] = 16'd5243;
        expect_d(0, 8'd120);
        $display("group b: worked example");
        run_stream(1, 0, 0, 0, 0, 1);

        // c: corners
        fill_corners;
        $display("group c: %0d corner rows", nc);
        run_stream(nc, 0, 0, 0, 0, 1);
        run_stream(nc, 20, 10, 0, 0, 0);

        // d: out-of-range pixels (ip_ok = 0) give 0
        fill_random(20000, 50, T_D_OK, T_D_INV);
        $display("group d: 20000 random rows, half of them with ip_ok = 0");
        run_stream(20000, 0, 0, 0, 0, 1);
        run_stream(20000, 15, 15, 0, 0, 0);

        // e: latency / throughput, then back-pressure and gaps
        $display("group e: latency, back-pressure, gaps");
        fill_random(50000, 100, T_E_FREE, T_E_FREE);
        run_stream(50000, 0, 0, 0, 0, 1);
        fill_random(1, 100, T_E_FREE, T_E_FREE);
        run_stream(1, 0, 0, 0, 0, 1);
        fill_random(5, 100, T_E_FREE, T_E_FREE);
        run_stream(5, 0, 0, 0, 0, 1);
        for (bp_i = 0; bp_i <= 30; bp_i = bp_i + 10) begin
            fill_random(40000, 90, T_E_BP, T_E_BP);
            run_stream(40000, bp_i, (bp_i == 0) ? 30 : 20, 0, 0, 0);
        end
        fill_random(40000, 90, T_E_BP, T_E_BP);
        run_stream(40000, 30, 0, 0, 0, 0);
        load_file(T_E_BP);                               // the model rows once more, stalled
        run_stream(n_file, 30, 20, 0, 0, 0);

        // f: reset in the middle of a stream, then a correct stream
        $display("group f: reset in the middle of a stream");
        for (k = 0; k < 12; k = k + 1) begin
            fill_random(600, 90, T_F, T_F);
            run_stream(600, (k % 3) * 15, (k % 2) * 20, 1 + (k % 2), 50 + rnd(400), 0);
            fill_random(2000, 90, T_F, T_F);
            run_stream(2000, (k % 4) * 10, (k % 3) * 10, 0, 0, (k % 4 == 0) && (k % 3 == 0));
        end

        @(negedge aclk);
        if (op_valid !== 1'b0) record_fail("op_valid still 1 after the last stream");

        // ---------------- report ----------------
        tot_d = 0;  tot_w = 0;  tot_mm_d = 0;  tot_mm_w = 0;
        for (i = 0; i < NTAG; i = i + 1) begin
            tot_d = tot_d + n_d[i];  tot_w = tot_w + n_w[i];
            tot_mm_d = tot_mm_d + mm_d[i];  tot_mm_w = tot_mm_w + mm_w[i];
        end
        $display("rows compared (D / weights) and mismatches:");
        $display("  a  model vectors           %0d / %0d   D mismatches %0d, weight mismatches %0d", n_d[T_A], n_w[T_A], mm_d[T_A], mm_w[T_A]);
        $display("  b  worked example          %0d / %0d   D mismatches %0d, weight mismatches %0d", n_d[T_B], n_w[T_B], mm_d[T_B], mm_w[T_B]);
        $display("  c  xf = yf = 0 (D = r1)    %0d / %0d   D mismatches %0d, weight mismatches %0d", n_d[T_C_ZERO], n_w[T_C_ZERO], mm_d[T_C_ZERO], mm_w[T_C_ZERO]);
        $display("  c  xf = 0 edge             %0d / %0d   D mismatches %0d, weight mismatches %0d", n_d[T_C_XF0], n_w[T_C_XF0], mm_d[T_C_XF0], mm_w[T_C_XF0]);
        $display("  c  yf = 0 edge             %0d / %0d   D mismatches %0d, weight mismatches %0d", n_d[T_C_YF0], n_w[T_C_YF0], mm_d[T_C_YF0], mm_w[T_C_YF0]);
        $display("  c  xf = yf = 65535         %0d / %0d   D mismatches %0d, weight mismatches %0d", n_d[T_C_MAX], n_w[T_C_MAX], mm_d[T_C_MAX], mm_w[T_C_MAX]);
        $display("  c  all r = 255 (D = 255)   %0d / %0d   D mismatches %0d, weight mismatches %0d", n_d[T_C_255], n_w[T_C_255], mm_d[T_C_255], mm_w[T_C_255]);
        $display("  c  all r = 0 (D = 0)       %0d / %0d   D mismatches %0d, weight mismatches %0d", n_d[T_C_R0], n_w[T_C_R0], mm_d[T_C_R0], mm_w[T_C_R0]);
        $display("  c  one neighbour 255       %0d / %0d   D mismatches %0d, weight mismatches %0d", n_d[T_C_ONE], n_w[T_C_ONE], mm_d[T_C_ONE], mm_w[T_C_ONE]);
        $display("  d  ip_ok = 0 (D = 0)       %0d / %0d   D mismatches %0d, weight mismatches %0d", n_d[T_D_INV], n_w[T_D_INV], mm_d[T_D_INV], mm_w[T_D_INV]);
        $display("  d  ip_ok = 1, same streams %0d / %0d   D mismatches %0d, weight mismatches %0d", n_d[T_D_OK], n_w[T_D_OK], mm_d[T_D_OK], mm_w[T_D_OK]);
        $display("  e  op_ready always 1       %0d / %0d   D mismatches %0d, weight mismatches %0d", n_d[T_E_FREE], n_w[T_E_FREE], mm_d[T_E_FREE], mm_w[T_E_FREE]);
        $display("  e  back-pressure, gaps     %0d / %0d   D mismatches %0d, weight mismatches %0d", n_d[T_E_BP], n_w[T_E_BP], mm_d[T_E_BP], mm_w[T_E_BP]);
        $display("  f  reset                   %0d / %0d   D mismatches %0d, weight mismatches %0d", n_d[T_F], n_w[T_F], mm_d[T_F], mm_w[T_F]);
        $display("rows per group: a=%0d b=%0d c=%0d d=%0d e=%0d f=%0d total=%0d (weights compared on %0d)",
                 grp_d(T_A, T_A), grp_d(T_B, T_B), grp_d(T_C_ZERO, T_C_ONE), grp_d(T_D_INV, T_D_OK),
                 grp_d(T_E_FREE, T_E_BP), grp_d(T_F, T_F), tot_d, tot_w);
        $display("mismatches: D %0d, weights %0d, op_last %0d, latency %0d (of %0d pixels), hold %0d (of %0d stalled cycles), handshake %0d, sum above 255*65536 %0d (of %0d), N+4 cycles %0d (of %0d streams), reset %0d (of %0d resets), tb reference %0d",
                 tot_mm_d, tot_mm_w, mm_last, mm_lat, n_lat, mm_hold, n_hold, mm_proto, mm_acc, n_acc, mm_cyc,
                 n_free, mm_rst, n_resets, mm_ref);
        $display("streams %0d, clock cycles %0d, stalled cycles %0d, seed %0d", n_streams, cyc, stall_cnt, SEED0);
        if (nfail == 0 && (n_d[T_A] < 100000 || n_d[T_C_255] < 10000 || n_d[T_D_INV] == 0 || n_hold == 0
                           || n_resets < 12))
            record_fail("a check group did not run");
        if (nfail == 0) $display("TEST PASS");
        else            $display("TEST FAIL: %0d failed checks, first: %0s", nfail, first_fail);
        $finish;
    end

    initial begin                                        // watchdog
        #200_000_000;
        $display("TEST FAIL: timeout");
        $finish;
    end

endmodule
