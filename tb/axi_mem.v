// axi_mem: behavioural AXI3 slave memory model of a Zynq HP port (testbench only, not synthesisable).
// One memory window, a read channel (step 3.4, HP0 style) and a write channel (step 3.5, HP1 style).
//
// Read channel:
//   - Memory: MEM_WORDS 64-bit words at BASE (e.g. the SRC_ADDR window 0x1000_0000 or DST_ADDR 0x1800_0000),
//     loaded with $readmemh from +MEM_FILE=<path> (or the MEM_FILE parameter). Byte k of a word = bits 8k+7:8k
//     (address order). Task dump(path, first, last) writes words first..last with $writememh.
//   - Read bursts accepted in order (single ID, in-order data), up to max_out bursts outstanding (>= 4).
//   - Random ARREADY back-pressure (ar_bp_pct % of cycles low), random AR-to-first-R latency lat_min..lat_max
//     cycles (latency L: the AR handshake in cycle c gives the first RVALID in cycle c + L at the earliest),
//     random RVALID gaps (r_gap_pct % of the beats get a one-cycle gap before them). Data back-to-back
//     across bursts when the next burst's latency has expired, so the model can deliver 1 beat per clock.
//   - Error injection: every beat of burst number err_burst (counted from 0 since reset, AR handshake order)
//     gets RRESP = SLVERR (2'b10). The data is still the memory content. err_burst = -1: none.
//   - Burst log: log_n, log_addr[], log_len[] (beats); also written to +MEM_LOG=<path> if given.
//   - Protocol checker (plain Verilog): every violation is printed ("AXI_MEM VIOLATION ...") and counted in
//     viol[k] and viol_total. Checked on the AR channel (the master): ARLEN > 15, ARSIZE != 3, ARBURST != INCR,
//     ARADDR not 8-byte aligned, burst crossing a 4 KB boundary, AR payload changing while ARVALID && !ARREADY,
//     ARVALID dropped before ARREADY, ARID != 0 (single in-order ID), address outside the memory window, X on
//     ARVALID / RREADY. On the R channel (the slave side, independent of RREADY): RVALID dropped or R payload
//     changed while RVALID && !RREADY, RVALID without an outstanding burst, RLAST on the wrong beat.
//
// Write channel (AXI3, WID used, single ID 0, in order):
//   - AW accepted while fewer than max_out_wr bursts wait for their B response, minus random back-pressure
//     (aw_bp_pct % of cycles AWREADY low). W beats accepted into a WBUF-entry buffer, minus random back-pressure
//     (w_bp_pct %), also BEFORE their AW (AXI3 allows it; counted in w_before_aw). Beats are paired with AWs in
//     order and written to the memory with WSTRB. When a burst's last beat is written, its B response becomes
//     valid b_lat_min..b_lat_max cycles later (in order, BVALID held until BREADY). BRESP = SLVERR (2'b10) for
//     AW number b_err_burst (counted from 0 since reset); the data is still written.
//   - Checker (the master): AWLEN > 15, AWSIZE != 3, AWBURST != INCR, AWADDR not 8-byte aligned, 4 KB crossing,
//     AW payload changing / AWVALID dropped while AWVALID && !AWREADY, AWID != 0, burst outside the window,
//     W payload changing / WVALID dropped while WVALID && !WREADY, WID != 0, WLAST before beat AWLEN+1 (fewer
//     beats), no WLAST on beat AWLEN+1 (more beats), X on AWVALID / WVALID / BREADY. Slave side: BVALID dropped
//     or B payload changed before BREADY, B response for a burst never issued (or not yet complete).
//
// Knobs: parameters give the defaults; plusargs +MEM_LAT_MIN, +MEM_LAT_MAX, +MEM_AR_BP, +MEM_R_GAP,
// +MEM_ERR_BURST, +MEM_MAX_OUT, +MEM_SEED override them at time 0; a testbench may change the knob registers
// (lat_min, lat_max, ar_bp_pct, r_gap_pct, err_burst, max_out, seed) between transfers. Write knobs:
// aw_bp_pct, w_bp_pct, b_lat_min, b_lat_max, b_err_burst, max_out_wr (plusargs +MEM_AW_BP, +MEM_W_BP,
// +MEM_B_LAT_MIN, +MEM_B_LAT_MAX, +MEM_B_ERR_BURST, +MEM_MAX_OUT_WR). With aw_bp_pct = w_bp_pct = 0 (default) and
// no write traffic it draws no random numbers, so the read channel behaves exactly as in step 3.4.
module axi_mem #(
    parameter [31:0] BASE      = 32'h1000_0000,
    parameter        MEM_WORDS = 16384,                  // 128 KB
    parameter        ID_W      = 6,
    parameter        MEM_FILE  = "",
    parameter        LAT_MIN   = 4,
    parameter        LAT_MAX   = 4,
    parameter        AR_BP     = 0,                      // percent of cycles with ARREADY low
    parameter        R_GAP     = 0,                      // percent of beats preceded by an RVALID gap
    parameter        ERR_BURST = -1,
    parameter        MAX_OUT   = 8,                      // outstanding read bursts accepted (>= 4)
    parameter        SEED      = 1,
    parameter        QDEPTH    = 64,                     // internal queue (>= MAX_OUT)
    parameter        LOG_MAX   = 65536,
    parameter        VERBOSE   = 20,                     // violations printed in full (all are counted)
    parameter        WBUF      = 64                      // W beats buffered (accepted before pairing)
) (
    input  wire            aclk,
    input  wire            aresetn,
    // AR (ARLEN is 8 bit wide here so that the checker can see a value > 15)
    input  wire [ID_W-1:0] s_arid,
    input  wire [31:0]     s_araddr,
    input  wire [7:0]      s_arlen,
    input  wire [2:0]      s_arsize,
    input  wire [1:0]      s_arburst,
    input  wire            s_arvalid,
    output reg             s_arready,
    // R
    output reg  [ID_W-1:0] s_rid,
    output reg  [63:0]     s_rdata,
    output reg  [1:0]      s_rresp,
    output reg             s_rlast,
    output reg             s_rvalid,
    input  wire            s_rready,
    // AW (AWLEN 8 bit wide, as ARLEN)
    input  wire [ID_W-1:0] s_awid,
    input  wire [31:0]     s_awaddr,
    input  wire [7:0]      s_awlen,
    input  wire [2:0]      s_awsize,
    input  wire [1:0]      s_awburst,
    input  wire            s_awvalid,
    output reg             s_awready,
    // W (AXI3: WID)
    input  wire [ID_W-1:0] s_wid,
    input  wire [63:0]     s_wdata,
    input  wire [7:0]      s_wstrb,
    input  wire            s_wlast,
    input  wire            s_wvalid,
    output reg             s_wready,
    // B
    output reg  [ID_W-1:0] s_bid,
    output reg  [1:0]      s_bresp,
    output reg             s_bvalid,
    input  wire            s_bready
);

    // ---------------- knobs ----------------
    integer lat_min, lat_max, ar_bp_pct, r_gap_pct, err_burst, max_out, seed;
    integer aw_bp_pct, w_bp_pct, b_lat_min, b_lat_max, b_err_burst, max_out_wr;
    reg [1023:0] fname;
    integer      flog;

    reg [63:0] mem [0:MEM_WORDS-1];

    initial begin
        lat_min = LAT_MIN; lat_max = LAT_MAX; ar_bp_pct = AR_BP; r_gap_pct = R_GAP;
        err_burst = ERR_BURST; max_out = MAX_OUT; seed = SEED;
        if ($value$plusargs("MEM_LAT_MIN=%d", lat_min)) ;
        if ($value$plusargs("MEM_LAT_MAX=%d", lat_max)) ;
        if ($value$plusargs("MEM_AR_BP=%d", ar_bp_pct)) ;
        if ($value$plusargs("MEM_R_GAP=%d", r_gap_pct)) ;
        if ($value$plusargs("MEM_ERR_BURST=%d", err_burst)) ;
        if ($value$plusargs("MEM_MAX_OUT=%d", max_out)) ;
        if ($value$plusargs("MEM_SEED=%d", seed)) ;
        aw_bp_pct = 0; w_bp_pct = 0; b_lat_min = 4; b_lat_max = 4; b_err_burst = -1; max_out_wr = 8;
        if ($value$plusargs("MEM_AW_BP=%d", aw_bp_pct)) ;
        if ($value$plusargs("MEM_W_BP=%d", w_bp_pct)) ;
        if ($value$plusargs("MEM_B_LAT_MIN=%d", b_lat_min)) ;
        if ($value$plusargs("MEM_B_LAT_MAX=%d", b_lat_max)) ;
        if ($value$plusargs("MEM_B_ERR_BURST=%d", b_err_burst)) ;
        if ($value$plusargs("MEM_MAX_OUT_WR=%d", max_out_wr)) ;
        if ($value$plusargs("MEM_FILE=%s", fname)) $readmemh(fname, mem);
        else if (MEM_FILE != "") $readmemh(MEM_FILE, mem);
        flog = 0;
        if ($value$plusargs("MEM_LOG=%s", fname)) flog = $fopen(fname, "w");
    end

    function integer urand100;                           // 0..99
        input dummy;
        begin
            urand100 = {$random(seed)} % 100;
        end
    endfunction

    // ---------------- state ----------------
    integer cyc;                                         // cycle counter (since time 0)
    integer q_addr  [0:QDEPTH-1];                        // byte address (as unsigned 32 bit in an integer)
    integer q_len   [0:QDEPTH-1];                        // beats
    integer q_ready [0:QDEPTH-1];                        // first cycle in which the first beat may be valid
    integer q_err   [0:QDEPTH-1];
    integer q_wr, q_rd, q_cnt;
    integer beat;                                        // beat index inside the head burst
    integer ar_count;                                    // AR handshakes since reset
    integer log_n;
    integer wlog_n;                                      // write bursts logged (write channel below)
    reg [31:0] log_addr [0:LOG_MAX-1];
    reg [4:0]  log_len  [0:LOG_MAX-1];
    integer    rbeats;                                   // R handshakes since time 0 (for the testbench)

    // checker
    localparam NV = 32;
    integer viol [0:NV-1];
    integer viol_total;
    reg [8*48-1:0] vname [0:NV-1];
    reg            p_arvalid, p_arready, p_rvalid, p_rready;
    reg [ID_W-1:0] p_arid;
    reg [31:0]     p_araddr;
    reg [7:0]      p_arlen;
    reg [2:0]      p_arsize;
    reg [1:0]      p_arburst;
    reg [63:0]     p_rdata;
    reg [1:0]      p_rresp;
    reg            p_rlast;
    reg [ID_W-1:0] p_rid;
    integer k, idx, lat, a, n;
    reg     gap_pending;

    initial begin
        cyc = 0; viol_total = 0; rbeats = 0; log_n = 0;
        for (k = 0; k < NV; k = k + 1) begin viol[k] = 0; vname[k] = "?"; end
        vname[0]  = "ARLEN > 15";
        vname[1]  = "ARSIZE != 3";
        vname[2]  = "ARBURST != INCR";
        vname[3]  = "ARADDR not 8-byte aligned";
        vname[4]  = "burst crosses a 4 KB boundary";
        vname[5]  = "AR payload changed while ARVALID && !ARREADY";
        vname[6]  = "ARVALID dropped before ARREADY";
        vname[7]  = "ARID != 0";
        vname[8]  = "burst outside the memory window";
        vname[9]  = "X on ARVALID or RREADY";
        vname[10] = "R: RVALID dropped / payload changed before RREADY";
        vname[11] = "R: RVALID without an outstanding burst";
        vname[12] = "R: RLAST on the wrong beat";
        vname[13] = "AWLEN > 15";
        vname[14] = "AWSIZE != 3";
        vname[15] = "AWBURST != INCR";
        vname[16] = "AWADDR not 8-byte aligned";
        vname[17] = "write burst crosses a 4 KB boundary";
        vname[18] = "AW payload changed while AWVALID && !AWREADY";
        vname[19] = "AWVALID dropped before AWREADY";
        vname[20] = "AWID != 0";
        vname[21] = "write burst outside the memory window";
        vname[22] = "W payload changed / WVALID dropped before WREADY";
        vname[23] = "WID != 0";
        vname[24] = "WLAST before beat AWLEN+1: fewer W beats than AWLEN+1";
        vname[25] = "no WLAST on beat AWLEN+1: more W beats than AWLEN+1";
        vname[26] = "B: BVALID dropped / payload changed before BREADY";
        vname[27] = "B response for a burst never issued or not complete";
        vname[28] = "X on AWVALID, WVALID or BREADY";
    end

    task violation;
        input integer v;
        begin
            viol[v] = viol[v] + 1;
            viol_total = viol_total + 1;
            if (viol_total <= VERBOSE)
                $display("AXI_MEM VIOLATION at %0t: %0s (AR 0x%08h len-1 %0d valid %b ready %b; AW 0x%08h len-1 %0d valid %b ready %b)",
                         $time, vname[v], s_araddr, s_arlen, s_arvalid, s_arready, s_awaddr, s_awlen, s_awvalid,
                         s_awready);
        end
    endtask

    task report;                                         // summary for the testbench
        begin
            $display("AXI_MEM checker: %0d violations, %0d read bursts and %0d write bursts logged", viol_total, log_n, wlog_n);
            for (k = 0; k < NV; k = k + 1)
                if (viol[k] != 0) $display("AXI_MEM checker:   %0d x %0s", viol[k], vname[k]);
        end
    endtask

    // ---------------- protocol checker (sampled at the clock edge, before the model updates) ----------------
    always @(posedge aclk) begin
        cyc <= cyc + 1;
        if (aresetn === 1'b1) begin
            if (s_arvalid !== 1'b0 && s_arvalid !== 1'b1) violation(9);
            if (s_rready  !== 1'b0 && s_rready  !== 1'b1) violation(9);
            if (s_arvalid === 1'b1) begin
                if (s_arlen > 8'd15)                 violation(0);
                if (s_arsize != 3'd3)                violation(1);
                if (s_arburst != 2'b01)              violation(2);
                if (s_araddr[2:0] != 3'd0)           violation(3);
                if ({1'b0, s_araddr[11:0]} + 8 * ({5'd0, s_arlen} + 1) > 4096) violation(4);
                if (s_arid != {ID_W{1'b0}})          violation(7);
                if (s_araddr < BASE || ({1'b0, s_araddr} + 8 * ({25'd0, s_arlen} + 1)) > ({1'b0, BASE} + 8 * MEM_WORDS))
                                                     violation(8);
            end
            if (p_arvalid && !p_arready) begin
                if (s_arvalid !== 1'b1) violation(6);
                else if (s_arid != p_arid || s_araddr != p_araddr || s_arlen != p_arlen || s_arsize != p_arsize ||
                         s_arburst != p_arburst) violation(5);
            end
            if (p_rvalid && !p_rready) begin
                if (!s_rvalid || s_rdata != p_rdata || s_rresp != p_rresp || s_rlast != p_rlast || s_rid != p_rid)
                    violation(10);
            end
        end
        p_arvalid <= (aresetn === 1'b1) && s_arvalid === 1'b1;
        p_arready <= s_arready;
        p_arid <= s_arid; p_araddr <= s_araddr; p_arlen <= s_arlen; p_arsize <= s_arsize; p_arburst <= s_arburst;
        p_rvalid <= (aresetn === 1'b1) && s_rvalid; p_rready <= s_rready;
        p_rdata <= s_rdata; p_rresp <= s_rresp; p_rlast <= s_rlast; p_rid <= s_rid;
    end

    // ---------------- read model ----------------
    always @(posedge aclk) begin
        if (aresetn !== 1'b1) begin
            s_arready <= 1'b0;
            s_rvalid  <= 1'b0;
            s_rlast   <= 1'b0;
            s_rresp   <= 2'b00;
            s_rid     <= {ID_W{1'b0}};
            q_wr = 0; q_rd = 0; q_cnt = 0; beat = 0; ar_count = 0; gap_pending = 1'b0;
        end else begin
            // R self-checks (before this edge's updates of the queue)
            if (s_rvalid && q_cnt == 0) violation(11);
            if (s_rvalid && q_cnt != 0 && s_rlast != (beat == q_len[q_rd] - 1)) violation(12);
            // AR handshake
            if (s_arvalid === 1'b1 && s_arready) begin
                lat = lat_min + ((lat_max > lat_min) ? ({$random(seed)} % (lat_max - lat_min + 1)) : 0);
                q_addr[q_wr]  = s_araddr;
                q_len[q_wr]   = s_arlen + 1;
                q_ready[q_wr] = cyc + lat - 1;            // RVALID registered at this edge -> visible in cycle + lat
                q_err[q_wr]   = (ar_count == err_burst);
                q_wr  = (q_wr + 1) % QDEPTH;
                q_cnt = q_cnt + 1;
                if (log_n < LOG_MAX) begin log_addr[log_n] = s_araddr; log_len[log_n] = s_arlen + 1; end
                if (flog != 0) $fdisplay(flog, "%0d %0d", s_araddr, s_arlen + 1);
                log_n = log_n + 1;
                ar_count = ar_count + 1;
            end
            // R handshake
            if (s_rvalid && s_rready) begin
                rbeats = rbeats + 1;
                if (beat == q_len[q_rd] - 1) begin
                    beat = 0;
                    q_rd = (q_rd + 1) % QDEPTH;
                    q_cnt = q_cnt - 1;
                end else
                    beat = beat + 1;
                gap_pending = (r_gap_pct > 0) && (urand100(0) < r_gap_pct);
            end
            // next R beat (RVALID only changes when it is 0 or was just accepted)
            if (!s_rvalid || s_rready) begin
                if (q_cnt != 0 && cyc >= q_ready[q_rd] && !gap_pending) begin
                    a   = q_addr[q_rd] + 8 * beat;
                    idx = (a - BASE) / 8;
                    s_rvalid <= 1'b1;
                    s_rdata  <= (a >= BASE && idx < MEM_WORDS) ? mem[idx] : 64'hDEAD_BEEF_DEAD_BEEF;
                    s_rresp  <= q_err[q_rd] ? 2'b10 : 2'b00;
                    s_rlast  <= (beat == q_len[q_rd] - 1);
                    s_rid    <= {ID_W{1'b0}};
                end else begin
                    s_rvalid <= 1'b0;
                    gap_pending = 1'b0;
                end
            end
            // ARREADY for the next cycle: room in the queue, minus random back-pressure
            s_arready <= (q_cnt < max_out) && !((ar_bp_pct > 0) && (urand100(0) < ar_bp_pct));
        end
    end

    // ---------------- write channel ----------------
    integer wa_addr [0:QDEPTH-1];                        // accepted AWs (in order)
    integer wa_len  [0:QDEPTH-1];
    integer wa_err  [0:QDEPTH-1];
    integer wa_wr, wa_rd, wa_cnt;                        // wa_cnt = AWs not yet paired completely
    reg [63:0] wb_data [0:WBUF-1];                       // accepted W beats not yet paired
    reg [7:0]  wb_strb [0:WBUF-1];
    reg        wb_last [0:WBUF-1];
    integer wb_wr, wb_rd, wb_cnt;
    integer wbt;                                         // beat index inside the AW being paired
    integer bq_ready [0:QDEPTH-1];                       // B responses of complete bursts
    integer bq_err   [0:QDEPTH-1];
    integer bq_wr, bq_rd, bq_cnt;
    integer aw_out;                                      // AWs accepted without B handshake
    integer aw_count;                                    // AW handshakes since reset
    integer w_before_aw;                                 // W beats accepted before their AW (since time 0)
    integer wbeats, bcount;                              // W / B handshakes since time 0
    reg [31:0] wlog_addr [0:LOG_MAX-1];
    reg [4:0]  wlog_len  [0:LOG_MAX-1];
    integer wi, wa, wk;
    reg     p_awvalid, p_awready, p_wvalid, p_wready, p_bvalid, p_bready;
    reg [ID_W-1:0] p_awid, p_wid, p_bid;
    reg [31:0] p_awaddr;
    reg [7:0]  p_awlen, p_wstrb;
    reg [2:0]  p_awsize;
    reg [1:0]  p_awburst, p_bresp;
    reg [63:0] p_wdata;
    reg        p_wlast;

    initial begin wbeats = 0; bcount = 0; w_before_aw = 0; wlog_n = 0; end

    task dump;                                           // $writememh of words first..last (word indices)
        input [8*1024-1:0] path;
        input integer first, last;
        begin
            $writememh(path, mem, first, last);
        end
    endtask

    // checker (master side of AW / W, slave side of B)
    always @(posedge aclk) begin
        if (aresetn === 1'b1) begin
            if ((s_awvalid !== 1'b0 && s_awvalid !== 1'b1) || (s_wvalid !== 1'b0 && s_wvalid !== 1'b1) ||
                (s_bready !== 1'b0 && s_bready !== 1'b1)) violation(28);
            if (s_awvalid === 1'b1) begin
                if (s_awlen > 8'd15)                 violation(13);
                if (s_awsize != 3'd3)                violation(14);
                if (s_awburst != 2'b01)              violation(15);
                if (s_awaddr[2:0] != 3'd0)           violation(16);
                if ({1'b0, s_awaddr[11:0]} + 8 * ({5'd0, s_awlen} + 1) > 4096) violation(17);
                if (s_awid != {ID_W{1'b0}})          violation(20);
                if (s_awaddr < BASE || ({1'b0, s_awaddr} + 8 * ({25'd0, s_awlen} + 1)) > ({1'b0, BASE} + 8 * MEM_WORDS))
                                                     violation(21);
            end
            if (p_awvalid && !p_awready) begin
                if (s_awvalid !== 1'b1) violation(19);
                else if (s_awid != p_awid || s_awaddr != p_awaddr || s_awlen != p_awlen || s_awsize != p_awsize ||
                         s_awburst != p_awburst) violation(18);
            end
            if (s_wvalid === 1'b1 && s_wid != {ID_W{1'b0}}) violation(23);
            if (p_wvalid && !p_wready) begin
                if (s_wvalid !== 1'b1 || s_wdata != p_wdata || s_wstrb != p_wstrb || s_wlast != p_wlast ||
                    s_wid != p_wid) violation(22);
            end
            if (p_bvalid && !p_bready) begin
                if (!s_bvalid || s_bresp != p_bresp || s_bid != p_bid) violation(26);
            end
        end
        p_awvalid <= (aresetn === 1'b1) && s_awvalid === 1'b1;
        p_awready <= s_awready;
        p_awid <= s_awid; p_awaddr <= s_awaddr; p_awlen <= s_awlen; p_awsize <= s_awsize; p_awburst <= s_awburst;
        p_wvalid <= (aresetn === 1'b1) && s_wvalid === 1'b1;
        p_wready <= s_wready;
        p_wdata <= s_wdata; p_wstrb <= s_wstrb; p_wlast <= s_wlast; p_wid <= s_wid;
        p_bvalid <= (aresetn === 1'b1) && s_bvalid; p_bready <= s_bready;
        p_bresp <= s_bresp; p_bid <= s_bid;
    end

    // write model
    always @(posedge aclk) begin
        if (aresetn !== 1'b1) begin
            s_awready <= 1'b0;
            s_wready  <= 1'b0;
            s_bvalid  <= 1'b0;
            s_bresp   <= 2'b00;
            s_bid     <= {ID_W{1'b0}};
            wa_wr = 0; wa_rd = 0; wa_cnt = 0; wb_wr = 0; wb_rd = 0; wb_cnt = 0; wbt = 0;
            bq_wr = 0; bq_rd = 0; bq_cnt = 0; aw_out = 0; aw_count = 0;
        end else begin
            // B handshake (slave-side check: a B response must belong to a complete burst)
            if (s_bvalid && s_bready === 1'b1) begin
                if (bq_cnt == 0) violation(27);
                else begin
                    bq_rd = (bq_rd + 1) % QDEPTH;
                    bq_cnt = bq_cnt - 1;
                end
                aw_out = aw_out - 1;
                bcount = bcount + 1;
            end
            // W handshake (a beat arriving while no AW waits and none is accepted at this edge is "before AW")
            if (s_wvalid === 1'b1 && s_wready) begin
                if (wa_cnt == 0 && !(s_awvalid === 1'b1 && s_awready)) w_before_aw = w_before_aw + 1;
                wb_data[wb_wr] = s_wdata;
                wb_strb[wb_wr] = s_wstrb;
                wb_last[wb_wr] = s_wlast;
                wb_wr = (wb_wr + 1) % WBUF;
                wb_cnt = wb_cnt + 1;
                wbeats = wbeats + 1;
            end
            // AW handshake
            if (s_awvalid === 1'b1 && s_awready) begin
                wa_addr[wa_wr] = s_awaddr;
                wa_len[wa_wr]  = s_awlen + 1;
                wa_err[wa_wr]  = (aw_count == b_err_burst);
                wa_wr  = (wa_wr + 1) % QDEPTH;
                wa_cnt = wa_cnt + 1;
                aw_out = aw_out + 1;
                aw_count = aw_count + 1;
                if (wlog_n < LOG_MAX) begin wlog_addr[wlog_n] = s_awaddr; wlog_len[wlog_n] = s_awlen + 1; end
                wlog_n = wlog_n + 1;
            end
            // pair one buffered W beat with the oldest incomplete AW
            if (wa_cnt != 0 && wb_cnt != 0) begin
                wa = wa_addr[wa_rd] + 8 * wbt;
                wi = (wa - BASE) / 8;
                if (wa >= BASE && wi < MEM_WORDS)
                    for (wk = 0; wk < 8; wk = wk + 1)
                        if (wb_strb[wb_rd][wk]) mem[wi][8*wk +: 8] = wb_data[wb_rd][8*wk +: 8];
                if (wb_last[wb_rd] && wbt < wa_len[wa_rd] - 1) violation(24);
                if (!wb_last[wb_rd] && wbt == wa_len[wa_rd] - 1) violation(25);
                if (wb_last[wb_rd] || wbt == wa_len[wa_rd] - 1) begin
                    // burst complete: schedule its B response
                    bq_ready[bq_wr] = cyc + b_lat_min - 1 +
                                      ((b_lat_max > b_lat_min) ? ({$random(seed)} % (b_lat_max - b_lat_min + 1)) : 0);
                    bq_err[bq_wr] = wa_err[wa_rd];
                    bq_wr = (bq_wr + 1) % QDEPTH;
                    bq_cnt = bq_cnt + 1;
                    wa_rd = (wa_rd + 1) % QDEPTH;
                    wa_cnt = wa_cnt - 1;
                    wbt = 0;
                end else
                    wbt = wbt + 1;
                wb_rd = (wb_rd + 1) % WBUF;
                wb_cnt = wb_cnt - 1;
            end
            // next B response (BVALID only changes when it is 0 or was just accepted)
            if (!s_bvalid || s_bready === 1'b1) begin
                if (bq_cnt != 0 && cyc >= bq_ready[bq_rd]) begin
                    s_bvalid <= 1'b1;
                    s_bresp  <= bq_err[bq_rd] ? 2'b10 : 2'b00;
                    s_bid    <= {ID_W{1'b0}};
                end else
                    s_bvalid <= 1'b0;
            end
            // readies for the next cycle (random back-pressure every cycle; no random draw when the percentage is
            // 0, so a read-only testbench sees exactly the step 3.4 sequence)
            s_awready <= (aw_out < max_out_wr) && !(aw_bp_pct > 0 && urand100(0) < aw_bp_pct);
            s_wready  <= (wb_cnt < WBUF - 1) && !(w_bp_pct > 0 && urand100(0) < w_bp_pct);
        end
    end

endmodule
