// tb_out_path: self-checking testbench for the output path (step 3.5), plain Verilog (D17):
//     bilinear_interp (pass-through) -> out_fifo -> axi_wr_master -> tb/axi_mem.v (HP1 model at DST 0x1800_0000)
// bilinear_interp runs with xf = yf = 0 and ip_ok = 1, so w1 = 65536 and D = r1 exactly (r2..r4 random, weight 0).
// It is in the chain because WR_STALL is its output (spec sections 8, 13): op_valid & !op_ready.
//
// Vectors: scripts/gen_out_path_vectors.py -> data/vectors/out_path/cases.txt (frames: the model's exp_*.hex and
// directed frames; expected AW lists = memmodel.split_bursts per output row). Plusargs: +VEC_DIR=<data/vectors>,
// +DUMP_DIR=<dir for the memory dump> (default: the simulation folder).
//
// Per case: memory filled with a canary, frame_start with W, H, DST; pixels fed with random ip_valid gaps (ip_gap %);
// memory knobs set (AWREADY / WREADY back-pressure, B latency, AWs accepted, SLVERR burst). Checks:
//   a/b  every AW handshake == expected list (address, length, order); at wr_frame_done the memory is dumped with
//        $writememh, read back and compared with the frame byte for byte; the rest of the window still holds the
//        canary (no stray writes)
//   c    (throughput cases) the pixel stream is never stalled (ip_valid & !ip_ready never), cycles reported
//   d    op_ready = 0 only with out_fifo full and the packer holding 7 bytes; cases that fill the FIFO report it
//   e    wr_err = 1 exactly in the cycle after the B response of the SLVERR burst, never otherwise
//   f    wr_beat count = W handshakes on the bus = W*H/8 (BYTES_WR = 8 x that); wr_stall count = the testbench's
//        own count of op_valid & !op_ready cycles
//   g    wr_frame_done exactly once, and only when every burst of the frame has its B response (checked in every
//        case; a failure is reported as "group g check")
//   h    reset of the whole chain and the memory in the middle of a frame, then the next frame complete
//   i    axi_mem protocol checker: 0 violations; simulation checks of out_fifo / axi_wr_master: 0 errors
// Final line exactly: TEST PASS or TEST FAIL: <reason>.
`timescale 1ns/1ps
module tb_out_path;

    localparam [31:0] DST   = 32'h1800_0000;
    localparam MEM_WORDS    = 8192;                       // 64 KB window
    localparam MAXAW        = 4096;
    localparam RST_CYCLES   = 16;
    localparam DRAIN        = 100;
    localparam [63:0] CANARY = 64'hC3C3_C3C3_C3C3_C3C3;

    reg aclk = 1'b0;
    always #5 aclk = ~aclk;
    reg aresetn = 1'b0;

    // ---------------- chain ----------------
    reg         ip_valid = 1'b0;
    wire        ip_ready;
    reg  [7:0]  ip_r1 = 8'd0, ip_r2 = 8'd0, ip_r3 = 8'd0, ip_r4 = 8'd0;
    reg         ip_last = 1'b0;
    wire        op_valid, op_ready, op_last, wr_stall;
    wire [7:0]  op_d;
    reg         frame_start = 1'b0;
    reg  [12:0] cfg_width = 13'd0, cfg_height = 13'd0;
    wire        wq_valid, wq_ready;
    wire [63:0] wq_data;
    wire [6:0]  wq_count;
    wire [5:0]  awid, wid, bid, rid;
    wire [31:0] awaddr;
    wire [3:0]  awlen, awcache, awqos;
    wire [2:0]  awsize, awprot;
    wire [1:0]  awburst, awlock, bresp, rresp;
    wire        awvalid, awready, wlast, wvalid, wready, bvalid, bready, rlast, rvalid, arready;
    wire [63:0] wdata, rdata;
    wire [7:0]  wstrb;
    wire        wr_beat, wr_frame_done, wr_err;

    bilinear_interp bi (
        .aclk(aclk), .aresetn(aresetn),
        .ip_valid(ip_valid), .ip_ready(ip_ready), .ip_xf(16'd0), .ip_yf(16'd0),
        .ip_r1(ip_r1), .ip_r2(ip_r2), .ip_r3(ip_r3), .ip_r4(ip_r4), .ip_ok(1'b1), .ip_last(ip_last),
        .op_valid(op_valid), .op_ready(op_ready), .op_d(op_d), .op_last(op_last), .wr_stall(wr_stall)
    );

    out_fifo of (
        .aclk(aclk), .aresetn(aresetn), .frame_start(frame_start), .cfg_stride2(1'b0), .cfg_o_col(1'b0),
        .op_valid(op_valid), .op_ready(op_ready), .op_d(op_d), .op_last(op_last),
        .wq_valid(wq_valid), .wq_ready(wq_ready), .wq_data(wq_data), .wq_count(wq_count)
    );

    axi_wr_master #(.WR_OUTSTANDING(8)) wm (
        .aclk(aclk), .aresetn(aresetn), .frame_start(frame_start),
        .cfg_dst_addr(DST), .cfg_width(cfg_width), .cfg_height(cfg_height),
        .cfg_stride2(1'b0), .cfg_o_row(1'b0), .cfg_wstrb(8'hFF),
        .wq_valid(wq_valid), .wq_ready(wq_ready), .wq_data(wq_data), .wq_count(wq_count),
        .m_axi_hp1_awid(awid), .m_axi_hp1_awaddr(awaddr), .m_axi_hp1_awlen(awlen), .m_axi_hp1_awsize(awsize),
        .m_axi_hp1_awburst(awburst), .m_axi_hp1_awlock(awlock), .m_axi_hp1_awcache(awcache),
        .m_axi_hp1_awprot(awprot), .m_axi_hp1_awqos(awqos), .m_axi_hp1_awvalid(awvalid),
        .m_axi_hp1_awready(awready),
        .m_axi_hp1_wid(wid), .m_axi_hp1_wdata(wdata), .m_axi_hp1_wstrb(wstrb), .m_axi_hp1_wlast(wlast),
        .m_axi_hp1_wvalid(wvalid), .m_axi_hp1_wready(wready),
        .m_axi_hp1_bid(bid), .m_axi_hp1_bresp(bresp), .m_axi_hp1_bvalid(bvalid), .m_axi_hp1_bready(bready),
        .wr_beat(wr_beat), .wr_frame_done(wr_frame_done), .wr_err(wr_err)
    );

    axi_mem #(.BASE(DST), .MEM_WORDS(MEM_WORDS)) mem (
        .aclk(aclk), .aresetn(aresetn),
        .s_arid(6'd0), .s_araddr(32'd0), .s_arlen(8'd0), .s_arsize(3'd3), .s_arburst(2'b01), .s_arvalid(1'b0),
        .s_arready(arready),
        .s_rid(rid), .s_rdata(rdata), .s_rresp(rresp), .s_rlast(rlast), .s_rvalid(rvalid), .s_rready(1'b1),
        .s_awid(awid), .s_awaddr(awaddr), .s_awlen({4'd0, awlen}), .s_awsize(awsize), .s_awburst(awburst),
        .s_awvalid(awvalid), .s_awready(awready),
        .s_wid(wid), .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(wlast), .s_wvalid(wvalid), .s_wready(wready),
        .s_bid(bid), .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready)
    );

    // ---------------- vectors ----------------
    reg [63:0] img  [0:MEM_WORDS-1];                      // expected frame (= pixel stream)
    reg [63:0] dmp  [0:MEM_WORDS-1];                      // memory dump read back
    reg [31:0] e_addr  [0:MAXAW-1];
    reg [4:0]  e_beats [0:MAXAW-1];

    integer c_group, W, H, nburst, aw_bp, w_bp, b_lat_min, b_lat_max, ip_gap, err_k, abort_at, max_out, cseed;
    reg [8*128-1:0] c_name, f_img, f_aw;
    reg [8*1024-1:0] vecdir, dumpdir, path, dpath;

    // run state
    reg     running = 1'b0;
    integer cyc = 0;
    integer npix, nwords;
    integer pi, ai, bk;                                   // pixels accepted, AWs seen, B responses seen
    integer n_wbus, n_wr_beat, n_wr_stall, n_own_stall, n_err, n_done, n_ipstall, n_full;
    integer t_first_px, t_last_px, t_last_b, t_done;
    integer tseed;
    reg     exp_wr_err;
    integer nfail = 0;
    integer n_dump_cmp = 0, n_done_checks = 0, n_cnt_checks = 0, w_before_aw0;
    reg [8*256-1:0] first_fail, msg;

    task fail;
        input [8*256-1:0] m;
        begin
            if (nfail == 0) first_fail = m;
            if (nfail < 10) $display("CHECK FAILED at %0t (case %0s): %0s", $time, c_name, m);
            nfail = nfail + 1;
        end
    endtask

    always @(posedge aclk) cyc <= cyc + 1;

    // ---------------- pixel driver ----------------
    always @(posedge aclk) begin
        if (!running || !aresetn) begin
            ip_valid <= 1'b0;
        end else begin
            if (ip_valid && ip_ready) begin
                if (t_first_px < 0) t_first_px = cyc;
                t_last_px = cyc;
                pi = pi + 1;
            end
            if (!(ip_valid && !ip_ready)) begin
                if (pi < npix && ({$random(tseed)} % 100) >= ip_gap) begin
                    ip_valid <= 1'b1;
                    ip_r1    <= img[pi >> 3][8 * (pi & 7) +: 8];
                    ip_r2    <= $random(tseed);
                    ip_r3    <= $random(tseed);
                    ip_r4    <= $random(tseed);
                    ip_last  <= (pi == npix - 1);
                end else
                    ip_valid <= 1'b0;
            end
        end
    end

    // ---------------- monitors ----------------
    integer k, mism, first_bad;
    always @(posedge aclk) begin
        if (aresetn) begin
            // AW stream
            if (awvalid && awready) begin
                if (!running) fail("AW handshake outside a case");
                else if (ai >= nburst) begin
                    $sformat(msg, "extra AW addr 0x%08h len %0d after %0d bursts", awaddr, awlen + 1, nburst); fail(msg);
                end else if (awaddr !== e_addr[ai] || {1'b0, awlen} + 5'd1 !== e_beats[ai]) begin
                    $sformat(msg, "AW %0d: addr 0x%08h len %0d, expected 0x%08h len %0d", ai, awaddr, awlen + 1,
                             e_addr[ai], e_beats[ai]);
                    fail(msg);
                end
                ai = ai + 1;
            end
            if (wvalid && wready) n_wbus = n_wbus + 1;
            if (wr_beat) n_wr_beat = n_wr_beat + 1;
            if (wr_stall) n_wr_stall = n_wr_stall + 1;
            if (op_valid && !op_ready) begin
                n_own_stall = n_own_stall + 1;
                // out_fifo back-pressure only when full with 7 bytes in the packer (spec section 9)
                if (!(of.count == 64 && of.pidx == 3'd7)) fail("op_ready = 0 while out_fifo is not full");
                else n_full = n_full + 1;
            end
            if (ip_valid && !ip_ready) n_ipstall = n_ipstall + 1;
            // wr_err: one cycle after the B response of the SLVERR burst, never otherwise
            if (wr_err !== exp_wr_err) begin
                $sformat(msg, "wr_err = %b after B response %0d, SLVERR burst %0d", wr_err, bk - 1, err_k); fail(msg);
            end
            if (wr_err) n_err = n_err + 1;
            exp_wr_err = 1'b0;
            if (bvalid && bready) begin
                exp_wr_err = (bk == err_k);
                t_last_b = cyc;
                bk = bk + 1;
            end
            // group g: frame done only after every B response; the memory holds the whole frame by then
            if (wr_frame_done) begin
                n_done = n_done + 1;
                t_done = cyc;
                n_done_checks = n_done_checks + 1;
                if (!running) fail("group g check: wr_frame_done outside a case");
                else if (bk != nburst || ai != nburst) begin
                    $sformat(msg, "group g check: wr_frame_done with %0d of %0d writes outstanding (%0d AWs issued)",
                             nburst - bk, nburst, ai);
                    fail(msg);
                end
                if (n_done == 1 && running) begin
                    mem.dump(dpath, 0, nwords - 1);
                    for (k = 0; k < nwords; k = k + 1) dmp[k] = 64'bx;
                    $readmemh(dpath, dmp, 0, nwords - 1);
                    mism = 0; first_bad = -1;
                    for (k = 0; k < nwords; k = k + 1)
                        if (dmp[k] !== img[k]) begin
                            mism = mism + 1;
                            if (first_bad < 0) first_bad = k;
                        end
                    if (mism != 0) begin
                        $sformat(msg, "%0sdump at wr_frame_done: %0d of %0d words differ, first at byte %0d: %016h, expected %016h",
                                 (bk != nburst) ? "group g check: " : "", mism, nwords, 8 * first_bad,
                                 dmp[first_bad], img[first_bad]);
                        fail(msg);
                    end
                    for (k = nwords; k < MEM_WORDS; k = k + 1)
                        if (mem.mem[k] !== CANARY && mism >= 0) begin
                            $sformat(msg, "stray write: word at byte %0d after the frame changed", 8 * k);
                            fail(msg);
                            mism = -1;
                        end
                    n_dump_cmp = n_dump_cmp + 1;
                end
            end
        end
    end

    // ---------------- main ----------------
    integer g_cases [0:7], g_bursts [0:7], g_bytes [0:7];
    integer i, fd, fda, r, a, n, ncase, t0, limit, g, tb_, tby;
    reg [8*8-1:0] gname;

    initial begin
        for (g = 0; g < 8; g = g + 1) begin g_cases[g] = 0; g_bursts[g] = 0; g_bytes[g] = 0; end
        tseed = 1; pi = 0; ai = 0; bk = 0; npix = 0; nburst = 0; err_k = -1; c_name = "none"; exp_wr_err = 1'b0;
        n_wbus = 0; n_wr_beat = 0; n_wr_stall = 0; n_own_stall = 0; n_err = 0; n_done = 0; n_ipstall = 0; n_full = 0;
        t_first_px = -1; t_last_px = -1; t_last_b = -1; t_done = -1;
        if (!$value$plusargs("VEC_DIR=%s", vecdir)) vecdir = "../../../data/vectors";
        if (!$value$plusargs("DUMP_DIR=%s", dumpdir)) dumpdir = ".";
        $sformat(dpath, "%0s/out_path_dump.hex", dumpdir);
        repeat (RST_CYCLES) @(posedge aclk);
        @(negedge aclk) aresetn = 1'b1;

        $sformat(path, "%0s/out_path/cases.txt", vecdir);
        fd = $fopen(path, "r");
        if (fd == 0) begin $display("TEST FAIL: cannot open %0s", path); $finish; end
        ncase = 0;
        while (nfail == 0 && !$feof(fd)) begin
            r = $fscanf(fd, "%d %s %d %d %d %d %d %d %d %d %d %d %d %d %s %s\n", c_group, c_name, W, H, nburst,
                        aw_bp, w_bp, b_lat_min, b_lat_max, ip_gap, err_k, abort_at, max_out, cseed, f_img, f_aw);
            if (r != 16) begin
                if (r > 0) fail("bad line in cases.txt");
            end else begin
                ncase = ncase + 1;
                npix = W * H;
                nwords = npix / 8;
                if (nwords > MEM_WORDS || nburst > MAXAW) fail("case too large for the testbench");
                $sformat(path, "%0s/%0s", vecdir, f_img);
                for (i = 0; i < nwords; i = i + 1) img[i] = 64'bx;
                $readmemh(path, img, 0, nwords - 1);
                if (img[0] === 64'bx || img[nwords - 1] === 64'bx) fail("cannot read the frame file");
                $sformat(path, "%0s/%0s", vecdir, f_aw);
                fda = $fopen(path, "r");
                if (fda == 0) fail("cannot open an AW list");
                for (i = 0; i < nburst; i = i + 1) begin
                    r = $fscanf(fda, "%d %d\n", a, n);
                    e_addr[i] = a; e_beats[i] = n;
                end
                $fclose(fda);
                for (i = 0; i < MEM_WORDS; i = i + 1) mem.mem[i] = CANARY;
                mem.aw_bp_pct = aw_bp; mem.w_bp_pct = w_bp; mem.b_lat_min = b_lat_min; mem.b_lat_max = b_lat_max;
                mem.max_out_wr = max_out; mem.seed = cseed;
                mem.b_err_burst = (err_k >= 0) ? mem.aw_count + err_k : -1;
                w_before_aw0 = mem.w_before_aw;
                tseed = cseed + 11;
                // frame
                @(negedge aclk);
                pi = 0; ai = 0; bk = 0; exp_wr_err = 1'b0;
                n_wbus = 0; n_wr_beat = 0; n_wr_stall = 0; n_own_stall = 0; n_err = 0; n_done = 0; n_ipstall = 0;
                n_full = 0; t_first_px = -1; t_last_px = -1; t_last_b = -1; t_done = -1;
                cfg_width = W; cfg_height = H;
                frame_start = 1'b1;
                @(negedge aclk);
                frame_start = 1'b0;
                running = 1'b1;
                t0 = cyc;
                limit = 100 * nwords + 200 * nburst + 20000;
                while (nfail == 0 && n_done == 0 && !(abort_at >= 0 && pi >= abort_at) && cyc - t0 < limit)
                    @(negedge aclk);
                if (cyc - t0 >= limit) begin
                    $sformat(msg, "timeout: %0d of %0d pixels in, %0d of %0d AWs, %0d B responses", pi, npix, ai,
                             nburst, bk);
                    fail(msg);
                end
                if (abort_at >= 0 && nfail == 0) begin
                    // reset in the middle of the frame: the whole chain and the memory
                    aresetn = 1'b0;
                    running = 1'b0;
                    repeat (RST_CYCLES) @(negedge aclk);
                    aresetn = 1'b1;
                    repeat (DRAIN) @(negedge aclk);
                    if (awvalid || wvalid || bvalid || op_valid || wq_valid || wr_frame_done)
                        fail("not idle after the reset");
                    $display("case h %0s: reset after %0d of %0d pixels (%0d AWs, %0d B responses), checked up to the reset",
                             c_name, pi, npix, ai, bk);
                    g_cases[c_group] = g_cases[c_group] + 1;
                    g_bursts[c_group] = g_bursts[c_group] + ai;
                end else if (nfail == 0) begin
                    repeat (DRAIN) @(negedge aclk);       // anything extra is caught by the monitors
                    running = 1'b0;
                    n_cnt_checks = n_cnt_checks + 1;
                    if (n_done != 1) begin $sformat(msg, "group g check: wr_frame_done %0d times", n_done); fail(msg); end
                    if (ai != nburst) begin $sformat(msg, "%0d AWs, expected %0d", ai, nburst); fail(msg); end
                    if (n_wbus != nwords) begin
                        $sformat(msg, "W handshakes on the bus %0d, expected %0d", n_wbus, nwords); fail(msg);
                    end
                    if (n_wr_beat != n_wbus) begin
                        $sformat(msg, "wr_beat count %0d, W handshakes %0d (BYTES_WR %0d vs %0d)", n_wr_beat, n_wbus,
                                 8 * n_wr_beat, 8 * n_wbus);
                        fail(msg);
                    end
                    if (n_wr_stall != n_own_stall) begin
                        $sformat(msg, "wr_stall count %0d, own count of op_valid & !op_ready %0d", n_wr_stall,
                                 n_own_stall);
                        fail(msg);
                    end
                    if (n_err != ((err_k >= 0) ? 1 : 0)) begin
                        $sformat(msg, "wr_err pulses %0d, expected %0d", n_err, (err_k >= 0) ? 1 : 0); fail(msg);
                    end
                    if (awvalid || wvalid || wq_valid || of.pidx != 0 || wm.outst != 0 || wm.active)
                        fail("output path not idle after the frame");
                    if (c_group == 2 && n_ipstall != 0) begin
                        $sformat(msg, "throughput case: pixel stream stalled %0d cycles", n_ipstall); fail(msg);
                    end
                    g_cases[c_group] = g_cases[c_group] + 1;
                    g_bursts[c_group] = g_bursts[c_group] + nburst;
                    g_bytes[c_group] = g_bytes[c_group] + npix;
                    if (c_group == 2)
                        $display("THROUGHPUT %0s: %0d pixels, %0d W beats, %0d bursts, B latency %0d: first pixel -> last pixel %0d cycles (%0d stall cycles, wr_stall %0d) = %0.4f pixels/clk, %0.4f W beats/clk; last pixel -> last BRESP %0d cycles; last pixel -> wr_frame_done %0d cycles",
                                 c_name, npix, nwords, nburst, b_lat_min, t_last_px - t_first_px + 1, n_ipstall,
                                 n_wr_stall, npix * 1.0 / (t_last_px - t_first_px + 1),
                                 nwords * 1.0 / (t_last_px - t_first_px + 1), t_last_b - t_last_px,
                                 t_done - t_last_px);
                    if (c_group == 3 && n_full != 0)
                        $display("case d %0s: out_fifo full -> op_ready = 0 in %0d cycles (wr_stall %0d), ip_ready = 0 in %0d cycles; frame correct",
                                 c_name, n_full, n_wr_stall, n_ipstall);
                    if (mem.w_before_aw != w_before_aw0)
                        $display("case %0s: %0d W beats accepted by the memory before their AW", c_name,
                                 mem.w_before_aw - w_before_aw0);
                    if (c_group == 4)
                        $display("case e %0s: SLVERR on burst %0d, wr_err pulses %0d, frame complete and byte-exact",
                                 c_name, err_k, n_err);
                    if (c_group == 6)
                        $display("case g %0s: last BRESP in cycle %0d, wr_frame_done in cycle %0d, 0 writes outstanding then",
                                 c_name, t_last_b, t_done);
                end
            end
        end
        $fclose(fd);

        // ---------------- summary ----------------
        mem.report;
        $display("simulation checks: out_fifo %0d errors, axi_wr_master %0d errors", of.sim_err, wm.sim_err);
        for (g = 0; g < 8; g = g + 1)
            if (g_cases[g] != 0) begin
                gname = "abcdefgh" >> (8 * (7 - g));
                $display("group %0s: %0d cases, %0d bursts, %0d bytes compared", gname[7:0], g_cases[g], g_bursts[g],
                         g_bytes[g]);
            end
        tb_ = 0; tby = 0; k = 0;
        for (g = 0; g < 8; g = g + 1) begin k = k + g_cases[g]; tb_ = tb_ + g_bursts[g]; tby = tby + g_bytes[g]; end
        $display("total: %0d cases, %0d bursts, %0d bytes compared (%0d memory dumps compared)", k, tb_, tby, n_dump_cmp);
        $display("group f: counters checked in %0d frames; group g: %0d wr_frame_done checks", n_cnt_checks,
                 n_done_checks);
        $display("W beats accepted before their AW (all cases): %0d", mem.w_before_aw);
        $display("group i: protocol violations %0d", mem.viol_total);
        if (nfail == 0 && ncase == 0) fail("no cases");
        if (nfail == 0 && mem.viol_total != 0) begin
            $sformat(msg, "%0d AXI protocol violations", mem.viol_total); fail(msg);
        end
        if (nfail == 0 && (of.sim_err != 0 || wm.sim_err != 0)) fail("simulation checks of the RTL failed");
        if (nfail == 0) $display("TEST PASS");
        else            $display("TEST FAIL: %0d failed checks, first: %0s", nfail, first_fail);
        $finish;
    end

endmodule
