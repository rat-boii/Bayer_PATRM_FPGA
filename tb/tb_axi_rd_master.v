// tb_axi_rd_master: self-checking testbench for rtl/axi_rd_master.v with the HP0 memory model tb/axi_mem.v
// (step 3.4). Plain Verilog (D17).
//
// Vectors: scripts/gen_axi_rd_vectors.py -> data/vectors/axi_rd/ (cases.txt, cmds_*.txt, bursts_*.txt, mem.hex).
// Plusarg: +VEC_DIR=<data/vectors/axi_rd>.
//
// For every case the testbench drives the row commands (valid held until ready, random idle cycles cmd_gap %),
// sets the memory knobs (latency, ARREADY back-pressure, RVALID gaps, accepted bursts, SLVERR burst) and checks
//   - every AR handshake against the expected burst list (address, length, order) = the step 2.2 list or
//     memmodel.split_bursts;
//   - every rd_* beat: rd_data = the memory word at its address (independent copy of mem.hex), rd_slot,
//     rd_word, rd_cmd_last, rd_err = 1 exactly on the beats of the SLVERR burst;
//   - rd_beat count = R handshakes counted on the bus = expected beats; BYTES_RD = 8 x rd_beat count;
//   - nothing extra arrives after the last beat; the master is idle afterwards.
// Groups (cases.txt column 1): 0 a (2.2 schedules), 1 b (directed 4 KB / lengths), 2 c (throughput),
// 3 d (random timing), 4 e (SLVERR), 6 g (reset in the middle). Group h = the protocol checker of axi_mem and the
// simulation checks of the master: 0 violations over all groups.
// Prints per group cases / bursts / beats compared and exactly one final line: TEST PASS or TEST FAIL: <reason>.
`timescale 1ns/1ps
module tb_axi_rd_master;

    localparam [31:0] BASE  = 32'h1000_0000;
    localparam MEM_WORDS    = 16384;
    localparam MAXC         = 65536;
    localparam MAXB         = 65536;
    localparam RST_CYCLES   = 16;
    localparam DRAIN        = 64;

    reg aclk = 1'b0;
    always #5 aclk = ~aclk;                               // 100 MHz
    reg aresetn = 1'b0;

    // ---------------- DUT and memory ----------------
    reg         cmd_valid = 1'b0;
    wire        cmd_ready;
    reg  [31:0] cmd_addr = 32'd0;
    reg  [6:0]  cmd_words = 7'd0;
    reg  [4:0]  cmd_slot = 5'd0;
    wire [5:0]  arid, rid;
    wire [31:0] araddr;
    wire [3:0]  arlen, arcache, arqos;
    wire [2:0]  arsize, arprot;
    wire [1:0]  arburst, arlock, rresp;
    wire        arvalid, arready, rlast, rvalid, rready;
    wire [63:0] rdata;
    wire        rd_valid, rd_cmd_last, rd_beat, rd_err;
    wire [63:0] rd_data;
    wire [4:0]  rd_slot;
    wire [5:0]  rd_word;

    axi_rd_master #(.RD_OUTSTANDING(8)) dut (
        .aclk(aclk), .aresetn(aresetn),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_addr(cmd_addr), .cmd_words(cmd_words),
        .cmd_slot(cmd_slot),
        .m_axi_hp0_arid(arid), .m_axi_hp0_araddr(araddr), .m_axi_hp0_arlen(arlen), .m_axi_hp0_arsize(arsize),
        .m_axi_hp0_arburst(arburst), .m_axi_hp0_arlock(arlock), .m_axi_hp0_arcache(arcache),
        .m_axi_hp0_arprot(arprot), .m_axi_hp0_arqos(arqos), .m_axi_hp0_arvalid(arvalid),
        .m_axi_hp0_arready(arready),
        .m_axi_hp0_rid(rid), .m_axi_hp0_rdata(rdata), .m_axi_hp0_rresp(rresp), .m_axi_hp0_rlast(rlast),
        .m_axi_hp0_rvalid(rvalid), .m_axi_hp0_rready(rready),
        .rd_valid(rd_valid), .rd_data(rd_data), .rd_slot(rd_slot), .rd_word(rd_word), .rd_cmd_last(rd_cmd_last),
        .rd_beat(rd_beat), .rd_err(rd_err)
    );

    axi_mem #(.BASE(BASE), .MEM_WORDS(MEM_WORDS)) mem (
        .aclk(aclk), .aresetn(aresetn),
        .s_arid(arid), .s_araddr(araddr), .s_arlen({4'd0, arlen}), .s_arsize(arsize), .s_arburst(arburst),
        .s_arvalid(arvalid), .s_arready(arready),
        .s_rid(rid), .s_rdata(rdata), .s_rresp(rresp), .s_rlast(rlast), .s_rvalid(rvalid), .s_rready(rready)
    );

    // ---------------- vectors ----------------
    reg [63:0] tbmem [0:MEM_WORDS-1];                     // independent copy of mem.hex
    reg [31:0] c_addr  [0:MAXC-1];
    reg [6:0]  c_words [0:MAXC-1];
    reg [4:0]  c_slot  [0:MAXC-1];
    reg [31:0] e_addr  [0:MAXB-1];
    reg [4:0]  e_beats [0:MAXB-1];
    reg [4:0]  e_slot  [0:MAXB-1];
    reg [5:0]  e_word  [0:MAXB-1];
    reg        e_last  [0:MAXB-1];

    // case parameters
    integer c_group, ncmd, nburst, nbeat, lat_min, lat_max, ar_bp, r_gap, cmd_gap, err_k, abort_at, max_out, cseed;
    reg [8*128-1:0] c_name, f_cmds, f_bursts;
    reg [8*1024-1:0] vecdir, path;

    // run state
    reg     running = 1'b0;
    integer cyc = 0;
    integer ci, ai, ri, rb;                               // command, AR, R burst, R beat indices
    integer n_rd_beat, n_bus_beat, n_err_beat, n_rd_valid;
    integer t_first_cmd, t_first_beat, t_last_beat;
    integer tseed;
    integer nfail = 0;
    reg [8*256-1:0] first_fail;
    reg [8*256-1:0] msg;

    task fail;
        input [8*256-1:0] m;
        begin
            if (nfail == 0) first_fail = m;
            if (nfail < 10) $display("CHECK FAILED at %0t (case %0s): %0s", $time, c_name, m);
            nfail = nfail + 1;
        end
    endtask

    always @(posedge aclk) cyc <= cyc + 1;

    // ---------------- command driver ----------------
    always @(posedge aclk) begin
        if (!running || !aresetn) begin
            cmd_valid <= 1'b0;
        end else begin
            if (cmd_valid && cmd_ready) begin
                if (t_first_cmd < 0) t_first_cmd = cyc;
                ci = ci + 1;
            end
            if (!(cmd_valid && !cmd_ready)) begin        // otherwise hold valid and the payload
                if (ci < ncmd && ({$random(tseed)} % 100) >= cmd_gap) begin
                    cmd_valid <= 1'b1;
                    cmd_addr  <= c_addr[ci];
                    cmd_words <= c_words[ci];
                    cmd_slot  <= c_slot[ci];
                end else
                    cmd_valid <= 1'b0;
            end
        end
    end

    // ---------------- AR monitor ----------------
    always @(posedge aclk) begin
        if (aresetn && arvalid && arready) begin
            if (!running) fail("AR handshake outside a case");
            else if (ai >= nburst) begin
                $sformat(msg, "extra AR addr 0x%08h len %0d after %0d bursts", araddr, arlen + 1, nburst);
                fail(msg);
            end else if (araddr !== e_addr[ai] || {1'b0, arlen} + 5'd1 !== e_beats[ai]) begin
                $sformat(msg, "AR %0d: addr 0x%08h len %0d, expected 0x%08h len %0d", ai, araddr, arlen + 1,
                         e_addr[ai], e_beats[ai]);
                fail(msg);
            end
            ai = ai + 1;
        end
    end

    // ---------------- R beat checker ----------------
    reg [31:0] b_addr;
    always @(posedge aclk) begin
        if (aresetn && rvalid && rready) n_bus_beat = n_bus_beat + 1;
        if (aresetn && rd_beat) n_rd_beat = n_rd_beat + 1;
        if (aresetn && rd_err) n_err_beat = n_err_beat + 1;
        if (aresetn && rd_beat !== rd_valid) fail("rd_beat differs from rd_valid");
        if (aresetn && rd_valid) begin
            n_rd_valid = n_rd_valid + 1;
            if (t_first_beat < 0) t_first_beat = cyc;
            t_last_beat = cyc;
            if (!running) fail("rd_valid outside a case");
            else if (ri >= nburst) fail("extra rd beat after the last expected beat");
            else begin
                b_addr = e_addr[ri] + 8 * rb;
                if (rd_data !== tbmem[(b_addr - BASE) >> 3]) begin
                    $sformat(msg, "beat at 0x%08h (burst %0d beat %0d): data %016h, memory %016h", b_addr, ri, rb,
                             rd_data, tbmem[(b_addr - BASE) >> 3]);
                    fail(msg);
                end
                if (rd_slot !== e_slot[ri] || rd_word !== e_word[ri] + rb ||
                    rd_cmd_last !== (e_last[ri] && rb == e_beats[ri] - 1)) begin
                    $sformat(msg, "beat at 0x%08h: slot %0d word %0d last %b, expected %0d %0d %b", b_addr,
                             rd_slot, rd_word, rd_cmd_last, e_slot[ri], e_word[ri] + rb,
                             e_last[ri] && rb == e_beats[ri] - 1);
                    fail(msg);
                end
                if (rd_err !== (ri == err_k)) begin
                    $sformat(msg, "beat at 0x%08h (burst %0d): rd_err %b, SLVERR burst %0d", b_addr, ri, rd_err, err_k);
                    fail(msg);
                end
                if (rb == e_beats[ri] - 1) begin rb = 0; ri = ri + 1; end
                else rb = rb + 1;
            end
        end
    end

    // ---------------- group statistics ----------------
    integer g_cases [0:7], g_bursts [0:7], g_beats [0:7];
    integer i, fd, fdc, r, a, w, s, wd, la, ncase, t0, limit, exp_err, k, g;
    reg [8*8-1:0] gname;
    real thr_all, thr_ss, ovh;

    initial begin
        for (g = 0; g < 8; g = g + 1) begin g_cases[g] = 0; g_bursts[g] = 0; g_beats[g] = 0; end
        tseed = 1; ci = 0; ai = 0; ri = 0; rb = 0; nburst = 0; ncmd = 0; err_k = -1; c_name = "none";
        n_rd_beat = 0; n_bus_beat = 0; n_err_beat = 0; n_rd_valid = 0;
        t_first_cmd = -1; t_first_beat = -1; t_last_beat = -1;
        if (!$value$plusargs("VEC_DIR=%s", vecdir)) vecdir = "../../../data/vectors/axi_rd";
        $sformat(path, "%0s/mem.hex", vecdir);
        $readmemh(path, tbmem);
        $readmemh(path, mem.mem);
        if (tbmem[0] === 64'bx || tbmem[MEM_WORDS-1] === 64'bx) begin
            $display("TEST FAIL: cannot read %0s", path);
            $finish;
        end
        repeat (RST_CYCLES) @(posedge aclk);
        @(negedge aclk) aresetn = 1'b1;

        $sformat(path, "%0s/cases.txt", vecdir);
        fd = $fopen(path, "r");
        if (fd == 0) begin $display("TEST FAIL: cannot open %0s", path); $finish; end
        ncase = 0;
        while (nfail == 0 && !$feof(fd)) begin
            r = $fscanf(fd, "%d %s %d %d %d %d %d %d %d %d %d %d %d %d %s %s\n", c_group, c_name, ncmd, nburst,
                        nbeat, lat_min, lat_max, ar_bp, r_gap, cmd_gap, err_k, abort_at, max_out, cseed, f_cmds,
                        f_bursts);
            if (r != 16) begin
                if (r > 0) fail("bad line in cases.txt");
            end else begin
                ncase = ncase + 1;
                // load vectors
                $sformat(path, "%0s/%0s", vecdir, f_cmds);
                fdc = $fopen(path, "r");
                if (fdc == 0) fail("cannot open a cmds file");
                for (i = 0; i < ncmd; i = i + 1) begin
                    r = $fscanf(fdc, "%d %d %d\n", a, w, s);
                    c_addr[i] = a; c_words[i] = w; c_slot[i] = s;
                end
                $fclose(fdc);
                $sformat(path, "%0s/%0s", vecdir, f_bursts);
                fdc = $fopen(path, "r");
                if (fdc == 0) fail("cannot open a bursts file");
                for (i = 0; i < nburst; i = i + 1) begin
                    r = $fscanf(fdc, "%d %d %d %d %d\n", a, w, s, wd, la);
                    e_addr[i] = a; e_beats[i] = w; e_slot[i] = s; e_word[i] = wd; e_last[i] = la;
                end
                $fclose(fdc);
                exp_err = 0;
                if (err_k >= 0) exp_err = e_beats[err_k];
                // memory knobs (between transfers, the memory is idle)
                mem.lat_min = lat_min; mem.lat_max = lat_max; mem.ar_bp_pct = ar_bp; mem.r_gap_pct = r_gap;
                mem.max_out = max_out; mem.seed = cseed;
                mem.err_burst = (err_k >= 0) ? mem.ar_count + err_k : -1;
                tseed = cseed + 7;
                // run
                @(negedge aclk);
                ci = 0; ai = 0; ri = 0; rb = 0;
                n_rd_beat = 0; n_bus_beat = 0; n_err_beat = 0; n_rd_valid = 0;
                t_first_cmd = -1; t_first_beat = -1; t_last_beat = -1;
                running = 1'b1;
                t0 = cyc;
                limit = 200 * nbeat + 20000;
                while (nfail == 0 && !(ri == nburst && ai == nburst && ci == ncmd) &&
                       !(abort_at >= 0 && n_rd_valid >= abort_at) && cyc - t0 < limit)
                    @(negedge aclk);
                if (cyc - t0 >= limit) fail("timeout: transfer did not finish");
                if (abort_at >= 0 && nfail == 0) begin
                    // reset in the middle: master and memory together, then check that everything is idle
                    aresetn = 1'b0;
                    running = 1'b0;
                    repeat (RST_CYCLES) @(negedge aclk);
                    aresetn = 1'b1;
                    repeat (DRAIN) @(negedge aclk);
                    if (arvalid || rvalid || rd_valid || !cmd_ready) fail("not idle after the reset");
                    $display("case g %0s: reset after %0d of %0d beats (%0d bursts issued), checked up to the reset",
                             c_name, n_rd_valid, nbeat, ai);
                    g_cases[c_group] = g_cases[c_group] + 1;
                    g_bursts[c_group] = g_bursts[c_group] + ri;
                    g_beats[c_group] = g_beats[c_group] + n_rd_valid;
                end else if (nfail == 0) begin
                    repeat (DRAIN) @(negedge aclk);       // anything extra is caught by the monitors
                    running = 1'b0;
                    if (n_rd_beat != nbeat) begin
                        $sformat(msg, "rd_beat count %0d, expected %0d", n_rd_beat, nbeat); fail(msg);
                    end
                    if (n_bus_beat != nbeat) begin
                        $sformat(msg, "R handshakes on the bus %0d, expected %0d", n_bus_beat, nbeat); fail(msg);
                    end
                    if (8 * n_rd_beat != 8 * n_bus_beat) fail("BYTES_RD != 8 x R handshakes");
                    if (n_err_beat != exp_err) begin
                        $sformat(msg, "rd_err pulses %0d, expected %0d", n_err_beat, exp_err); fail(msg);
                    end
                    if (arvalid || dut.cnt != 0 || dut.s_active || cmd_valid) fail("master not idle after the case");
                    g_cases[c_group] = g_cases[c_group] + 1;
                    g_bursts[c_group] = g_bursts[c_group] + nburst;
                    g_beats[c_group] = g_beats[c_group] + nbeat;
                    if (c_group == 4)
                        $display("case e %0s: SLVERR on burst %0d, %0d rd_err pulses, data unchanged, frame complete (%0d beats, BYTES_RD %0d)",
                                 c_name, err_k, n_err_beat, nbeat, 8 * n_rd_beat);
                    if (c_group == 2) begin
                        thr_all = nbeat * 1.0 / (t_last_beat - t_first_cmd + 1);
                        thr_ss  = nbeat * 1.0 / (t_last_beat - t_first_beat + 1);
                        ovh     = (t_last_beat - t_first_beat + 1 - nbeat) * 1.0 / nburst;
                        $display("THROUGHPUT %0s: %0d bursts, %0d beats, latency %0d, memory accepts %0d: first command -> last beat %0d cycles = %0.4f beats/clk; first beat -> last beat %0d cycles = %0.4f beats/clk; overhead %0.4f cycles per burst",
                                 c_name, nburst, nbeat, lat_min, max_out, t_last_beat - t_first_cmd + 1, thr_all,
                                 t_last_beat - t_first_beat + 1, thr_ss, ovh);
                    end
                end
            end
        end
        $fclose(fd);

        // ---------------- summary ----------------
        mem.report;
        $display("master simulation checks: %0d errors", dut.sim_err);
        for (g = 0; g < 8; g = g + 1)
            if (g_cases[g] != 0) begin
                gname = "abcdefgh" >> (8 * (7 - g));
                $display("group %0s: %0d cases, %0d bursts, %0d beats compared", gname[7:0], g_cases[g],
                         g_bursts[g], g_beats[g]);
            end
        k = 0; a = 0; w = 0;
        for (g = 0; g < 8; g = g + 1) begin k = k + g_cases[g]; a = a + g_bursts[g]; w = w + g_beats[g]; end
        $display("total: %0d cases, %0d bursts, %0d beats compared", k, a, w);
        $display("group h: protocol violations %0d", mem.viol_total);
        if (nfail == 0 && ncase == 0) fail("no cases");
        if (nfail == 0 && mem.viol_total != 0) begin
            $sformat(msg, "%0d AXI protocol violations", mem.viol_total); fail(msg);
        end
        if (nfail == 0 && dut.sim_err != 0) fail("master simulation checks failed");
        if (nfail == 0) $display("TEST PASS");
        else            $display("TEST FAIL: %0d failed checks, first: %0s", nfail, first_fail);
        $finish;
    end

endmodule
