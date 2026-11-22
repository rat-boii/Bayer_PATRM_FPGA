// prefetch_ctrl: fetch records -> row read commands -> line_buf writes (spec/interface.md section 5), step 3.6b.
//
// Fetching blocks (nrows > 0) are numbered from 0 at frame_start, in fetch-record order.
//   prep pipeline (ce rule, spec section 0), one record per stage:
//     P1  record registers; DSP operands row_top, W
//     P2  m = row_top * W (DSP48E1 M register); off = SRC_ADDR + s_col, off_w = off + row step
//     P3  addr_top = m + off, addr_bot = m + off_w. Row step = W (gray: row_bot = row_top + 1 whenever it is fetched,
//         nrows = 2) or 2W (Bayer Option A, cfg_stride2 = 1: the next plane row is memory row row_top + 2, spec 18.3)
//     IS  issue: top row first, then bottom; a row with fetch = 1 waits until its slot is free, then one command
//         (cmd_valid stays 1 until cmd_ready: a slot can only become free while waiting). When the record is done
//         (all its commands accepted): its slots get last_user = this block and busy = 1, and one entry
//         {number of commands} goes into the ready queue.
//   slot free (spec 5, "last_user[slot] < blocks_done"): kept as a busy bit per slot, set when a block that uses
//     the slot (fetched or reused) leaves IS, cleared by blk_done of the block equal to last_user[slot]. Same
//     condition as the spec compare while fewer than 2^15 blocks are in flight (at most about 40 are), but it never
//     wraps: a 16-bit modulo compare of last_user against blocks_done would see a slot whose last user is more
//     than 2^15 blocks old as "in the future" (long runs of reused rows on a 4096 x 4096 frame).
//   line_buf write (1 cycle after the beat): words are stored by source column (spec 6.2, option A): slot word
//     p = (s_col / 8 + rd_word) mod SLOT_WORDS, bank p[0], entry slot * SLOT_WORDS/2 + p[5:1]. s_col / 8 of the
//     command in flight for a slot is kept in base[slot] (written at the command handshake; a slot gets a new
//     command only after every block using it was read out, so after all beats of the previous one).
//   blocks_ready: the ready queue pops its head when that many commands have been written completely (reads
//     return in order); a record without commands pops as soon as it is at the head (in order).
//   frame_start in the middle of a frame: commands already accepted by axi_rd_master still return beats; they
//     are counted (cmd_out) and their beats dropped (not written, not counted as complete).
// Ports as spec section 5, plus frame_start.
// Test only: PATRM_FAULT_A_ROWSTEP fetches the bottom row at top + W in Option A; tb_patrm_top TB_BAYER_A must fail.
module prefetch_ctrl #(
    parameter SIZE_BITS  = 13,
    parameter CNT_BITS   = 7,                             // fetch_words / cmd_words 1..64
    parameter SLOT_BITS  = 5,                             // NSLOT = 2^SLOT_BITS
    parameter WORD_BITS  = 6,                             // SLOT_WORDS = 2^WORD_BITS = SPAN_MAX / 8
    parameter BLK_BITS   = 16,                            // block counters (spec 5)
    parameter RQ_DEPTH   = 16,                            // ready queue (records done in IS, not yet ready)
    parameter RQ_BITS    = 4                              // log2(RQ_DEPTH)
) (
    input  wire                     aclk,
    input  wire                     aresetn,
    input  wire                     frame_start,
    input  wire [31:0]              cfg_src_addr,
    input  wire [SIZE_BITS-1:0]     cfg_width,           // full row stride W in bytes (both modes)
    input  wire                     cfg_stride2,         // Bayer Option A pass: bottom row = top + 2W
    // fetch records (block_planner)
    input  wire                     fetch_valid,
    output wire                     fetch_ready,
    input  wire [SIZE_BITS-1:0]     fetch_row_top,
    input  wire [SIZE_BITS-1:0]     fetch_row_bot,       // = row_top + 1 (gray) / + 2 (Option A) when fetched (not used, see P3)
    input  wire [SLOT_BITS-1:0]     fetch_slot_top,
    input  wire [SLOT_BITS-1:0]     fetch_slot_bot,
    input  wire                     fetch_top,
    input  wire                     fetch_bot,
    input  wire [SIZE_BITS-1:0]     fetch_s_col,
    input  wire [CNT_BITS-1:0]      fetch_words,
    // row read commands (axi_rd_master)
    output wire                     cmd_valid,
    input  wire                     cmd_ready,
    output wire [31:0]              cmd_addr,
    output wire [CNT_BITS-1:0]      cmd_words,
    output wire [SLOT_BITS-1:0]     cmd_slot,
    // beats (axi_rd_master), no back-pressure
    input  wire                     rd_valid,
    input  wire [63:0]              rd_data,
    input  wire [SLOT_BITS-1:0]     rd_slot,
    input  wire [WORD_BITS-1:0]     rd_word,              // word of the beat inside its command
    input  wire                     rd_cmd_last,
    // line_buf write
    output reg                      buf_we,
    output reg                      buf_wbank,
    output reg  [SLOT_BITS+WORD_BITS-2:0] buf_waddr,
    output reg  [63:0]              buf_wdata,
    // block counters
    output reg  [BLK_BITS-1:0]      blocks_ready,
    input  wire                     blk_done
);

    localparam NSLOT = 1 << SLOT_BITS;

    // ------------------------------------------------------------------ frame configuration
    reg [31:0]          src_r;
    reg [SIZE_BITS-1:0] w_r;
    reg [SIZE_BITS:0]   step_r;                          // memory distance top row -> bottom row: W or 2W
    always @(posedge aclk) begin
        if (frame_start) begin
            src_r  <= cfg_src_addr;
            w_r    <= cfg_width;
