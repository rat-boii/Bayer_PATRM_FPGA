// Self-checking testbench of rtl/bayer_seq.v (step 5.2, spec/interface.md section 18.2). No vectors needed.
//   python scripts/sim.py --top tb_bayer_seq -f tb/bayer_seq.f
// Two instances: MODES = 3 (Option A built) and MODES = 1 (gray build, Option A must never appear).
// Per job (random W, H, B13, B23, T registers, random gaps before each pass_done):
//   - frame_start exactly one cycle after start_accept, and one cycle after pass_done of a pass that is not the last
//   - pass_* values during every pass = the table of spec 18.1 (gray: B13 / B23, W x H, no offsets, stride 0,
//     WSTRB FF; Option A pass k: T of plane k, W/2 x H/2, o_row = k[1], o_col = k[0], stride 1, WSTRB 55 / AA)
//   - pass_* values do not change during a pass (only together with frame_start)
//   - job_done in the same cycle as the last pass_done, never otherwise; number of passes 1 (gray) or 4
//   - a stray pass_done while idle does nothing; aresetn in the middle of a job returns to idle
// Final line: TEST PASS or TEST FAIL: <reason>.
`timescale 1ns/1ps
module tb_bayer_seq;

    localparam SB = 13;
    reg aclk = 1'b0, aresetn = 1'b0;
    always #5 aclk = ~aclk;

    reg           start_accept = 1'b0, pass_done = 1'b0;
    reg  [1:0]    cfg_mode = 2'd0;
    reg  [SB-1:0] cfg_width = 0, cfg_height = 0;
    reg  [31:0]   cfg_b13 = 0, cfg_b23 = 0;
    reg  [31:0]   t [0:7];

    // DUT A (MODES 3) and DUT G (MODES 1)
    wire          fs_a, jd_a, or_a, oc_a, s2_a, fs_g, jd_g, or_g, oc_g, s2_g;
    wire [1:0]    pi_a, pi_g;
    wire [31:0]   b13_a, b23_a, b13_g, b23_g;
    wire [SB-1:0] w_a, h_a, w_g, h_g;
    wire [7:0]    st_a, st_g;

    bayer_seq #(.MODES(3), .SIZE_BITS(SB)) dut_a (
        .aclk(aclk), .aresetn(aresetn), .start_accept(start_accept), .cfg_mode(cfg_mode),
        .cfg_width(cfg_width), .cfg_height(cfg_height), .cfg_b13(cfg_b13), .cfg_b23(cfg_b23),
        .cfg_t_r_x(t[0]), .cfg_t_r_y(t[1]), .cfg_t_gr_x(t[2]), .cfg_t_gr_y(t[3]),
        .cfg_t_gb_x(t[4]), .cfg_t_gb_y(t[5]), .cfg_t_b_x(t[6]), .cfg_t_b_y(t[7]),
        .pass_done(pass_done), .frame_start(fs_a), .job_done(jd_a), .pass_index(pi_a), .pass_b13(b13_a),
        .pass_b23(b23_a), .pass_width(w_a), .pass_height(h_a), .pass_o_row(or_a), .pass_o_col(oc_a),
        .pass_stride2(s2_a), .pass_wstrb(st_a));
    bayer_seq #(.MODES(1), .SIZE_BITS(SB)) dut_g (
        .aclk(aclk), .aresetn(aresetn), .start_accept(start_accept), .cfg_mode(cfg_mode),
        .cfg_width(cfg_width), .cfg_height(cfg_height), .cfg_b13(cfg_b13), .cfg_b23(cfg_b23),
        .cfg_t_r_x(t[0]), .cfg_t_r_y(t[1]), .cfg_t_gr_x(t[2]), .cfg_t_gr_y(t[3]),
        .cfg_t_gb_x(t[4]), .cfg_t_gb_y(t[5]), .cfg_t_b_x(t[6]), .cfg_t_b_y(t[7]),
        .pass_done(pass_done), .frame_start(fs_g), .job_done(jd_g), .pass_index(pi_g), .pass_b13(b13_g),
        .pass_b23(b23_g), .pass_width(w_g), .pass_height(h_g), .pass_o_row(or_g), .pass_o_col(oc_g),
        .pass_stride2(s2_g), .pass_wstrb(st_g));

    integer nfail = 0, njobs = 0, npasses = 0, seed = 5;
    reg [8*200-1:0] first;
    task fail;
        input [8*200-1:0] m;
        begin
            if (nfail == 0) first = m;
            nfail = nfail + 1;
            if (nfail <= 10) $display("  FAIL %0s", m);
        end
    endtask

    // expected values of pass k for a job with Option A flag a (spec 18.1)
    task check_pass;
        input        a, is_a_dut;
        input [1:0]  k;
        input [1:0]  pi;
        input [31:0] b13, b23;
        input [SB-1:0] w, h;
        input        orow, ocol, s2;
        input [7:0]  st;
        reg   [31:0] eb13, eb23;
        begin
            eb13 = a ? t[2 * k] : cfg_b13;
            eb23 = a ? t[2 * k + 1] : cfg_b23;
            if (pi !== (a ? k : 2'd0) || b13 !== eb13 || b23 !== eb23 ||
                w !== (a ? cfg_width >> 1 : cfg_width) || h !== (a ? cfg_height >> 1 : cfg_height) ||
                orow !== (a & k[1]) || ocol !== (a & k[0]) || s2 !== a ||
                st !== (!a ? 8'hFF : (k[0] ? 8'hAA : 8'h55))) begin
                $sformat(first, "%0s: job %0d pass %0d (Option A %0d): index %0d b13 %h b23 %h W %0d H %0d o %0d%0d s2 %0d strb %h",
                         is_a_dut ? "MODES 3" : "MODES 1", njobs, k, a, pi, b13, b23, w, h, orow, ocol, s2, st);
                fail(first);
            end
        end
    endtask

    // ---- monitor: frame_start timing, values stable during a pass, job_done only with the last pass_done ----
    reg        sa_d = 0, hold_ok = 0;
    reg [92:0] hold_a, hold_g;
    wire [92:0] now_a = {pi_a, b13_a, b23_a, w_a, h_a, or_a, oc_a, s2_a, st_a};
    wire [92:0] now_g = {pi_g, b13_g, b23_g, w_g, h_g, or_g, oc_g, s2_g, st_g};
    always @(posedge aclk) begin
        if (aresetn && hold_ok) begin
            if (!fs_a && now_a !== hold_a) fail("MODES 3: pass values changed without frame_start");
            if (!fs_g && now_g !== hold_g) fail("MODES 1: pass values changed without frame_start");
            if (sa_d && !(fs_a && fs_g)) fail("frame_start not 1 cycle after start_accept");
        end
        hold_a <= now_a; hold_g <= now_g;
        hold_ok <= aresetn;
        sa_d <= start_accept;
    end

    integer i, j, k, gap, passes_a, passes_g, mode_a;
    reg     a_job;

    task one_job;
        input [1:0] mode;
        begin
            cfg_mode = mode;
            cfg_width = 16 * (1 + ($random(seed) & 255));
            cfg_height = 2 * (1 + ($random(seed) & 2047));
            cfg_b13 = $random(seed); cfg_b23 = $random(seed);
            for (i = 0; i < 8; i = i + 1) t[i] = $random(seed);
            a_job = (mode == 2'd1);
            @(negedge aclk) start_accept = 1'b1;
            @(negedge aclk) start_accept = 1'b0;
            if (!(fs_a && fs_g)) fail("frame_start of pass 0 missing");
            passes_a = 0; passes_g = 0;
            for (k = 0; k < 4; k = k + 1) begin
                if (k == 0 || (a_job && k > 0)) begin
                    check_pass(a_job, 1'b1, k, pi_a, b13_a, b23_a, w_a, h_a, or_a, oc_a, s2_a, st_a);
                    if (k == 0) check_pass(1'b0, 1'b0, 0, pi_g, b13_g, b23_g, w_g, h_g, or_g, oc_g, s2_g, st_g);
                    passes_a = passes_a + 1;
                    gap = $random(seed) & 31;
                    repeat (gap) begin
                        @(negedge aclk);
                        if (fs_a || jd_a) fail("frame_start / job_done during a pass");
                    end
                    pass_done = 1'b1;
                    #1;
                    if (jd_a !== (!a_job || k == 3)) fail("MODES 3: job_done wrong at pass_done");
                    if (jd_g !== (k == 0)) fail("MODES 1: job_done wrong at pass_done");
                    @(negedge aclk) pass_done = 1'b0;
                    if (fs_a !== (a_job && k < 3)) fail("MODES 3: frame_start not 1 cycle after pass_done");
                    if (fs_g) fail("MODES 1: frame_start after its only pass");
                    npasses = npasses + 1;
                end
            end
            if (passes_a != (a_job ? 4 : 1)) fail("wrong number of passes");
            // stray pass_done while idle
            repeat (3) @(negedge aclk);
            pass_done = 1'b1; #1;
            if (jd_a || jd_g) fail("job_done from a stray pass_done");
            @(negedge aclk) pass_done = 1'b0;
            if (fs_a || fs_g) fail("frame_start from a stray pass_done");
            njobs = njobs + 1;
        end
    endtask

    initial begin
        for (i = 0; i < 8; i = i + 1) t[i] = 0;
        repeat (4) @(negedge aclk);
        aresetn = 1'b1;
        @(negedge aclk);
        if (fs_a || jd_a || s2_a || st_a !== 8'hFF || fs_g) fail("outputs after reset");
        for (j = 0; j < 200; j = j + 1) one_job(($random(seed) & 1) ? 2'd1 : 2'd0);
        // aresetn in the middle of an Option A job, then a gray and an Option A job
        cfg_mode = 2'd1;
        @(negedge aclk) start_accept = 1'b1;
        @(negedge aclk) start_accept = 1'b0;
        pass_done = 1'b1;
        @(negedge aclk) pass_done = 1'b0;                       // pass 1 starts
        aresetn = 1'b0;
        repeat (3) @(negedge aclk);
        aresetn = 1'b1;
        @(negedge aclk);
        if (pi_a !== 2'd0 || s2_a || st_a !== 8'hFF) fail("pass values not at reset after aresetn");
        pass_done = 1'b1; #1;
        if (jd_a) fail("job_done after aresetn");
        @(negedge aclk) pass_done = 1'b0;
        one_job(2'd0);
        one_job(2'd1);
        // MODE 2 and 3 never start Option A (axil_regs rejects them; here: treated as gray, one pass)
        one_job(2'd2);
        one_job(2'd3);
        $display("tb_bayer_seq: %0d jobs, %0d passes checked in the MODES 3 instance (MODES 1 instance in parallel)",
                 njobs, npasses);
        if (nfail == 0) $display("TEST PASS");
        else            $display("TEST FAIL: %0d errors, first: %0s", nfail, first);
        $finish;
    end

endmodule
