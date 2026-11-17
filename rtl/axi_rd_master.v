// axi_rd_master: HP0 read master, spec/interface.md section 10.
//
// Executes row read commands (cmd_addr, cmd_words 1..64, cmd_slot) from prefetch_ctrl as AXI3 read bursts:
// 64-bit beats, ARSIZE = 3, ARBURST = INCR, ARID = 0, at most 16 beats, never across a 4 KB boundary.
// Splitting (spec section 10, = memmodel.split_bursts): the next burst starts at a,
//     length = min(remaining, 16, (4096 - a mod 4096) / 8) beats;   a += 8 * length.
// min(16, (4096 - a mod 4096) / 8) only differs from 16 in the last 128 bytes of a page:
//     a[11:7] == 5'h1F and a[6:3] != 0  ->  16 - a[6:3]   (a is 8-byte aligned, so a[2:0] = 0).
//
// AR side. The burst source is the current command (registers s_*) or, when no command is in progress, the
// command on the input port (bypass: command handshake in cycle t -> ARVALID in cycle t + 1, "command to first
// AR: 1 cycle"). The length is computed separately for both sources (the in-progress source's 4 KB room is
// precomputed in s_room) and selected at the end, so no long path starts at s_active or cmd_addr. One burst is loaded into the registered AR outputs per cycle when the AR register is free
// (ARVALID = 0 or ARREADY = 1) and fewer than RD_OUTSTANDING bursts are in flight. A burst counts as in flight
// from the cycle it is loaded into the AR register until its last R beat. cmd_ready = no command in progress
// and a burst can be loaded now, so the first burst of the next command follows the last burst of the
// previous one without a gap (one AR per cycle). cmd_ready depends on m_axi_hp0_arready (a ready -> ready path;
// no path from a ready input to a valid output).
//
// R side. A burst-info FIFO (RD_OUTSTANDING entries: slot, first word, beats - 1, last-of-command) records each
// issued burst (written one cycle after the issue, from the AR register); R beats are matched to it in order (single ID). RREADY = 1 always (prefetch_ctrl always
// accepts; spec section 5). Every R beat appears one cycle later on rd_* (registered), with
//     rd_slot = slot of its command, rd_word = word index inside the command (0..cmd_words-1),
//     rd_cmd_last = last beat of the command, rd_beat = 1 (to ctrl_fsm: BYTES_RD += 8, spec section 13),
//     rd_err = 1 when RRESP != OKAY (open question Q1: the data is delivered unchanged and the frame goes on;
//     rd_err is for the BUS_ERROR status planned in step 3.7).
// RLAST and RID are not used by the logic (the FIFO knows the burst length); RLAST is compared with the
// expected beat in simulation only (sim_err, between translate_off / translate_on).
//
// PATRM_FAULT_NO4K (test only): the 4 KB term is dropped from the split. tb_axi_rd_master must fail with it.
module axi_rd_master #(
    parameter RD_OUTSTANDING = 8,                        // bursts in flight (>= 2; spec section 0)
    parameter ID_W           = 6,
    parameter SLOT_W         = 5,                        // NSLOT = 32
    parameter WORD_W         = 6,                        // word in a slot, 0..63
    parameter WORDS_W        = 7                         // cmd_words 1..64
) (
    input  wire               aclk,
    input  wire               aresetn,                   // synchronous, active low
    // row read commands from prefetch_ctrl
    input  wire               cmd_valid,
    output wire               cmd_ready,
    input  wire [31:0]        cmd_addr,                  // 8-byte aligned
    input  wire [WORDS_W-1:0] cmd_words,                 // 1..64
    input  wire [SLOT_W-1:0]  cmd_slot,
    // HP0 read address channel
    output wire [ID_W-1:0]    m_axi_hp0_arid,
    output reg  [31:0]        m_axi_hp0_araddr,
    output reg  [3:0]         m_axi_hp0_arlen,           // beats - 1 (AXI3)
    output wire [2:0]         m_axi_hp0_arsize,
    output wire [1:0]         m_axi_hp0_arburst,
    output wire [1:0]         m_axi_hp0_arlock,
    output wire [3:0]         m_axi_hp0_arcache,
    output wire [2:0]         m_axi_hp0_arprot,
    output wire [3:0]         m_axi_hp0_arqos,
    output reg                m_axi_hp0_arvalid,
    input  wire               m_axi_hp0_arready,
    // HP0 read data channel
    input  wire [ID_W-1:0]    m_axi_hp0_rid,             // ignored (single ID, in order)
    input  wire [63:0]        m_axi_hp0_rdata,
    input  wire [1:0]         m_axi_hp0_rresp,
    input  wire               m_axi_hp0_rlast,           // simulation check only
    input  wire               m_axi_hp0_rvalid,
    output wire               m_axi_hp0_rready,
    // beats to prefetch_ctrl (valid only, no back-pressure)
    output reg                rd_valid,
    output reg  [63:0]        rd_data,                   // byte k = bits 8k+7:8k (address order)
    output reg  [SLOT_W-1:0]  rd_slot,
    output reg  [WORD_W-1:0]  rd_word,
    output reg                rd_cmd_last,
    output reg                rd_beat,                   // to ctrl_fsm: BYTES_RD += 8
    output reg                rd_err                     // RRESP != OKAY on this beat (Q1)
);

    localparam PTR_W = (RD_OUTSTANDING > 1) ? $clog2(RD_OUTSTANDING) : 1;
    localparam CNT_W = $clog2(RD_OUTSTANDING + 1);

    assign m_axi_hp0_arid    = {ID_W{1'b0}};
    assign m_axi_hp0_arsize  = 3'b011;                   // 8 bytes per beat
    assign m_axi_hp0_arburst = 2'b01;                    // INCR
    assign m_axi_hp0_arlock  = 2'b00;
    assign m_axi_hp0_arcache = 4'b0011;
    assign m_axi_hp0_arprot  = 3'b000;
    assign m_axi_hp0_arqos   = 4'b0000;
    assign m_axi_hp0_rready  = 1'b1;

    // ---------------- command in progress ----------------
    reg               s_active;
    reg [31:0]        s_addr;                            // next burst address
    reg [WORDS_W-1:0] s_rem;                             // words still to request
    reg [WORD_W-1:0]  s_word;                            // word index of the next burst inside the command
    reg [SLOT_W-1:0]  s_slot;
    reg [4:0]         s_room;                            // min(16, beats from s_addr to the 4 KB boundary)

    // Burst length, computed separately for the two sources and selected at the end (timing, spec section 15).
    // Input port: room from cmd_addr. Command in progress: room precomputed in s_room.
`ifdef PATRM_FAULT_NO4K
    wire [4:0] c_room = 5'd16;
`else
    wire       c_near = (cmd_addr[11:7] == 5'h1F) && (cmd_addr[6:3] != 4'd0);
    wire [4:0] c_room = c_near ? (5'd16 - {1'b0, cmd_addr[6:3]}) : 5'd16;
`endif
    wire       c_fits = (cmd_words <= {{(WORDS_W-5){1'b0}}, c_room});
    wire       s_fits = (s_rem     <= {{(WORDS_W-5){1'b0}}, s_room});
    wire [4:0] c_blen = c_fits ? cmd_words[4:0] : c_room;
    wire [4:0] s_blen = s_fits ? s_rem[4:0]     : s_room;

    // burst source: the command in progress, else the input port (bypass)
    wire [31:0]        src_addr  = s_active ? s_addr : cmd_addr;
    wire [WORDS_W-1:0] src_rem   = s_active ? s_rem  : cmd_words;
    wire [WORD_W-1:0]  src_word  = s_active ? s_word : {WORD_W{1'b0}};
    wire [SLOT_W-1:0]  src_slot  = s_active ? s_slot : cmd_slot;
    wire [4:0]         src_room  = s_active ? s_room : c_room;
    wire               fits      = s_active ? s_fits : c_fits;     // this burst ends the command
    wire [4:0]         blen      = s_active ? s_blen : c_blen;     // 1..16 beats
    wire               src_valid = s_active | cmd_valid;

    // State after a burst that does NOT end the command (the only case in which s_* is used): its length is
    // src_room, so the next address is src_addr + 8 * src_room. That address is 4 KB aligned when src_room < 16
    // (room 16 next), else src_addr + 128, whose room is 16 - src_addr[6:3] when src_addr[11:7] == 30.
`ifdef PATRM_FAULT_NO4K
    wire [4:0] n_room = 5'd16;
`else
    wire       n_near = (src_addr[11:7] == 5'h1E) && (src_addr[6:3] != 4'd0);
    wire [4:0] n_room = n_near ? (5'd16 - {1'b0, src_addr[6:3]}) : 5'd16;
`endif

    // ---------------- burst-info FIFO ----------------
    reg [SLOT_W-1:0] fi_slot  [0:RD_OUTSTANDING-1];
    reg [WORD_W-1:0] fi_word  [0:RD_OUTSTANDING-1];
    reg [3:0]        fi_lenm1 [0:RD_OUTSTANDING-1];
    reg              fi_last  [0:RD_OUTSTANDING-1];
    reg [PTR_W-1:0]  wp, rp;
    reg [CNT_W-1:0]  cnt;                                // bursts in flight (counted from the issue cycle)
    reg [3:0]        bcnt;                               // beat index inside the head burst
    reg              push;                               // write the burst in the AR register into the FIFO
    reg [SLOT_W-1:0] ar_slot;                            // side information of the burst in the AR register
    reg [WORD_W-1:0] ar_word;
    reg              ar_last;

    wire ar_free = !m_axi_hp0_arvalid || m_axi_hp0_arready;
    wire room_ok = (cnt != RD_OUTSTANDING[CNT_W-1:0]);
    wire issue   = src_valid && ar_free && room_ok;
    assign cmd_ready = !s_active && ar_free && room_ok;

    wire r_hs      = m_axi_hp0_rvalid;                   // RREADY = 1
    wire r_lastbt  = (bcnt == fi_lenm1[rp]);
    wire pop       = r_hs && r_lastbt;

    function [PTR_W-1:0] inc;
        input [PTR_W-1:0] p;
        begin
            inc = (p == RD_OUTSTANDING - 1) ? {PTR_W{1'b0}} : p + 1'b1;
        end
    endfunction

    // AR channel and command state
    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axi_hp0_arvalid <= 1'b0;
            s_active          <= 1'b0;
            push              <= 1'b0;
        end else begin
            push <= issue;
            if (issue) begin
                m_axi_hp0_arvalid <= 1'b1;
                s_active          <= !fits;
            end else if (m_axi_hp0_arready)
                m_axi_hp0_arvalid <= 1'b0;
        end
    end

    always @(posedge aclk) begin
        if (issue) begin
            m_axi_hp0_araddr <= src_addr;
            m_axi_hp0_arlen  <= blen - 5'd1;
            ar_slot          <= src_slot;
            ar_word          <= src_word;
            ar_last          <= fits;
            s_addr           <= src_addr + {24'd0, src_room, 3'b000};
            s_rem            <= src_rem - {{(WORDS_W-5){1'b0}}, src_room};
            s_word           <= src_word + {{(WORD_W-5){1'b0}}, src_room};
            s_slot           <= src_slot;
            s_room           <= n_room;
        end
    end

    // The FIFO entry is written one cycle after the issue, from the AR register. The first R beat of that burst
    // can arrive at the earliest two cycles after the issue (ARVALID one cycle after the issue, R after the AR
    // handshake), when the entry is already there.
    always @(posedge aclk) begin
        if (push) begin
            fi_slot[wp]  <= ar_slot;
            fi_word[wp]  <= ar_word;
            fi_lenm1[wp] <= m_axi_hp0_arlen;
            fi_last[wp]  <= ar_last;
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            wp   <= {PTR_W{1'b0}};
            rp   <= {PTR_W{1'b0}};
            cnt  <= {CNT_W{1'b0}};
            bcnt <= 4'd0;
        end else begin
            if (push) wp <= inc(wp);
            if (pop)  rp <= inc(rp);
            if (issue && !pop)      cnt <= cnt + 1'b1;
            else if (pop && !issue) cnt <= cnt - 1'b1;
            if (r_hs) bcnt <= r_lastbt ? 4'd0 : bcnt + 4'd1;
        end
    end

    // R beat -> rd_* (registered)
    always @(posedge aclk) begin
        if (!aresetn) begin
            rd_valid    <= 1'b0;
            rd_cmd_last <= 1'b0;
            rd_beat     <= 1'b0;
            rd_err      <= 1'b0;
        end else begin
            rd_valid    <= r_hs;
            rd_beat     <= r_hs;
            rd_cmd_last <= r_hs && r_lastbt && fi_last[rp];
            rd_err      <= r_hs && (m_axi_hp0_rresp != 2'b00);
        end
    end

    always @(posedge aclk) begin
        if (r_hs) begin
            rd_data <= m_axi_hp0_rdata;
            rd_slot <= fi_slot[rp];
            rd_word <= fi_word[rp] + {{(WORD_W-4){1'b0}}, bcnt};
        end
    end

    // ---------------- simulation checks ----------------
    // synthesis translate_off
    integer sim_err;
    initial sim_err = 0;
    always @(posedge aclk) begin
        if (aresetn === 1'b1) begin
            if (m_axi_hp0_rvalid === 1'b1 && cnt == 0) begin
                sim_err = sim_err + 1;
                $display("AXI_RD_MASTER ERROR at %0t: R beat without an outstanding burst", $time);
            end else if (m_axi_hp0_rvalid === 1'b1 && m_axi_hp0_rlast !== r_lastbt) begin
                sim_err = sim_err + 1;
                $display("AXI_RD_MASTER ERROR at %0t: RLAST = %b, expected %b (beat %0d of %0d)", $time,
                         m_axi_hp0_rlast, r_lastbt, bcnt, fi_lenm1[rp] + 1);
            end
            if (cmd_valid === 1'b1 && cmd_ready &&
                (cmd_words == 0 || cmd_words > 64 || cmd_addr[2:0] != 3'd0)) begin
                sim_err = sim_err + 1;
                $display("AXI_RD_MASTER ERROR at %0t: bad command addr 0x%08h words %0d", $time, cmd_addr, cmd_words);
            end
        end
    end
    // synthesis translate_on

endmodule
