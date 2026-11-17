// axi_wr_master: HP1 write master, spec/interface.md section 11.
//
// Writes the output frame row by row: row u at DST_ADDR + u W. Each row is split like the reads (spec section 10,
// = memmodel.split_bursts): the next burst starts at a, length = min(words left in the row, 16,
// (4096 - a mod 4096) / 8) beats; a += 8 * length. Rows are contiguous in memory, so a simply runs on; only
// the words-left counter restarts at W / 8 for every row. AXI3, 64-bit beats, AWSIZE = 3, INCR, AWID = WID = 0,
// WSTRB = 8'hFF (gray mode; Option A hook: section 14).
//
// AW. An AW is issued only when all its beats are in out_fifo and not yet promised to an earlier burst:
//     wq_count - pending_w >= length       (pending_w = beats of issued bursts not yet taken from out_fifo)
// so W never waits mid-burst. At most WR_OUTSTANDING bursts are without B response (UG585: HP write acceptance
// 8 to 32; Q3). A burst counts from its issue into the AW register to its B response. Registered AW outputs;
// wq_count reaching the burst length -> AWVALID: 1 cycle. The length is computed one cycle ahead (spec section 15):
// blen_r / fits_r are registered from a and rem, which only change at an issue or at frame_start; in the cycle
// after such a change they are not valid yet (len_ok = 0) and no AW is issued. So at most one AW every 2 cycles,
// far more than needed (the pixel input fills at most one word per 8 cycles).
//
// W. A burst's W beats start no earlier than its AW: the burst length is written into a small FIFO one cycle
// after the issue, and the W output register loads beats from out_fifo only for bursts in that FIFO, so the
// first WVALID of a burst comes at the earliest one cycle after its AWVALID. Registered W outputs (one-entry
// output register, 1 beat per clock); wq_ready = the register is loaded (a ready -> ready path from wready).
//
// B. BREADY = 1 always. Each B response decrements the outstanding count; wr_err = 1 for one cycle per B
// response with BRESP != OKAY (open question Q1: the frame still completes; the BUS_ERROR status is wired in
// step 3.7). wr_frame_done pulses once per frame, in the cycle after the last B response of the frame
// arrived (all rows issued and no burst outstanding), so DONE is never set before the data is in DDR.
// wr_beat = one W beat accepted (to ctrl_fsm: BYTES_WR += 8), one cycle after the W handshake.
//
// Test-only faults: PATRM_FAULT_NO4K_WR drops the 4 KB term of the split; PATRM_FAULT_EARLY_DONE raises
// wr_frame_done after the last W beat instead of after the last B response. tb_out_path must fail with either.
module axi_wr_master #(
    parameter WR_OUTSTANDING = 8,                        // bursts without B response (<= 8, Q3)
    parameter ID_W           = 6,
    parameter SIZE_BITS      = 13,                       // WIDTH / HEIGHT (D11: <= 4096)
    parameter CNT_W          = 7                         // wq_count width (OUT_DEPTH = 64)
) (
    input  wire                 aclk,
    input  wire                 aresetn,                 // synchronous, active low
    input  wire                 frame_start,
    input  wire [31:0]          cfg_dst_addr,            // 4 KB aligned (memory_map.md)
    input  wire [SIZE_BITS-1:0] cfg_width,               // multiple of 8
    input  wire [SIZE_BITS-1:0] cfg_height,
    // words from out_fifo
    input  wire                 wq_valid,
    output wire                 wq_ready,
    input  wire [63:0]          wq_data,
    input  wire [CNT_W-1:0]     wq_count,
    // HP1 write address channel
    output wire [ID_W-1:0]      m_axi_hp1_awid,
    output reg  [31:0]          m_axi_hp1_awaddr,
    output reg  [3:0]           m_axi_hp1_awlen,         // beats - 1 (AXI3)
    output wire [2:0]           m_axi_hp1_awsize,
    output wire [1:0]           m_axi_hp1_awburst,
    output wire [1:0]           m_axi_hp1_awlock,
    output wire [3:0]           m_axi_hp1_awcache,
    output wire [2:0]           m_axi_hp1_awprot,
    output wire [3:0]           m_axi_hp1_awqos,
    output reg                  m_axi_hp1_awvalid,
    input  wire                 m_axi_hp1_awready,
    // HP1 write data channel
    output wire [ID_W-1:0]      m_axi_hp1_wid,
    output reg  [63:0]          m_axi_hp1_wdata,
    output wire [7:0]           m_axi_hp1_wstrb,
    output reg                  m_axi_hp1_wlast,
    output reg                  m_axi_hp1_wvalid,
    input  wire                 m_axi_hp1_wready,
    // HP1 write response channel
    input  wire [ID_W-1:0]      m_axi_hp1_bid,           // ignored (single ID, in order)
    input  wire [1:0]           m_axi_hp1_bresp,
    input  wire                 m_axi_hp1_bvalid,
    output wire                 m_axi_hp1_bready,
    // to ctrl_fsm
    output reg                  wr_beat,                 // BYTES_WR += 8
    output reg                  wr_frame_done,           // pulse: last B response of the frame received
    output reg                  wr_err                   // BRESP != OKAY on this B response (Q1)
);

    localparam ROWW_W = SIZE_BITS - 3;                   // words per row: W / 8 <= 512
    localparam PTR_W  = (WR_OUTSTANDING > 1) ? $clog2(WR_OUTSTANDING) : 1;
    localparam OUT_W  = $clog2(WR_OUTSTANDING + 1);
    localparam PEND_W = CNT_W + 1;                       // pending_w <= WR_OUTSTANDING * 16, and <= wq_count

    assign m_axi_hp1_awid    = {ID_W{1'b0}};
    assign m_axi_hp1_awsize  = 3'b011;
    assign m_axi_hp1_awburst = 2'b01;
    assign m_axi_hp1_awlock  = 2'b00;
    assign m_axi_hp1_awcache = 4'b0011;
    assign m_axi_hp1_awprot  = 3'b000;
    assign m_axi_hp1_awqos   = 4'b0000;
    assign m_axi_hp1_wid     = {ID_W{1'b0}};
    assign m_axi_hp1_wstrb   = 8'hFF;
    assign m_axi_hp1_bready  = 1'b1;

    // ---------------- frame state ----------------
    reg                 active;                          // frame in progress (frame_start .. wr_frame_done)
    reg [31:0]          a;                               // next burst address
    reg [ROWW_W-1:0]    row_words;                       // W / 8
    reg [ROWW_W-1:0]    rem;                             // words left in the current row
    reg [SIZE_BITS-1:0] rows_left;                       // rows not completely issued
    reg [OUT_W-1:0]     outst;                           // bursts issued without B response
    reg [PEND_W-1:0]    pending_w;                       // beats promised to issued bursts, not yet taken

    // burst length from registers: min(rem, 16, beats to the 4 KB boundary)
`ifdef PATRM_FAULT_NO4K_WR
    wire [4:0] room = 5'd16;
`else
    wire       near_end = (a[11:7] == 5'h1F) && (a[6:3] != 4'd0);
    wire [4:0] room = near_end ? (5'd16 - {1'b0, a[6:3]}) : 5'd16;
`endif
    wire       fits = (rem <= {{(ROWW_W-5){1'b0}}, room});     // this burst ends the row
    wire [4:0] blen = fits ? rem[4:0] : room;
    reg  [4:0] blen_r;                                          // blen / fits, one cycle later
    reg        fits_r;
    reg        len_ok;                                          // blen_r / fits_r match the current a / rem

    wire [PEND_W-1:0] free_w = {1'b0, wq_count} - pending_w;    // words in out_fifo not promised yet
    wire words_ok = (free_w >= {{(PEND_W-5){1'b0}}, blen_r});
    wire ar_free  = !m_axi_hp1_awvalid || m_axi_hp1_awready;
    wire issue    = active && len_ok && (rows_left != {SIZE_BITS{1'b0}}) && ar_free &&
                    (outst != WR_OUTSTANDING[OUT_W-1:0]) && words_ok;

    // ---------------- W burst FIFO (lengths of issued bursts) ----------------
    reg [3:0]       wb_lenm1 [0:WR_OUTSTANDING-1];
    reg [PTR_W-1:0] wb_wp, wb_rp;
    reg [OUT_W-1:0] wb_cnt;
    reg             wb_push;                             // write the burst in the AW register into the FIFO
    reg [3:0]       wbeat;                               // beat index inside the head burst

    wire w_free = !m_axi_hp1_wvalid || m_axi_hp1_wready;
    wire w_load = w_free && (wb_cnt != {OUT_W{1'b0}}) && wq_valid;
    wire w_lastb = (wbeat == wb_lenm1[wb_rp]);
    wire w_pop  = w_load && w_lastb;
    assign wq_ready = w_load;

    wire b_hs = m_axi_hp1_bvalid;                        // BREADY = 1

    function [PTR_W-1:0] inc;
        input [PTR_W-1:0] p;
        begin
            inc = (p == WR_OUTSTANDING - 1) ? {PTR_W{1'b0}} : p + 1'b1;
        end
    endfunction

`ifdef PATRM_FAULT_EARLY_DONE
    wire frame_end = active && (rows_left == {SIZE_BITS{1'b0}}) && !m_axi_hp1_awvalid && (wb_cnt == 0) &&
                     !m_axi_hp1_wvalid && !wb_push;
`else
    wire frame_end = active && (rows_left == {SIZE_BITS{1'b0}}) && (outst == {OUT_W{1'b0}});
`endif

    // AW channel, frame state
    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axi_hp1_awvalid <= 1'b0;
            active            <= 1'b0;
            rows_left         <= {SIZE_BITS{1'b0}};
            outst             <= {OUT_W{1'b0}};
            pending_w         <= {PEND_W{1'b0}};
            wb_push           <= 1'b0;
            wr_frame_done     <= 1'b0;
            len_ok            <= 1'b0;
        end else begin
            len_ok        <= !(frame_start || issue);
            wb_push       <= issue;
            wr_frame_done <= 1'b0;
            if (frame_start) begin
                active    <= 1'b1;
                rows_left <= cfg_height;
            end else begin
                if (issue && fits_r) rows_left <= rows_left - 1'b1;
                if (frame_end) begin
                    active        <= 1'b0;
                    wr_frame_done <= 1'b1;
                end
            end
            if (issue)                        m_axi_hp1_awvalid <= 1'b1;
            else if (m_axi_hp1_awready)       m_axi_hp1_awvalid <= 1'b0;
            if (issue && !b_hs)               outst <= outst + 1'b1;
            else if (b_hs && !issue)          outst <= outst - 1'b1;
            pending_w <= pending_w + (issue ? {{(PEND_W-5){1'b0}}, blen_r} : {PEND_W{1'b0}})
                                   - (w_load ? {{(PEND_W-1){1'b0}}, 1'b1} : {PEND_W{1'b0}});
        end
    end

    always @(posedge aclk) begin
        if (frame_start) begin
            a         <= cfg_dst_addr;
            row_words <= cfg_width[SIZE_BITS-1:3];
            rem       <= cfg_width[SIZE_BITS-1:3];
        end else if (issue) begin
            m_axi_hp1_awaddr <= a;
            m_axi_hp1_awlen  <= blen_r - 5'd1;
            a                <= a + {24'd0, blen_r, 3'b000};
            rem              <= fits_r ? row_words : rem - {{(ROWW_W-5){1'b0}}, blen_r};
        end
        blen_r <= blen;
        fits_r <= fits;
    end

    // W channel
    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axi_hp1_wvalid <= 1'b0;
            wb_wp  <= {PTR_W{1'b0}};
            wb_rp  <= {PTR_W{1'b0}};
            wb_cnt <= {OUT_W{1'b0}};
            wbeat  <= 4'd0;
        end else begin
            if (w_load)                 m_axi_hp1_wvalid <= 1'b1;
            else if (m_axi_hp1_wready)  m_axi_hp1_wvalid <= 1'b0;
            if (wb_push) wb_wp <= inc(wb_wp);
            if (w_pop)   wb_rp <= inc(wb_rp);
            if (wb_push && !w_pop)      wb_cnt <= wb_cnt + 1'b1;
            else if (w_pop && !wb_push) wb_cnt <= wb_cnt - 1'b1;
            if (w_load) wbeat <= w_lastb ? 4'd0 : wbeat + 4'd1;
        end
    end

    always @(posedge aclk) begin
        if (wb_push) wb_lenm1[wb_wp] <= m_axi_hp1_awlen;
        if (w_load) begin
            m_axi_hp1_wdata <= wq_data;
            m_axi_hp1_wlast <= w_lastb;
        end
    end

    // to ctrl_fsm
    always @(posedge aclk) begin
        if (!aresetn) begin
            wr_beat <= 1'b0;
            wr_err  <= 1'b0;
        end else begin
            wr_beat <= m_axi_hp1_wvalid && m_axi_hp1_wready;
            wr_err  <= b_hs && (m_axi_hp1_bresp != 2'b00);
        end
    end

    // ---------------- simulation checks ----------------
    // synthesis translate_off
    integer sim_err;
    initial sim_err = 0;
    always @(posedge aclk) begin
        if (aresetn === 1'b1) begin
            if (m_axi_hp1_bvalid === 1'b1 && outst == 0) begin
                sim_err = sim_err + 1;
                $display("AXI_WR_MASTER ERROR at %0t: B response without an outstanding burst", $time);
            end
            if (w_load && !wq_valid) begin
                sim_err = sim_err + 1;
                $display("AXI_WR_MASTER ERROR at %0t: W beat taken from an empty out_fifo", $time);
            end
            if (frame_start && (cfg_width[2:0] != 3'd0 || cfg_width == 0 || cfg_height == 0 ||
                                cfg_dst_addr[11:0] != 12'd0)) begin
                sim_err = sim_err + 1;
                $display("AXI_WR_MASTER ERROR at %0t: bad frame W %0d H %0d DST 0x%08h", $time, cfg_width,
                         cfg_height, cfg_dst_addr);
            end
        end
    end
    // synthesis translate_on

endmodule
