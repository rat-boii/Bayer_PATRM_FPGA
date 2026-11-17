// axi_mem: behavioural AXI3 slave memory model of the Zynq HP0 port (testbench only, not synthesisable).
//
// Read channel (step 3.4). The write channel (AW / W / B) is added in step 3.5 at the marked place.
//   - Memory: MEM_WORDS 64-bit words at BASE (the SRC_ADDR window, 0x1000_0000), loaded with $readmemh from
//     +MEM_FILE=<path> (or the MEM_FILE parameter). Byte k of a word = bits 8k+7:8k (address order).
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
// Knobs: parameters give the defaults; plusargs +MEM_LAT_MIN, +MEM_LAT_MAX, +MEM_AR_BP, +MEM_R_GAP,
// +MEM_ERR_BURST, +MEM_MAX_OUT, +MEM_SEED override them at time 0; a testbench may change the knob registers
// (lat_min, lat_max, ar_bp_pct, r_gap_pct, err_burst, max_out, seed) between transfers.
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
    parameter        VERBOSE   = 20                      // violations printed in full (all are counted)
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
    input  wire            s_rready
    // AW / W / B: step 3.5
);

    // ---------------- knobs ----------------
    integer lat_min, lat_max, ar_bp_pct, r_gap_pct, err_burst, max_out, seed;
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
    reg [31:0] log_addr [0:LOG_MAX-1];
    reg [4:0]  log_len  [0:LOG_MAX-1];
    integer    rbeats;                                   // R handshakes since time 0 (for the testbench)

    // checker
    localparam NV = 16;
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
    end

    task violation;
        input integer v;
        begin
            viol[v] = viol[v] + 1;
            viol_total = viol_total + 1;
            if (viol_total <= VERBOSE)
                $display("AXI_MEM VIOLATION at %0t: %0s (araddr 0x%08h arlen %0d arvalid %b arready %b)", $time,
                         vname[v], s_araddr, s_arlen, s_arvalid, s_arready);
        end
    endtask

    task report;                                         // summary for the testbench
        begin
            $display("AXI_MEM checker: %0d violations, %0d bursts logged", viol_total, log_n);
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

    // ---------------- write channel: step 3.5 ----------------

endmodule
