// Self-checking testbench for rtl/axil_regs.v (step 3.1).
//
// Needs the vectors from `python scripts/gen_axil_vectors.py` (data/vectors/axil_regs_*.hex, from spec/regs.json
// and model/job.py). Run from the repo root:
//   python scripts/gen_axil_vectors.py
//   python scripts/sim.py --top tb_axil_regs -f tb/axil_regs.f --incdir rtl
// Prints the number of checks per group and exactly one final line: "TEST PASS" or "TEST FAIL: <reason>".
//
// Groups: a reset values, b read/write/WSTRB/RO/unmapped, c START pulse + BUSY + lock, d error codes and priority,
//         e DONE / W1C / interrupt, f counters, g worked-example job image, p protocol monitor (every cycle),
//         i (step 3.7) BUSY before the engine reacts, BUS_ERROR at the end of a job.
// AXI-Lite master: random idle gaps, AW/W together, AW first or W first with a random gap, random BREADY/RREADY.
// Engine stub (models ctrl_fsm): BUSY one cycle after start_accept (busy_lag more cycles in group i), done_set in
// the last BUSY cycle, counters.
`timescale 1ns/1ps
module tb_axil_regs;

`include "patrm_regs.vh"

    localparam CLK_HALF      = 5;                        // 100 MHz
    localparam BLOCK_LEN_MAX = 64;                       // gray build (D15)
    localparam [2:0] MODES   = 3'b001;
    localparam NSLOT         = 32;                       // word slots of the 7-bit address space
    localparam K_UNMAPPED = 0, K_CFG = 1, K_CTRL = 2, K_STATUS = 3, K_COUNTER = 4, K_BUILD_ID = 5;
    localparam G_A = 0, G_B = 1, G_C = 2, G_D = 3, G_E = 4, G_F = 5, G_G = 6, G_P = 7, G_I = 8;

    localparam [31:0] C_START = 32'd1 << PATRM_CTRL_START_LSB;
    localparam [31:0] C_IRQ   = 32'd1 << PATRM_CTRL_IRQ_EN_LSB;
    localparam [31:0] S_BUSY  = 32'd1 << PATRM_STATUS_BUSY_LSB;
    localparam [31:0] S_DONE  = 32'd1 << PATRM_STATUS_DONE_LSB;
    localparam [31:0] S_ERROR = 32'd1 << PATRM_STATUS_ERROR_LSB;
    localparam [31:0] S_ERRC  = ((32'd1 << PATRM_STATUS_ERR_CODE_W) - 1) << PATRM_STATUS_ERR_CODE_LSB;

`ifdef ALT_SEED                                          // second seed: --define ALT_SEED
    integer seed = 7;
`else
    integer seed = 31;
`endif

    // ---------------- clock, reset, DUT ----------------
    reg aclk = 1'b0;
    reg aresetn = 1'b0;
    always #CLK_HALF aclk = ~aclk;

    reg  [6:0]  awaddr = 0;  reg awvalid = 0;  wire awready;
    reg  [31:0] wdata = 0;   reg [3:0] wstrb = 0;  reg wvalid = 0;  wire wready;
    wire [1:0]  bresp;       wire bvalid;  reg bready = 0;
    reg  [6:0]  araddr = 0;  reg arvalid = 0;  wire arready;
    wire [31:0] rdata;       wire [1:0] rresp;  wire rvalid;  reg rready = 0;

    wire [1:0]  cfg_mode;
    wire [31:0] cfg_src_addr, cfg_dst_addr;
    wire [12:0] cfg_width, cfg_height, cfg_block_len;
    wire [31:0] cfg_b11, cfg_b12, cfg_b13, cfg_b21, cfg_b22, cfg_b23;
    wire [31:0] cfg_t_r_x, cfg_t_r_y, cfg_t_gr_x, cfg_t_gr_y, cfg_t_gb_x, cfg_t_gb_y, cfg_t_b_x, cfg_t_b_y;
    wire        start_accept, interrupt;
    reg         busy = 0, done_set = 0, bus_err = 0;
    reg  [31:0] cnt_cycles = 0, cnt_bytes_rd = 0, cnt_bytes_wr = 0, cnt_rd_stall = 0, cnt_wr_stall = 0;

    axil_regs #(.BLOCK_LEN_MAX(BLOCK_LEN_MAX), .MODES(MODES)) dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axil_awaddr(awaddr), .s_axil_awprot(3'b000), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
        .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
        .s_axil_araddr(araddr), .s_axil_arprot(3'b000), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
        .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
        .cfg_mode(cfg_mode), .cfg_src_addr(cfg_src_addr), .cfg_dst_addr(cfg_dst_addr),
        .cfg_width(cfg_width), .cfg_height(cfg_height),
        .cfg_b11(cfg_b11), .cfg_b12(cfg_b12), .cfg_b13(cfg_b13), .cfg_b21(cfg_b21), .cfg_b22(cfg_b22), .cfg_b23(cfg_b23),
        .cfg_t_r_x(cfg_t_r_x), .cfg_t_r_y(cfg_t_r_y), .cfg_t_gr_x(cfg_t_gr_x), .cfg_t_gr_y(cfg_t_gr_y),
        .cfg_t_gb_x(cfg_t_gb_x), .cfg_t_gb_y(cfg_t_gb_y), .cfg_t_b_x(cfg_t_b_x), .cfg_t_b_y(cfg_t_b_y),
        .cfg_block_len(cfg_block_len),
        .start_accept(start_accept), .busy(busy), .done_set(done_set), .bus_err(bus_err),
        .cnt_cycles(cnt_cycles), .cnt_bytes_rd(cnt_bytes_rd), .cnt_bytes_wr(cnt_bytes_wr),
        .cnt_rd_stall(cnt_rd_stall), .cnt_wr_stall(cnt_wr_stall),
        .interrupt(interrupt)
    );

    // ---------------- vectors ----------------
    reg [31:0] spec [0:3*NSLOT-1];                       // reset[32], rw_mask[32], kind[32]
    reg [31:0] jobv [0:63];                              // n, then (offset, value) pairs
    function [31:0] s_reset; input integer i; s_reset = spec[i];           endfunction
    function [31:0] s_rw;    input integer i; s_rw    = spec[NSLOT + i];   endfunction
    function [31:0] s_kind;  input integer i; s_kind  = spec[2*NSLOT + i]; endfunction

    // ---------------- check bookkeeping ----------------
    integer nchk [0:8];
    integer nfail = 0;
    reg [8*200-1:0] first_fail;
    reg [8*200-1:0] msgbuf;

    task record_fail;
        input integer g;
        input [8*200-1:0] m;
        begin
            if (nfail == 0) first_fail = m;
            nfail = nfail + 1;
            if (nfail <= 20) $display("  FAIL %0s", m);
        end
    endtask

    task chk;
        input integer g;
        input ok;
        input [8*160-1:0] m;
        begin
            nchk[g] = nchk[g] + 1;
            if (ok !== 1'b1) begin
                $sformat(msgbuf, "(%c) %0s", "a" + g, m);
                record_fail(g, msgbuf);
            end
        end
    endtask

    task chk_eq;
        input integer g;
        input [31:0] got;
        input [31:0] exp;
        input [8*120-1:0] m;
        begin
            nchk[g] = nchk[g] + 1;
            if (got !== exp) begin
                $sformat(msgbuf, "(%c) %0s: got 0x%08h, expected 0x%08h", "a" + g, m, got, exp);
                record_fail(g, msgbuf);
            end
        end
    endtask

    function integer rnd;                                // 0 .. n-1
        input integer n;
        begin
            rnd = ($random(seed) & 32'h7FFF_FFFF) % n;
        end
    endfunction

    // ---------------- AXI-Lite master ----------------
    integer wr_order = -1;                               // -1 random, 0 together, 1 AW first, 2 W first
    integer max_gap  = 3;
    reg     backpressure = 1'b1;
    integer n_order [0:2];
    reg [31:0] b_status;                                 // dut STATUS in the first BVALID cycle of the last write
    reg        b_start;                                  // start_accept in that cycle

    task axil_write;
        input [6:0]  addr;
        input [31:0] data;
        input [3:0]  strb;
        integer order, gap, k;
        reg aw_done, w_done, b_done, b_seen;
        begin
            order = (wr_order < 0) ? rnd(3) : wr_order;
            n_order[order] = n_order[order] + 1;
            gap = rnd(max_gap + 1);
            repeat (rnd(3)) @(posedge aclk);
            #1;
            awaddr = addr; wdata = data; wstrb = strb;
            aw_done = 0; w_done = 0; k = 0;
            awvalid = (order != 2) || (gap == 0);
            wvalid  = (order != 1) || (gap == 0);
            while (!(aw_done && w_done)) begin
                @(posedge aclk);
                if (awvalid && awready) aw_done = 1;
                if (wvalid && wready)   w_done  = 1;
                #1;
                k = k + 1;
                if (aw_done) awvalid = 0; else if (k >= gap) awvalid = 1;
                if (w_done)  wvalid  = 0; else if (k >= gap) wvalid  = 1;
            end
            awaddr = $random(seed); wdata = $random(seed); wstrb = $random(seed);   // garbage while not valid
            b_done = 0; b_seen = 0;
            while (!b_done) begin
                bready = backpressure ? rnd(2) : 1'b1;
                @(posedge aclk);
                if (bvalid && !b_seen) begin
                    b_seen = 1;
                    b_status = dut.status_word;
                    b_start  = start_accept;
                end
                if (bvalid && bready) b_done = 1;
                #1;
            end
            bready = 0;
        end
    endtask

    task axil_read;
        input  [6:0]  addr;
        output [31:0] data;
        reg ar_done, r_done;
        begin
            repeat (rnd(3)) @(posedge aclk);
            #1;
            araddr = addr; arvalid = 1; ar_done = 0;
            while (!ar_done) begin
                @(posedge aclk);
                if (arvalid && arready) ar_done = 1;
                #1;
            end
            arvalid = 0; araddr = $random(seed);
            r_done = 0;
            while (!r_done) begin
                rready = backpressure ? rnd(2) : 1'b1;
                @(posedge aclk);
                if (rvalid && rready) begin
                    data = rdata;
                    r_done = 1;
                end
                #1;
            end
            rready = 0;
        end
    endtask

    // ---------------- engine stub (stands in for ctrl_fsm) ----------------
    reg     hold_job = 0;
    integer job_len  = 5;
    integer job_cnt  = 0;
    reg     stub_load = 0;
    integer busy_lag = 0;                                // extra cycles before busy rises (group i)
    integer lag_cnt  = 0;
    reg     stub_done = 0;                               // group i: done_set while busy has not risen
    reg [31:0] ld_cycles, ld_bytes_rd, ld_bytes_wr, ld_rd_stall, ld_wr_stall;

    always @(posedge aclk) begin
        if (!aresetn) begin
            busy <= 0; done_set <= 0; job_cnt <= 0; lag_cnt <= 0;
            cnt_cycles <= 0; cnt_bytes_rd <= 0; cnt_bytes_wr <= 0; cnt_rd_stall <= 0; cnt_wr_stall <= 0;
        end else if (done_set && !busy) begin
            done_set <= 0;
        end else if (start_accept && !busy) begin
            if (busy_lag == 0) busy <= 1;
            lag_cnt <= busy_lag; job_cnt <= 0;
            cnt_cycles <= 0; cnt_bytes_rd <= 0; cnt_bytes_wr <= 0; cnt_rd_stall <= 0; cnt_wr_stall <= 0;
        end else if (lag_cnt != 0) begin
            if (stub_done) begin
                done_set <= 1; lag_cnt <= 0;
            end else begin
                lag_cnt <= lag_cnt - 1;
                if (lag_cnt == 1) busy <= 1;
            end
        end else if (busy) begin
            job_cnt      <= job_cnt + 1;
            cnt_cycles   <= cnt_cycles + 1;
            cnt_bytes_rd <= cnt_bytes_rd + 8;
            cnt_bytes_wr <= cnt_bytes_wr + (job_cnt[0] ? 8 : 0);
            cnt_rd_stall <= cnt_rd_stall + job_cnt[1];
            cnt_wr_stall <= cnt_wr_stall + job_cnt[2];
            if (done_set) begin
                busy <= 0; done_set <= 0;
            end else if (!hold_job && job_cnt >= job_len - 1) begin
                done_set <= 1;
            end
        end else if (stub_load) begin
            cnt_cycles <= ld_cycles; cnt_bytes_rd <= ld_bytes_rd; cnt_bytes_wr <= ld_bytes_wr;
            cnt_rd_stall <= ld_rd_stall; cnt_wr_stall <= ld_wr_stall;
        end
    end

    // ---------------- protocol monitor (group p) and start-pulse counter ----------------
    reg        bvalid_q = 0, bready_q = 0, rvalid_q = 0, rready_q = 0;
    reg [31:0] rdata_q = 0;
    integer    mon_cycles = 0, mon_viol = 0, irq_viol = 0;
    integer    start_pulses = 0, start_run = 0, start_max = 0;

    always @(posedge aclk) begin
        if (aresetn) begin
            mon_cycles = mon_cycles + 1;
            if (bvalid_q && !bready_q && !bvalid)                        mon_viol = mon_viol + 1;
            if (rvalid_q && !rready_q && (!rvalid || rdata !== rdata_q)) mon_viol = mon_viol + 1;
            if (bvalid && bresp !== 2'b00)                               mon_viol = mon_viol + 1;
            if (rvalid && rresp !== 2'b00)                               mon_viol = mon_viol + 1;
            if (awready !== wready)                                      mon_viol = mon_viol + 1;
            if (awready && !(awvalid && wvalid))                         mon_viol = mon_viol + 1;
            if (awvalid && awready && arvalid && arready)                mon_viol = mon_viol + 1;
            if (interrupt !== (dut.ctrl_irq_en & dut.st_done))           irq_viol = irq_viol + 1;
            if (start_accept) begin
                start_run = start_run + 1;
                if (start_run == 1) start_pulses = start_pulses + 1;
                if (start_run > start_max) start_max = start_run;
            end else begin
                start_run = 0;
            end
        end
        bvalid_q = bvalid; bready_q = bready; rvalid_q = rvalid; rready_q = rready; rdata_q = rdata;
    end

    // ---------------- helpers ----------------
    reg [31:0] shadow [0:NSLOT-1];                       // expected value of every config register
    reg [31:0] rv;
    integer i, j, n, p0;

    function [31:0] cfg_out;                             // configuration output for word slot i
        input integer s;
        begin
            case (s)
                PATRM_REG_CTRL >> 2:      cfg_out = {29'd0, cfg_mode, 1'b0};
                PATRM_REG_SRC_ADDR >> 2:  cfg_out = cfg_src_addr;
                PATRM_REG_DST_ADDR >> 2:  cfg_out = cfg_dst_addr;
                PATRM_REG_WIDTH >> 2:     cfg_out = cfg_width;
                PATRM_REG_HEIGHT >> 2:    cfg_out = cfg_height;
                PATRM_REG_B11 >> 2:       cfg_out = cfg_b11;
                PATRM_REG_B12 >> 2:       cfg_out = cfg_b12;
                PATRM_REG_B13 >> 2:       cfg_out = cfg_b13;
                PATRM_REG_B21 >> 2:       cfg_out = cfg_b21;
                PATRM_REG_B22 >> 2:       cfg_out = cfg_b22;
                PATRM_REG_B23 >> 2:       cfg_out = cfg_b23;
                PATRM_REG_T_R_X >> 2:     cfg_out = cfg_t_r_x;
                PATRM_REG_T_R_Y >> 2:     cfg_out = cfg_t_r_y;
                PATRM_REG_T_GR_X >> 2:    cfg_out = cfg_t_gr_x;
                PATRM_REG_T_GR_Y >> 2:    cfg_out = cfg_t_gr_y;
                PATRM_REG_T_GB_X >> 2:    cfg_out = cfg_t_gb_x;
                PATRM_REG_T_GB_Y >> 2:    cfg_out = cfg_t_gb_y;
                PATRM_REG_T_B_X >> 2:     cfg_out = cfg_t_b_x;
                PATRM_REG_T_B_Y >> 2:     cfg_out = cfg_t_b_y;
                PATRM_REG_BLOCK_LEN >> 2: cfg_out = cfg_block_len;
                default:                  cfg_out = 32'hDEAD_BEEF;
            endcase
        end
    endfunction

    function [31:0] merge;
        input [31:0] o;
        input [31:0] nw;
        input [3:0]  s;
        integer k;
        begin
            for (k = 0; k < 4; k = k + 1)
                merge[8*k +: 8] = s[k] ? nw[8*k +: 8] : o[8*k +: 8];
        end
    endfunction

    task cfg_write;                                      // write a config register and track it (idle only)
        input [6:0]  off;
        input [31:0] val;
        begin
            axil_write(off, val, 4'hF);
            shadow[off >> 2] = val & s_rw(off >> 2);
        end
    endtask

    task set_cfg;
        input [31:0] src, dst, w, h, bl;
        begin
            cfg_write(PATRM_REG_SRC_ADDR, src);
            cfg_write(PATRM_REG_DST_ADDR, dst);
            cfg_write(PATRM_REG_WIDTH, w);
            cfg_write(PATRM_REG_HEIGHT, h);
            cfg_write(PATRM_REG_BLOCK_LEN, bl);
        end
    endtask

    task good_cfg;                                       // a configuration that passes every check (gray)
        set_cfg(32'h1000_0000, 32'h1800_0000, 640, 480, BLOCK_LEN_MAX);
    endtask

    task wait_idle;
        begin
            @(posedge aclk);
            while (busy || start_accept) @(posedge aclk);
            #1;
        end
    endtask

    task clear_status;
        axil_write(PATRM_REG_STATUS, S_DONE | S_ERROR, 4'hF);
    endtask

    task check_all_regs;                                 // every register reads its expected value
        input integer g;
        input [8*60-1:0] tag;
        integer s;
        begin
            for (s = 0; s < NSLOT; s = s + 1) begin
                if (s_kind(s) == K_CFG) begin
                    axil_read(s << 2, rv);
                    $sformat(msgbuf, "%0s: reg 0x%02h readback", tag, s << 2);
                    chk_eq(g, rv, shadow[s], msgbuf);
                    $sformat(msgbuf, "%0s: reg 0x%02h cfg output", tag, s << 2);
                    chk_eq(g, cfg_out(s), shadow[s], msgbuf);
                end
            end
        end
    endtask

    // start attempt in mode `mode`; exp = expected ERR code (PATRM_ERR_NONE = must start)
    task try_start;
        input [1:0]  mode;
        input [3:0]  exp;
        input [8*60-1:0] what;
        reg [31:0] st0, st;
        begin
            axil_read(PATRM_REG_STATUS, st0);
            p0 = start_pulses;
            axil_write(PATRM_REG_CTRL, C_START | (mode << PATRM_CTRL_MODE_LSB), 4'hF);
            axil_read(PATRM_REG_STATUS, st);
            if (exp == PATRM_ERR_NONE) begin
                $sformat(msgbuf, "%0s: STATUS at BVALID", what);
                chk_eq(G_D, b_status & (S_BUSY | S_ERROR | S_ERRC | S_DONE), S_BUSY, msgbuf);
                $sformat(msgbuf, "%0s: STATUS read after start", what);
                chk_eq(G_D, st & (S_BUSY | S_ERROR | S_ERRC | S_DONE), S_BUSY, msgbuf);
                $sformat(msgbuf, "%0s: one start pulse", what);
                chk_eq(G_D, start_pulses - p0, 1, msgbuf);
                wait_idle;
                clear_status;
            end else begin
                $sformat(msgbuf, "%0s: STATUS at BVALID", what);
                chk_eq(G_D, b_status & (S_BUSY | S_ERROR | S_ERRC), S_ERROR | (exp << PATRM_STATUS_ERR_CODE_LSB), msgbuf);
                $sformat(msgbuf, "%0s: STATUS read after start (DONE unchanged)", what);
                chk_eq(G_D, st, (st0 & S_DONE) | S_ERROR | (exp << PATRM_STATUS_ERR_CODE_LSB), msgbuf);
                $sformat(msgbuf, "%0s: no start pulse", what);
                chk_eq(G_D, start_pulses - p0, 0, msgbuf);
                axil_write(PATRM_REG_STATUS, S_ERROR, 4'hF);
                axil_read(PATRM_REG_STATUS, st);
                $sformat(msgbuf, "%0s: W1C ERROR clears ERROR and ERR_CODE", what);
                chk_eq(G_D, st, st0 & S_DONE, msgbuf);
            end
        end
    endtask

    // ---------------- test sequence ----------------
    integer s, o;
    reg [31:0] d, e, st;

    initial begin
        for (i = 0; i < 9; i = i + 1) nchk[i] = 0;
        for (i = 0; i < 3; i = i + 1) n_order[i] = 0;
        for (i = 0; i < 3 * NSLOT; i = i + 1) spec[i] = 32'hx;
        for (i = 0; i < 64; i = i + 1) jobv[i] = 32'hx;
        first_fail = 0;
        $readmemh("../../../data/vectors/axil_regs_spec.hex", spec);
        $readmemh("../../../data/vectors/axil_regs_job.hex", jobv);
        if (^spec[3*NSLOT-1] === 1'bx || ^jobv[0] === 1'bx) begin
            $display("TEST FAIL: vectors missing; run python scripts/gen_axil_vectors.py");
            $finish;
        end
        for (s = 0; s < NSLOT; s = s + 1) shadow[s] = s_reset(s);

        repeat (16) @(posedge aclk);
        #1 aresetn = 1;
        repeat (2) @(posedge aclk);

        // ===== a. reset values =====
        $display("a. reset values");
        chk(G_A, interrupt === 1'b0, "interrupt = 0 after reset");
        chk(G_A, start_accept === 1'b0, "start_accept = 0 after reset");
        for (s = 0; s < NSLOT; s = s + 1) begin
            axil_read(s << 2, rv);
            $sformat(msgbuf, "reset value of offset 0x%02h", s << 2);
            chk_eq(G_A, rv, s_reset(s), msgbuf);
            if (s_kind(s) == K_CFG) begin
                $sformat(msgbuf, "reset cfg output of offset 0x%02h", s << 2);
                chk_eq(G_A, cfg_out(s), s_reset(s), msgbuf);
            end
        end
        chk_eq(G_A, cfg_mode, s_reset(PATRM_REG_CTRL >> 2) >> PATRM_CTRL_MODE_LSB, "reset cfg_mode");

        // ===== b. read/write, WSTRB, RO, unmapped =====
        $display("b. read/write");
        for (o = 0; o < 3; o = o + 1) begin             // full writes, each handshake order in turn
            wr_order = o;
            for (s = 0; s < NSLOT; s = s + 1) if (s_kind(s) == K_CFG) begin
                d = $random(seed);
                axil_write(s << 2, d, 4'hF);
                shadow[s] = d & s_rw(s);
                axil_read(s << 2, rv);
                $sformat(msgbuf, "full write/readback 0x%02h (order %0d)", s << 2, o);
                chk_eq(G_B, rv, shadow[s], msgbuf);
                $sformat(msgbuf, "cfg output 0x%02h", s << 2);
                chk_eq(G_B, cfg_out(s), shadow[s], msgbuf);
            end
        end
        wr_order = -1;
        for (j = 0; j < 4; j = j + 1)                    // partial WSTRB writes (random order and gaps)
            for (s = 0; s < NSLOT; s = s + 1) if (s_kind(s) == K_CFG) begin
                d = $random(seed);
                e = (j == 0) ? 4'h0 : rnd(16);           // includes WSTRB = 0 (no change)
                axil_write(s << 2, d, e[3:0]);
                shadow[s] = merge(shadow[s], d, e[3:0]) & s_rw(s);
                axil_read(s << 2, rv);
                $sformat(msgbuf, "WSTRB %b write/readback 0x%02h", e[3:0], s << 2);
                chk_eq(G_B, rv, shadow[s], msgbuf);
            end
        // explicit unused-bit check on the 13-bit fields
        axil_write(PATRM_REG_WIDTH, 32'hFFFF_FFFF, 4'hF);
        axil_read(PATRM_REG_WIDTH, rv);
        chk_eq(G_B, rv, (32'd1 << PATRM_WIDTH_W_W) - 1, "WIDTH unused bits read 0");
        shadow[PATRM_REG_WIDTH >> 2] = rv;
        // byte address bits 1:0 are ignored
        d = $random(seed);
        axil_write(PATRM_REG_B12 | 7'd3, d, 4'hF);
        shadow[PATRM_REG_B12 >> 2] = d;
        axil_read(PATRM_REG_B12 | 7'd2, rv);
        chk_eq(G_B, rv, d, "address bits 1:0 ignored");
        // CTRL: MODE and IRQ_EN read back, START reads 0, other bits 0
        for (j = 0; j < 8; j = j + 1) begin
            d = $random(seed) & ~C_START;
            axil_write(PATRM_REG_CTRL, d, 4'hF);
            axil_read(PATRM_REG_CTRL, rv);
            chk_eq(G_B, rv, d & s_rw(PATRM_REG_CTRL >> 2), "CTRL write/readback");
            chk_eq(G_B, cfg_mode, (d >> PATRM_CTRL_MODE_LSB) & 3, "cfg_mode follows CTRL.MODE");
        end
        axil_write(PATRM_REG_CTRL, C_IRQ | C_START, 4'hE);   // byte 0 not enabled: nothing changes, no start
        axil_read(PATRM_REG_CTRL, e);
        chk_eq(G_B, e, rv, "CTRL write with WSTRB[0]=0 ignored");
        chk_eq(G_B, start_pulses, 0, "no start from a write with WSTRB[0]=0");
        axil_write(PATRM_REG_CTRL, 0, 4'hF);
        // RO registers ignore writes; STATUS RO bits ignore writes
        for (s = 0; s < NSLOT; s = s + 1) if (s_kind(s) == K_COUNTER || s_kind(s) == K_BUILD_ID) begin
            axil_read(s << 2, e);
            axil_write(s << 2, ~e, 4'hF);
            axil_read(s << 2, rv);
            $sformat(msgbuf, "RO register 0x%02h ignores writes", s << 2);
            chk_eq(G_B, rv, e, msgbuf);
        end
        axil_write(PATRM_REG_STATUS, ~(S_DONE | S_ERROR), 4'hF);
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_B, rv, 0, "STATUS RO / reserved bits ignore writes");
        // unmapped offsets: read 0, writes change nothing
        for (s = 0; s < NSLOT; s = s + 1) if (s_kind(s) == K_UNMAPPED) begin
            axil_write(s << 2, $random(seed), 4'hF);
            axil_read(s << 2, rv);
            $sformat(msgbuf, "unmapped 0x%02h reads 0", s << 2);
            chk_eq(G_B, rv, 0, msgbuf);
        end
        check_all_regs(G_B, "after unmapped writes");
        // write and read issued in the same cycle (write first, both complete)
        d = $random(seed);
        fork
            axil_write(PATRM_REG_B21, d, 4'hF);
            axil_read(PATRM_REG_B22, rv);
        join
        shadow[PATRM_REG_B21 >> 2] = d;
        chk_eq(G_B, rv, shadow[PATRM_REG_B22 >> 2], "read concurrent with write");
        axil_read(PATRM_REG_B21, rv);
        chk_eq(G_B, rv, d, "write concurrent with read");

        // ===== c. START pulse, BUSY, lock while busy =====
        $display("c. start / busy / lock");
        good_cfg;
        clear_status;
        hold_job = 1;
        p0 = start_pulses;
        axil_write(PATRM_REG_CTRL, C_START, 4'hF);
        chk(G_C, b_start === 1'b1, "start_accept = 1 in the BVALID cycle (T+1)");
        chk_eq(G_C, b_status & (S_BUSY | S_ERROR), S_BUSY, "BUSY already set at BVALID");
        chk_eq(G_C, start_pulses - p0, 1, "exactly one start pulse");
        chk_eq(G_C, start_max, 1, "start pulse lasts one cycle");
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_C, rv, S_BUSY, "STATUS = BUSY after start");
        for (s = 0; s < NSLOT; s = s + 1) if (s_kind(s) == K_CFG)
            axil_write(s << 2, $random(seed), 4'hF);     // locked: shadow keeps the old values
        axil_write(PATRM_REG_CTRL, (2 << PATRM_CTRL_MODE_LSB) | C_IRQ, 4'hF);
        check_all_regs(G_C, "locked while busy");
        axil_read(PATRM_REG_CTRL, rv);
        chk_eq(G_C, rv, C_IRQ, "MODE locked, IRQ_EN writable while busy");
        axil_write(PATRM_REG_CTRL, 0, 4'hF);
        axil_read(PATRM_REG_CTRL, rv);
        chk_eq(G_C, rv, 0, "IRQ_EN cleared while busy");
        chk(G_C, busy === 1'b1, "job still running");
        hold_job = 0;
        wait_idle;
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_C, rv, S_DONE, "DONE after the job, BUSY = 0");
        clear_status;
        d = $random(seed);
        cfg_write(PATRM_REG_B13, d);
        axil_read(PATRM_REG_B13, rv);
        chk_eq(G_C, rv, d, "unlocked after the job");
        chk_eq(G_C, start_max, 1, "start pulse still one cycle");

        // ===== d. error codes and priority =====
        $display("d. error codes");
        good_cfg;
        try_start(PATRM_MODE_GRAY, PATRM_ERR_NONE, "good config");
        try_start(PATRM_MODE_BAYER_A, PATRM_ERR_BAD_MODE, "MODE 1 not in MODES");
        try_start(PATRM_MODE_BAYER_B, PATRM_ERR_BAD_MODE, "MODE 2 not in MODES");
        try_start(2'd3, PATRM_ERR_BAD_MODE, "MODE 3");
        cfg_write(PATRM_REG_WIDTH, 0);      try_start(PATRM_MODE_GRAY, PATRM_ERR_BAD_SIZE, "W = 0");
        cfg_write(PATRM_REG_WIDTH, 4104);   try_start(PATRM_MODE_GRAY, PATRM_ERR_BAD_SIZE, "W = 4104 > 4096");
        cfg_write(PATRM_REG_WIDTH, 644);    try_start(PATRM_MODE_GRAY, PATRM_ERR_BAD_SIZE, "W = 644 not mult of 8");
        cfg_write(PATRM_REG_WIDTH, 4096);   try_start(PATRM_MODE_GRAY, PATRM_ERR_NONE, "W = 4096");
        cfg_write(PATRM_REG_HEIGHT, 0);     try_start(PATRM_MODE_GRAY, PATRM_ERR_BAD_SIZE, "H = 0");
        cfg_write(PATRM_REG_HEIGHT, 4097);  try_start(PATRM_MODE_GRAY, PATRM_ERR_BAD_SIZE, "H = 4097");
        cfg_write(PATRM_REG_HEIGHT, 4096);  try_start(PATRM_MODE_GRAY, PATRM_ERR_NONE, "4096 x 4096");
        set_cfg(32'h1000_0000, 32'h1800_0000, 8, 1, 1);
        try_start(PATRM_MODE_GRAY, PATRM_ERR_NONE, "8 x 1, BLOCK_LEN 1");
        good_cfg;
        cfg_write(PATRM_REG_SRC_ADDR, 32'h1000_0800);  try_start(PATRM_MODE_GRAY, PATRM_ERR_BAD_ADDR, "SRC not 4 KB aligned");
        cfg_write(PATRM_REG_SRC_ADDR, 32'h1000_1000);
        cfg_write(PATRM_REG_DST_ADDR, 32'h1800_0001);  try_start(PATRM_MODE_GRAY, PATRM_ERR_BAD_ADDR, "DST not 4 KB aligned");
        cfg_write(PATRM_REG_DST_ADDR, 32'hFFFF_F000);  try_start(PATRM_MODE_GRAY, PATRM_ERR_NONE, "DST 0xFFFFF000");
        cfg_write(PATRM_REG_BLOCK_LEN, 0);              try_start(PATRM_MODE_GRAY, PATRM_ERR_BAD_BLOCK_LEN, "BLOCK_LEN 0");
        cfg_write(PATRM_REG_BLOCK_LEN, BLOCK_LEN_MAX + 1); try_start(PATRM_MODE_GRAY, PATRM_ERR_BAD_BLOCK_LEN, "BLOCK_LEN 65");
        cfg_write(PATRM_REG_BLOCK_LEN, 8191);           try_start(PATRM_MODE_GRAY, PATRM_ERR_BAD_BLOCK_LEN, "BLOCK_LEN 8191");
        cfg_write(PATRM_REG_BLOCK_LEN, BLOCK_LEN_MAX);  try_start(PATRM_MODE_GRAY, PATRM_ERR_NONE, "BLOCK_LEN 64");
        // the check uses the MODE written together with START
        axil_write(PATRM_REG_CTRL, 3 << PATRM_CTRL_MODE_LSB, 4'hF);
        try_start(PATRM_MODE_GRAY, PATRM_ERR_NONE, "stored MODE 3, START with MODE 0");
        axil_write(PATRM_REG_CTRL, 0, 4'hF);
        try_start(PATRM_MODE_BAYER_A, PATRM_ERR_BAD_MODE, "stored MODE 0, START with MODE 1");
        // START_BUSY: the running job continues
        axil_write(PATRM_REG_CTRL, 0, 4'hF);
        hold_job = 1;
        axil_write(PATRM_REG_CTRL, C_START, 4'hF);
        p0 = start_pulses;
        cfg_write(PATRM_REG_WIDTH, 0);                   // locked: ignored (shadow fixed below)
        shadow[PATRM_REG_WIDTH >> 2] = 640;
        axil_write(PATRM_REG_CTRL, C_START | (3 << PATRM_CTRL_MODE_LSB), 4'hF);
        chk_eq(G_D, b_status & (S_BUSY | S_ERROR | S_ERRC), S_BUSY | S_ERROR | (PATRM_ERR_START_BUSY << PATRM_STATUS_ERR_CODE_LSB),
               "START_BUSY at BVALID (busy + bad mode + bad size)");
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_D, rv, S_BUSY | S_ERROR | (PATRM_ERR_START_BUSY << PATRM_STATUS_ERR_CODE_LSB), "START_BUSY in STATUS, still busy");
        chk_eq(G_D, start_pulses - p0, 0, "no second start pulse");
        chk_eq(G_D, cfg_mode, PATRM_MODE_GRAY, "MODE of the running job unchanged");
        hold_job = 0;
        wait_idle;
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_D, rv, S_DONE | S_ERROR | (PATRM_ERR_START_BUSY << PATRM_STATUS_ERR_CODE_LSB), "running job finished normally");
        clear_status;
        // priority with several errors at once
        set_cfg(32'h1000_0004, 32'h1800_0000, 644, 480, 0);  // size + addr + block_len bad
        try_start(2'd3, PATRM_ERR_BAD_MODE, "mode+size+addr+blen -> BAD_MODE");
        try_start(PATRM_MODE_GRAY, PATRM_ERR_BAD_SIZE, "size+addr+blen -> BAD_SIZE");
        cfg_write(PATRM_REG_WIDTH, 640);
        try_start(PATRM_MODE_GRAY, PATRM_ERR_BAD_ADDR, "addr+blen -> BAD_ADDR");
        cfg_write(PATRM_REG_HEIGHT, 0);
        try_start(PATRM_MODE_BAYER_B, PATRM_ERR_BAD_MODE, "mode+size+addr+blen (H=0) -> BAD_MODE");
        cfg_write(PATRM_REG_SRC_ADDR, 32'h1000_0000);
        try_start(PATRM_MODE_GRAY, PATRM_ERR_BAD_SIZE, "size+blen -> BAD_SIZE");
        cfg_write(PATRM_REG_HEIGHT, 480);
        try_start(PATRM_MODE_GRAY, PATRM_ERR_BAD_BLOCK_LEN, "blen only -> BAD_BLOCK_LEN");
        // a rejected start keeps DONE
        cfg_write(PATRM_REG_BLOCK_LEN, 16);
        axil_write(PATRM_REG_CTRL, C_START, 4'hF);
        wait_idle;
        try_start(2'd3, PATRM_ERR_BAD_MODE, "rejected start with DONE = 1");
        clear_status;

        // ===== e. DONE, W1C, interrupt =====
        $display("e. done / interrupt");
        good_cfg;
        axil_write(PATRM_REG_CTRL, C_START, 4'hF);       // IRQ_EN = 0
        wait_idle;
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_E, rv, S_DONE, "DONE = 1, BUSY = 0 after done_set");
        chk(G_E, interrupt === 1'b0, "no interrupt with IRQ_EN = 0");
        axil_write(PATRM_REG_CTRL, C_IRQ, 4'hF);
        chk(G_E, interrupt === 1'b1, "interrupt follows IRQ_EN with DONE = 1 (level)");
        axil_write(PATRM_REG_STATUS, 0, 4'hF);
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_E, rv, S_DONE, "writing 0 to DONE does nothing");
        chk(G_E, interrupt === 1'b1, "interrupt still high after writing 0");
        axil_write(PATRM_REG_STATUS, S_DONE, 4'hE);
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_E, rv, S_DONE, "W1C with WSTRB[0] = 0 does nothing");
        axil_write(PATRM_REG_STATUS, S_ERROR, 4'hF);
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_E, rv, S_DONE, "W1C ERROR leaves DONE");
        axil_write(PATRM_REG_STATUS, S_DONE, 4'hF);
        chk(G_E, interrupt === 1'b0, "W1C DONE drops the interrupt by BVALID");
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_E, rv, 0, "W1C DONE clears DONE");
        // IRQ_EN = 1 during the job: interrupt rises with DONE
        axil_write(PATRM_REG_CTRL, C_START | C_IRQ, 4'hF);
        chk(G_E, interrupt === 1'b0, "no interrupt while busy");
        wait_idle;
        chk(G_E, interrupt === 1'b1, "interrupt at done with IRQ_EN = 1");
        // an accepted start clears DONE and the interrupt
        hold_job = 1;
        axil_write(PATRM_REG_CTRL, C_START | C_IRQ, 4'hF);
        chk(G_E, interrupt === 1'b0, "accepted start clears DONE / interrupt");
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_E, rv, S_BUSY, "accepted start: DONE = 0");
        hold_job = 0;
        wait_idle;
        axil_write(PATRM_REG_STATUS, S_DONE, 4'hF);
        // an error never raises the interrupt
        axil_write(PATRM_REG_CTRL, C_START | C_IRQ | (3 << PATRM_CTRL_MODE_LSB), 4'hF);
        repeat (5) @(posedge aclk);
        chk(G_E, interrupt === 1'b0, "rejected start does not raise the interrupt");
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_E, rv, S_ERROR | (PATRM_ERR_BAD_MODE << PATRM_STATUS_ERR_CODE_LSB), "error recorded");
        axil_write(PATRM_REG_STATUS, S_DONE | S_ERROR, 4'hF);
        axil_write(PATRM_REG_CTRL, 0, 4'hF);

        // ===== f. counters =====
        $display("f. counters");
        for (j = 0; j < 4; j = j + 1) begin
            ld_cycles = $random(seed); ld_bytes_rd = $random(seed); ld_bytes_wr = $random(seed);
            ld_rd_stall = $random(seed); ld_wr_stall = $random(seed);
            if (j == 3) begin
                ld_cycles = 32'hFFFF_FFFF; ld_bytes_rd = 32'h8000_0000; ld_bytes_wr = 0;
                ld_rd_stall = 32'h0000_0001; ld_wr_stall = 32'h7FFF_FFFF;
            end
            @(posedge aclk); #1 stub_load = 1;
            @(posedge aclk); #1 stub_load = 0;
            axil_read(PATRM_REG_CYCLES, rv);   chk_eq(G_F, rv, ld_cycles,   "CYCLES");
            axil_read(PATRM_REG_BYTES_RD, rv); chk_eq(G_F, rv, ld_bytes_rd, "BYTES_RD");
            axil_read(PATRM_REG_BYTES_WR, rv); chk_eq(G_F, rv, ld_bytes_wr, "BYTES_WR");
            axil_read(PATRM_REG_RD_STALL, rv); chk_eq(G_F, rv, ld_rd_stall, "RD_STALL");
            axil_read(PATRM_REG_WR_STALL, rv); chk_eq(G_F, rv, ld_wr_stall, "WR_STALL");
        end
        job_len = 37;                                    // counters from a real (stub) job, held after DONE
        axil_write(PATRM_REG_CTRL, C_START, 4'hF);
        wait_idle;
        axil_read(PATRM_REG_CYCLES, rv);   chk_eq(G_F, rv, cnt_cycles,   "CYCLES after job");
        axil_read(PATRM_REG_BYTES_RD, rv); chk_eq(G_F, rv, cnt_bytes_rd, "BYTES_RD after job");
        axil_read(PATRM_REG_BYTES_WR, rv); chk_eq(G_F, rv, cnt_bytes_wr, "BYTES_WR after job");
        axil_read(PATRM_REG_RD_STALL, rv); chk_eq(G_F, rv, cnt_rd_stall, "RD_STALL after job");
        axil_read(PATRM_REG_WR_STALL, rv); chk_eq(G_F, rv, cnt_wr_stall, "WR_STALL after job");
        chk(G_F, cnt_cycles == job_len + 1 && cnt_bytes_rd == 8 * cnt_cycles, "stub counters advanced");
        clear_status;
        job_len = 5;

        // ===== g. worked-example job image from model/job.py =====
        $display("g. worked-example job (%0d writes)", jobv[0]);
        clear_status;                                    // driver step 5
        hold_job = 1;
        n = jobv[0];
        p0 = start_pulses;
        for (j = 0; j < n; j = j + 1) begin              // driver step 6 + 7 (CTRL with START last)
            axil_write(jobv[1 + 2*j], jobv[2 + 2*j], 4'hF);
            if (jobv[1 + 2*j] != PATRM_REG_CTRL) shadow[jobv[1 + 2*j] >> 2] = jobv[2 + 2*j];
        end
        chk_eq(G_G, jobv[2*n - 1], PATRM_REG_CTRL, "last write of the image is CTRL");
        chk_eq(G_G, b_status & (S_BUSY | S_ERROR | S_ERRC | S_DONE), S_BUSY, "START accepted (STATUS at BVALID)");
        axil_read(PATRM_REG_STATUS, rv);                 // driver step 8
        chk_eq(G_G, rv, S_BUSY, "START accepted (STATUS read)");
        chk_eq(G_G, start_pulses - p0, 1, "one start pulse");
        for (j = 0; j < n; j = j + 1) begin              // every written register reads back its image value
            axil_read(jobv[1 + 2*j], rv);
            e = jobv[2 + 2*j];
            if (jobv[1 + 2*j] == PATRM_REG_CTRL) e = e & ~C_START;
            $sformat(msgbuf, "job image readback 0x%02h", jobv[1 + 2*j]);
            chk_eq(G_G, rv, e, msgbuf);
        end
        check_all_regs(G_G, "job image (all config regs + cfg outputs)");
        axil_read(PATRM_REG_BUILD_ID, rv);
        chk_eq(G_G, rv, s_reset(PATRM_REG_BUILD_ID >> 2), "BUILD_ID");
        hold_job = 0;
        wait_idle;
        chk(G_G, interrupt === 1'b1, "worked-example job: interrupt at done (IRQ_EN = 1)");
        axil_write(PATRM_REG_STATUS, S_DONE, 4'hF);      // driver step 9
        chk(G_G, interrupt === 1'b0, "worked-example job: interrupt cleared");

        // ===== i. step 3.7: BUSY before the engine reacts, BUS_ERROR =====
        $display("i. busy pending / bus error");
        axil_write(PATRM_REG_CTRL, 0, 4'hF);
        clear_status;
        good_cfg;
        backpressure = 0;
        hold_job = 1;
        busy_lag = 40;                                   // the engine raises busy 40 cycles later than ctrl_fsm does
        axil_write(PATRM_REG_CTRL, C_START, 4'hF);
        chk_eq(G_I, b_status & (S_BUSY | S_ERROR), S_BUSY, "BUSY at BVALID, engine not reacting yet");
        chk(G_I, busy === 1'b0, "busy input still 0 after the START response");
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_I, rv, S_BUSY, "first STATUS read after START: BUSY = 1 with busy input 0");
        chk(G_I, busy === 1'b0, "busy input still 0 after the STATUS read");
        axil_write(PATRM_REG_WIDTH, 8, 4'hF);
        axil_read(PATRM_REG_WIDTH, rv);
        chk_eq(G_I, rv, 640, "configuration locked while the start is pending");
        p0 = start_pulses;
        axil_write(PATRM_REG_CTRL, C_START, 4'hF);
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_I, rv, S_BUSY | S_ERROR | (PATRM_ERR_START_BUSY << PATRM_STATUS_ERR_CODE_LSB),
               "START while the start is pending -> START_BUSY");
        chk_eq(G_I, start_pulses - p0, 0, "no second start pulse while pending");
        axil_write(PATRM_REG_STATUS, S_ERROR, 4'hF);
        chk(G_I, busy === 1'b0, "busy input still 0 at the end of the pending checks");
        while (busy !== 1'b1) @(posedge aclk);
        repeat (3) @(posedge aclk);
        #1;
        chk(G_I, dut.start_pending === 1'b0, "start_pending cleared when busy rises");
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_I, rv, S_BUSY, "BUSY = 1 from the busy input");
        hold_job = 0;
        wait_idle;
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_I, rv, S_DONE, "job with a late busy ends normally");
        clear_status;
        // done_set before busy ever rose: the pending flag must not stay set
        busy_lag = 1000;
        axil_write(PATRM_REG_CTRL, C_START, 4'hF);
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_I, rv, S_BUSY, "BUSY pending before done_set");
        @(posedge aclk); #1 stub_done = 1;
        while (done_set !== 1'b1) @(posedge aclk);
        #1 stub_done = 0;
        repeat (3) @(posedge aclk);
        #1;
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_I, rv, S_DONE, "done_set clears the pending flag");
        clear_status;
        busy_lag = 0;
        // BUS_ERROR: only at the end of a job, DONE and the interrupt as normal
        bus_err = 1;
        repeat (3) @(posedge aclk);
        #1;
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_I, rv, 0, "bus_err without done_set does nothing");
        hold_job = 1;
        axil_write(PATRM_REG_CTRL, C_START | C_IRQ, 4'hF);
        repeat (5) @(posedge aclk);
        #1;
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_I, rv, S_BUSY, "no ERROR before the end of the job");
        hold_job = 0;
        wait_idle;
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_I, rv, S_DONE | S_ERROR | (PATRM_ERR_BUS_ERROR << PATRM_STATUS_ERR_CODE_LSB), "BUS_ERROR with DONE");
        chk(G_I, interrupt === 1'b1, "interrupt fires with BUS_ERROR");
        axil_write(PATRM_REG_STATUS, S_DONE, 4'hF);
        chk(G_I, interrupt === 1'b0, "W1C DONE drops the interrupt");
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_I, rv, S_ERROR | (PATRM_ERR_BUS_ERROR << PATRM_STATUS_ERR_CODE_LSB), "ERROR is sticky after W1C DONE");
        axil_write(PATRM_REG_STATUS, S_ERROR, 4'hF);
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_I, rv, 0, "W1C ERROR clears ERROR and ERR_CODE");
        // an accepted start clears a BUS_ERROR left from the previous job
        axil_write(PATRM_REG_CTRL, C_START, 4'hF);
        wait_idle;
        bus_err = 0;
        hold_job = 1;
        axil_write(PATRM_REG_CTRL, C_START, 4'hF);
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_I, rv, S_BUSY, "accepted start clears DONE and BUS_ERROR");
        // BUS_ERROR replaces a START_BUSY code from the same job
        axil_write(PATRM_REG_CTRL, C_START, 4'hF);
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_I, rv, S_BUSY | S_ERROR | (PATRM_ERR_START_BUSY << PATRM_STATUS_ERR_CODE_LSB), "START_BUSY during the job");
        bus_err = 1;
        hold_job = 0;
        wait_idle;
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_I, rv, S_DONE | S_ERROR | (PATRM_ERR_BUS_ERROR << PATRM_STATUS_ERR_CODE_LSB), "BUS_ERROR replaces START_BUSY");
        clear_status;
        // a W1C of ERROR and DONE in the done_set cycle loses against the new error and done
        job_len = 12;
        axil_write(PATRM_REG_CTRL, C_START, 4'hF);
        #1;
        while (!(busy === 1'b1 && job_cnt == job_len - 1)) begin @(posedge aclk); #1; end
        @(posedge aclk); #1;                             // done_set = 1 in this cycle
        chk(G_I, done_set === 1'b1, "W1C collision: done_set cycle reached");
        awaddr = PATRM_REG_STATUS; wdata = S_DONE | S_ERROR; wstrb = 4'hF; awvalid = 1; wvalid = 1; bready = 1;
        @(posedge aclk);
        chk(G_I, awready === 1'b1, "W1C collision: write taken in the done_set cycle");
        #1 awvalid = 0; wvalid = 0;
        while (bvalid !== 1'b1) begin @(posedge aclk); #1; end
        @(posedge aclk); #1 bready = 0;
        wait_idle;
        axil_read(PATRM_REG_STATUS, rv);
        chk_eq(G_I, rv, S_DONE | S_ERROR | (PATRM_ERR_BUS_ERROR << PATRM_STATUS_ERR_CODE_LSB),
               "done_set and BUS_ERROR win over a W1C in the same cycle");
        clear_status;
        bus_err = 0;
        job_len = 5;
        backpressure = 1;

        // ===== p. protocol monitor summary =====
        chk_eq(G_P, mon_viol, 0, "AXI-Lite protocol violations");
        chk_eq(G_P, irq_viol, 0, "cycles with interrupt != IRQ_EN & DONE");
        chk_eq(G_C, start_max, 1, "longest start pulse over the whole run");
        chk(G_P, n_order[0] > 0 && n_order[1] > 0 && n_order[2] > 0, "all three AW/W orders used");

        $display("checks: a=%0d b=%0d c=%0d d=%0d e=%0d f=%0d g=%0d i=%0d p=%0d (monitor %0d cycles); writes by order together/AW-first/W-first = %0d/%0d/%0d; start pulses %0d",
                 nchk[0], nchk[1], nchk[2], nchk[3], nchk[4], nchk[5], nchk[6], nchk[8], nchk[7], mon_cycles,
                 n_order[0], n_order[1], n_order[2], start_pulses);
        if (nfail == 0) $display("TEST PASS");
        else            $display("TEST FAIL: %0d failed checks, first: %0s", nfail, first_fail);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TEST FAIL: timeout");
        $finish;
    end

endmodule