`ifdef PATRM_FAULT_A_ROWSTEP
            step_r <= {1'b0, cfg_width};                 // test-only fault: bottom row at top + W in Option A too
`else
            step_r <= cfg_stride2 ? {cfg_width, 1'b0} : {1'b0, cfg_width};
`endif
        end
    end

    // ------------------------------------------------------------------ issue stage (IS) state
    reg                     is_valid, is_nt, is_nb;      // record present; top / bottom row still to issue
    reg                     is_ft, is_fb;                // fetch flags of the record (for the ready queue)
    reg  [SLOT_BITS-1:0]    is_st, is_sb;
    reg  [31:0]             is_at, is_ab;
    reg  [CNT_BITS-1:0]     is_words;
    reg  [WORD_BITS-1:0]    is_wbase;                    // s_col / 8 mod SLOT_WORDS

    reg  [NSLOT-1:0]        busy;
    reg  [BLK_BITS-1:0]     last_user [0:NSLOT-1];
    reg  [BLK_BITS-1:0]     blk_idx;                     // index of the record in IS
    reg  [BLK_BITS-1:0]     blocks_done;

    reg  [RQ_BITS:0]        rq_cnt;
    wire                    rq_room = (rq_cnt != RQ_DEPTH);

    wire [SLOT_BITS-1:0]    cur_slot = is_nt ? is_st : is_sb;
    wire                    rem_any  = is_nt || is_nb;
    assign cmd_valid = is_valid && rem_any && !busy[cur_slot] && rq_room;
    assign cmd_addr  = is_nt ? is_at : is_ab;
    assign cmd_words = is_words;
    assign cmd_slot  = cur_slot;
    wire   issue     = cmd_valid && cmd_ready;
    wire   is_finish = is_valid && rq_room && (!rem_any || (issue && !(is_nt && is_nb)));
    wire   ce        = !is_valid || is_finish;
    assign fetch_ready = ce;

    // ------------------------------------------------------------------ prep pipeline P1..P3
    reg                     p1_v, p2_v, p3_v;
    reg  [SIZE_BITS-1:0]    p1_row, p1_scol;
    reg  [SLOT_BITS-1:0]    p1_st, p1_sb, p2_st, p2_sb, p3_st, p3_sb;
    reg                     p1_ft, p1_fb, p2_ft, p2_fb, p3_ft, p3_fb;
    reg  [CNT_BITS-1:0]     p1_words, p2_words, p3_words;
    reg  [WORD_BITS-1:0]    p2_wb, p3_wb;
    reg  [2*SIZE_BITS-1:0]  p2_m;                        // row_top * W (DSP M register)
    reg  [31:0]             p2_off, p2_offw;
    reg  [31:0]             p3_at, p3_ab;

    always @(posedge aclk) begin
        if (ce) begin
            // P1
            p1_row   <= fetch_row_top;
            p1_scol  <= fetch_s_col;
            p1_st    <= fetch_slot_top;
            p1_sb    <= fetch_slot_bot;
            p1_ft    <= fetch_top;
            p1_fb    <= fetch_bot;
            p1_words <= fetch_words;
            // P2
            p2_m     <= p1_row * w_r;
            p2_off   <= src_r + {{(32-SIZE_BITS){1'b0}}, p1_scol};
            p2_offw  <= src_r + {{(32-SIZE_BITS){1'b0}}, p1_scol} + {{(31-SIZE_BITS){1'b0}}, step_r};
            p2_st    <= p1_st;  p2_sb <= p1_sb;  p2_ft <= p1_ft;  p2_fb <= p1_fb;
            p2_words <= p1_words;
            p2_wb    <= p1_scol[WORD_BITS+2:3];
            // P3
            p3_at    <= p2_off  + {{(32-2*SIZE_BITS){1'b0}}, p2_m};
            p3_ab    <= p2_offw + {{(32-2*SIZE_BITS){1'b0}}, p2_m};
            p3_st    <= p2_st;  p3_sb <= p2_sb;  p3_ft <= p2_ft;  p3_fb <= p2_fb;
            p3_words <= p2_words;
            p3_wb    <= p2_wb;
        end
    end

    always @(posedge aclk) begin
        if (!aresetn || frame_start) begin
            p1_v <= 1'b0; p2_v <= 1'b0; p3_v <= 1'b0;
        end else if (ce) begin
            p1_v <= fetch_valid;
            p2_v <= p1_v;
            p3_v <= p2_v;
        end
    end

    // ------------------------------------------------------------------ IS register
    always @(posedge aclk) begin
        if (!aresetn || frame_start) begin
            is_valid <= 1'b0; is_nt <= 1'b0; is_nb <= 1'b0;
        end else if (ce) begin
            is_valid <= p3_v;
            is_nt    <= p3_v && p3_ft;
            is_nb    <= p3_v && p3_fb;
        end else if (issue) begin
            if (is_nt) is_nt <= 1'b0;
            else       is_nb <= 1'b0;
        end
    end
    always @(posedge aclk) begin
        if (ce) begin
            is_ft <= p3_ft; is_fb <= p3_fb;
            is_st <= p3_st; is_sb <= p3_sb;
            is_at <= p3_at; is_ab <= p3_ab;
            is_words <= p3_words;
            is_wbase <= p3_wb;
        end
    end

    // ------------------------------------------------------------------ slots: busy, last_user, blocks_done
    integer s;
`ifdef PATRM_FAULT_SLOT_EARLY
    // deliberate fault (step 3.6b): a slot is freed when the block BEFORE its last user is read out
    wire [BLK_BITS-1:0] done_plus1 = blocks_done + 1'b1;
`endif
    always @(posedge aclk) begin
        if (!aresetn || frame_start) begin
            busy        <= {NSLOT{1'b0}};
            blk_idx     <= {BLK_BITS{1'b0}};
            blocks_done <= {BLK_BITS{1'b0}};
        end else begin
            if (blk_done) begin
                blocks_done <= blocks_done + 1'b1;
                for (s = 0; s < NSLOT; s = s + 1)
`ifdef PATRM_FAULT_SLOT_EARLY
                    if (last_user[s] == blocks_done || last_user[s] == done_plus1) busy[s] <= 1'b0;
`else
                    if (last_user[s] == blocks_done) busy[s] <= 1'b0;
`endif
            end
            if (is_finish) begin                          // after the clears: a new user wins
                busy[is_st] <= 1'b1;
                busy[is_sb] <= 1'b1;
                blk_idx     <= blk_idx + 1'b1;
            end
        end
    end
    always @(posedge aclk) begin
        if (is_finish) begin
            last_user[is_st] <= blk_idx;
            last_user[is_sb] <= blk_idx;
        end
    end

    // ------------------------------------------------------------------ commands in flight, stale beats
    reg  [7:0] cmd_out;                                   // accepted by axi_rd_master, last beat not yet seen
    reg  [7:0] drop;                                      // commands of an aborted frame still to come
    wire       raw_done = rd_valid && rd_cmd_last;
    wire       stale    = frame_start || (drop != 8'd0);
    wire [7:0] out_next = cmd_out + {7'd0, issue} - {7'd0, raw_done};
    always @(posedge aclk) begin
        if (!aresetn) begin
            cmd_out <= 8'd0;
            drop    <= 8'd0;
        end else begin
            cmd_out <= out_next;
            if (frame_start)              drop <= out_next;
            else if (raw_done && drop != 8'd0) drop <= drop - 1'b1;
        end
    end

    // ------------------------------------------------------------------ line_buf write (1 cycle after the beat)
    reg  [WORD_BITS-1:0] base [0:NSLOT-1];
    always @(posedge aclk) begin
        if (issue) base[cur_slot] <= is_wbase;
    end
    wire [WORD_BITS-1:0] pword = base[rd_slot] + rd_word;    // mod SLOT_WORDS
    reg                  w_last;
    always @(posedge aclk) begin
        if (!aresetn) begin
            buf_we <= 1'b0;
            w_last <= 1'b0;
        end else begin
            buf_we <= rd_valid && !stale;
            w_last <= raw_done && !stale;
        end
        buf_wbank <= pword[0];
        buf_waddr <= {rd_slot, pword[WORD_BITS-1:1]};
        buf_wdata <= rd_data;
    end

    // ------------------------------------------------------------------ ready queue -> blocks_ready
    reg  [1:0]          rq_mem [0:RQ_DEPTH-1];           // commands of the record (0, 1 or 2)
    reg  [RQ_BITS-1:0]  rq_wp, rq_rp;
    reg  [7:0]          cdone;                            // complete commands not yet assigned to a block
    wire [1:0]          rq_head = rq_mem[rq_rp];
    wire                rq_pop  = (rq_cnt != 0) && (cdone >= {6'd0, rq_head});
    always @(posedge aclk) begin
        if (is_finish) rq_mem[rq_wp] <= {1'b0, is_ft} + {1'b0, is_fb};
    end
    always @(posedge aclk) begin
        if (!aresetn || frame_start) begin
            rq_wp <= 0; rq_rp <= 0; rq_cnt <= 0;
            cdone <= 8'd0;
            blocks_ready <= {BLK_BITS{1'b0}};
        end else begin
            if (is_finish) rq_wp <= rq_wp + 1'b1;
            if (rq_pop)    rq_rp <= rq_rp + 1'b1;
            rq_cnt <= rq_cnt + {{RQ_BITS{1'b0}}, is_finish} - {{RQ_BITS{1'b0}}, rq_pop};
            cdone  <= cdone + {7'd0, w_last} - (rq_pop ? {6'd0, rq_head} : 8'd0);
            if (rq_pop) blocks_ready <= blocks_ready + 1'b1;
        end
    end

endmodule
