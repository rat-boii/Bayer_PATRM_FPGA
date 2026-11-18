// block_planner: block and fetch schedule of the grayscale engine (spec/interface.md section 3, step 3.6a; timing step 3.6c).
//
// Scans the output frame row by row, one pixel per clock, with its own add-only coordinates (X(0,0) = b13,
// Y(0,0) = b23, +(b12, b22) per output column, +(b11, b21) per output row, 32-bit wrapping, D4), cuts the
// blocks by D16 (a) x0 change, (b) BLOCK_LEN, (c) SPAN_MAX, decides the rows of every block, the row reuse of
// D14 (P1) and the buffer slots (ring rule), and writes one block descriptor per block (desc FIFO -> coord_gen)
// and one fetch record per block with valid pixels (fetch FIFO -> prefetch_ctrl). Hardware form of
// model/memmodel.py make_blocks + schedule (policy P1); output = data/vectors/sched_blocks_*.txt record for record.
//
// Pipeline (all stages advance together on ce = both FIFOs have room for one more record):
//   A  scan: (u, v) counters and the add-only X, Y; after the last pixel one "flush" token closes the last block
//   B  per pixel: D1 valid, x0, x0 == H-1, word columns wlo = y0 >> 3, whi = y1 >> 3 (y1 = min(y0 + 1, W - 1))
//      and the rule (c) bound of a block that would start with this pixel (step 3.6c)
//   C  rule decision (D16 a, b, c in this order) and block state; registers the block that the pixel closes
//   D1 rows, range and row compares against the previous fetching block, reuse decision (P1)   (step 3.6c)
//   D2 slots (ring), then both FIFO writes in the same cycle                                   (step 3.6c)
// A block is closed by the first pixel of the next block (or by the flush token), so at most one block closes
// per cycle and 1-pixel blocks still run at one descriptor per clock.
// Blocks without valid pixels (nrows = 0) drive 0 on the slot and s_col fields (the model writes -1 = none);
// coord_gen / pixel_fetch do not use them for such blocks.
//
// Column ranges are kept in 8-byte words: floor8(min y0) = 8 * wlo, ceil8(max y1 + 1) = 8 * (whi + 1), so the
// aligned span is 8 * (whi - wlo + 1) and rule (c) is (whi - wlo + 1) > SPAN_MAX / 8.
// Step 3.6c (timing, same block lists): a block never leaves its output row, and along a row Y steps by b22, so
// y0, y1, wlo and whi of the valid pixels are monotonic (no wrap: D4 keeps |Y| < 2^30). For b22 >= 0 the block's
// minimum is its FIRST valid pixel's wlo and the maximum the CURRENT pixel's whi; for b22 < 0 the reverse. So the
// min / max compares are gone and rule (c) is one compare with a bound fixed at the block's first valid pixel:
//   b22 >= 0: whi > wlo_first + SPAN_WORDS - 1        b22 < 0: wlo < whi_first - (SPAN_WORDS - 1)
// Rule (b) uses a flag blk_full = (blk_n == BLOCK_LEN) computed one pixel ahead.
// No multipliers (0 DSP48E1): the planner's coordinates are additions only; coord_gen recomputes each block start
// with its own multiply-add (fixed convention), so the coordinates exist twice by design (spec section 3).
//
// Test only: PATRM_FAULT_SPAN compares the span against SPAN_MAX + 8 (must fail tb_block_planner group c).
module block_planner #(
    parameter SIZE_BITS   = 13,                 // WIDTH / HEIGHT / row / column fields
    parameter CNT_BITS    = 7,                  // desc_n, fetch_words (1..64)
    parameter SLOT_BITS   = 5,                  // NSLOT = 2^SLOT_BITS = 32 line buffer slots
    parameter SPAN_MAX    = 512,                // D16 (c), bytes, multiple of 8, >= 16, <= 8 * (2^CNT_BITS - 1)
    parameter DESC_DEPTH  = 16,                 // descriptor FIFO depth (power of 2)
    parameter FETCH_DEPTH = 16                  // fetch FIFO depth (power of 2)
) (
    input  wire                  aclk,
    input  wire                  aresetn,
    input  wire                  frame_start,
    input  wire [SIZE_BITS-1:0]  cfg_width,
    input  wire [SIZE_BITS-1:0]  cfg_height,
    input  wire [SIZE_BITS-1:0]  cfg_block_len,
    input  wire [31:0]           cfg_b11, cfg_b12, cfg_b13, cfg_b21, cfg_b22, cfg_b23,
    // block descriptors (to coord_gen)
    output wire                  desc_valid,
    input  wire                  desc_ready,
    output wire [SIZE_BITS-1:0]  desc_u,
    output wire [SIZE_BITS-1:0]  desc_v0,
    output wire [CNT_BITS-1:0]   desc_n,
    output wire [1:0]            desc_nrows,
    output wire [SLOT_BITS-1:0]  desc_slot_top,
    output wire [SLOT_BITS-1:0]  desc_slot_bot,
    output wire [SIZE_BITS-1:0]  desc_s_col,
    output wire                  desc_last,
    // fetch records (to prefetch_ctrl), only blocks with nrows > 0
    output wire                  fetch_valid,
    input  wire                  fetch_ready,
    output wire [SIZE_BITS-1:0]  fetch_row_top,
    output wire [SIZE_BITS-1:0]  fetch_row_bot,
    output wire [SLOT_BITS-1:0]  fetch_slot_top,
    output wire [SLOT_BITS-1:0]  fetch_slot_bot,
    output wire                  fetch_top,
    output wire                  fetch_bot,
    output wire [SIZE_BITS-1:0]  fetch_s_col,
    output wire [CNT_BITS-1:0]   fetch_words
);

    localparam WB      = SIZE_BITS - 3;                    // word column index (column >> 3)
    localparam SPW_B   = WB + 1;                           // span in words, 1 .. 2^WB
`ifdef PATRM_FAULT_SPAN
    localparam SPAN_WORDS = SPAN_MAX / 8 + 1;              // FAULT: allows SPAN_MAX + 8 bytes
`else
    localparam SPAN_WORDS = SPAN_MAX / 8;
`endif
    localparam DA_B    = $clog2(DESC_DEPTH);
    localparam FA_B    = $clog2(FETCH_DEPTH);
    localparam DESC_W  = 3 * SIZE_BITS + CNT_BITS + 2 + 2 * SLOT_BITS + 1;
    localparam FETCH_W = 3 * SIZE_BITS + 2 * SLOT_BITS + 2 + CNT_BITS;

    // ------------------------------------------------------------------ FIFO state, ce
    reg  [DA_B:0]  d_cnt;
    reg  [FA_B:0]  f_cnt;
    wire           ce = (d_cnt != DESC_DEPTH) && (f_cnt != FETCH_DEPTH);

    // ------------------------------------------------------------------ configuration (latched at frame_start)
    reg  [31:0]          k_b12, k_b22, k_b11, k_b21;
    reg  [SIZE_BITS-1:0] k_wm1, k_hm1, k_len;
    reg  [31:0]          k_xmax, k_ymax;                   // (H-1) << 16, (W-1) << 16
    reg                  k_neg, k_len1;                    // b22 < 0; BLOCK_LEN == 1

    // ------------------------------------------------------------------ stage A: scan
    reg                  a_run, a_flush;
    reg  [SIZE_BITS-1:0] a_u, a_v;
    reg  [31:0]          a_X, a_Y, a_rX, a_rY;             // current pixel; start of the next output row
    wire                 a_row_end   = (a_v == k_wm1);
    wire                 a_frame_end = a_row_end && (a_u == k_hm1);

    reg                  b_tok, b_flush, b_rowstart;
    reg  [SIZE_BITS-1:0] b_u, b_v;
    reg  [31:0]          b_X, b_Y;

    always @(posedge aclk) begin
        if (!aresetn) begin
            a_run <= 1'b0; a_flush <= 1'b0; a_u <= 0; a_v <= 0;
            a_X <= 0; a_Y <= 0; a_rX <= 0; a_rY <= 0;
            b_tok <= 1'b0; b_flush <= 1'b0; b_rowstart <= 1'b0; b_u <= 0; b_v <= 0; b_X <= 0; b_Y <= 0;
            k_b11 <= 0; k_b12 <= 0; k_b21 <= 0; k_b22 <= 0; k_wm1 <= 0; k_hm1 <= 0; k_len <= 0;
            k_xmax <= 0; k_ymax <= 0; k_neg <= 1'b0; k_len1 <= 1'b0;
        end else if (frame_start) begin
            k_b11 <= cfg_b11; k_b12 <= cfg_b12; k_b21 <= cfg_b21; k_b22 <= cfg_b22;
            k_wm1 <= cfg_width - 1'b1;
            k_hm1 <= cfg_height - 1'b1;
            k_len <= cfg_block_len;
            k_neg <= cfg_b22[31];
            k_len1 <= (cfg_block_len[CNT_BITS-1:0] == 1);
            k_xmax <= {{(16 - SIZE_BITS){1'b0}}, cfg_height - 1'b1, 16'd0};
            k_ymax <= {{(16 - SIZE_BITS){1'b0}}, cfg_width - 1'b1, 16'd0};
            a_run <= 1'b1; a_flush <= 1'b0; a_u <= 0; a_v <= 0;
            a_X <= cfg_b13; a_Y <= cfg_b23;
            a_rX <= cfg_b13 + cfg_b11; a_rY <= cfg_b23 + cfg_b21;
            b_tok <= 1'b0; b_flush <= 1'b0;
        end else if (ce) begin
            b_tok <= a_run || a_flush;
            b_flush <= !a_run && a_flush;
            b_u <= a_u; b_v <= a_v; b_X <= a_X; b_Y <= a_Y;
            b_rowstart <= (a_v == 0);
            if (a_run) begin
                if (a_row_end) begin
                    a_v <= 0;
                    a_u <= a_u + 1'b1;
                    a_X <= a_rX; a_Y <= a_rY;                        // 32-bit wrapping adds (D4)
                    a_rX <= a_rX + k_b11; a_rY <= a_rY + k_b21;
                end else begin
                    a_v <= a_v + 1'b1;
                    a_X <= a_X + k_b12; a_Y <= a_Y + k_b22;
                end
                if (a_frame_end) begin
                    a_run <= 1'b0;
                    a_flush <= 1'b1;
                end
            end else begin
                a_flush <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------ stage B: D1 valid, x0, word columns
    wire                 bv_valid = !b_X[31] && (b_X <= k_xmax) && !b_Y[31] && (b_Y <= k_ymax);   // D1
    wire [SIZE_BITS-1:0] bv_x0 = b_X[16 + SIZE_BITS - 1:16];          // X >>> 16 (0 .. H-1 when valid)
    wire [SIZE_BITS-1:0] bv_y0 = b_Y[16 + SIZE_BITS - 1:16];
    wire [SIZE_BITS-1:0] bv_y1 = (bv_y0 == k_wm1) ? bv_y0 : bv_y0 + 1'b1;   // min(y0 + 1, W - 1)

    reg                  c_tok, c_flush, c_rowstart, c_pv, c_x0last;
    reg  [SIZE_BITS-1:0] c_u, c_v, c_x0;
    reg  [WB-1:0]        c_wlo, c_whi;
    reg  signed [WB+1:0] c_bnd;                            // rule (c) bound if a block starts at this pixel
    wire signed [WB+1:0] bv_bnd = k_neg ? $signed({2'b00, bv_y1[SIZE_BITS-1:3]}) - (SPAN_WORDS - 1)
                                        : $signed({2'b00, bv_y0[SIZE_BITS-1:3]}) + (SPAN_WORDS - 1);

    always @(posedge aclk) begin
        if (!aresetn || frame_start) begin
            c_tok <= 1'b0; c_flush <= 1'b0; c_rowstart <= 1'b0; c_pv <= 1'b0; c_x0last <= 1'b0;
            c_u <= 0; c_v <= 0; c_x0 <= 0; c_wlo <= 0; c_whi <= 0; c_bnd <= 0;
        end else if (ce) begin
            c_tok <= b_tok; c_flush <= b_flush; c_rowstart <= b_rowstart;
            c_u <= b_u; c_v <= b_v;
            c_pv <= bv_valid;
            c_x0 <= bv_x0;
            c_x0last <= (bv_x0 == k_hm1);
            c_wlo <= bv_y0[SIZE_BITS-1:3];
            c_whi <= bv_y1[SIZE_BITS-1:3];
            c_bnd <= bv_bnd;
        end
    end

    // ------------------------------------------------------------------ stage C: D16 rules, block state
    reg                  blk_open, blk_hasv, blk_x0last, blk_full;
    reg  [SIZE_BITS-1:0] blk_u, blk_v0, blk_x0;
    reg  [CNT_BITS-1:0]  blk_n, blk_nvalid;
    reg  [WB-1:0]        blk_wlo, blk_whi;
    reg  signed [WB+1:0] blk_bnd;                           // rule (c) bound of the block (its first valid pixel)
    reg                  row_hasv;                          // the output row already had a valid pixel
    reg  [SIZE_BITS-1:0] row_key;                           // x0 of the most recent valid pixel of the row

    wire rule_a = c_pv && row_hasv && (c_x0 != row_key);
    wire rule_b = blk_full;                                 // blk_n == BLOCK_LEN
    wire rule_c = c_pv && blk_hasv && (k_neg ? ($signed({2'b00, c_wlo}) < blk_bnd)
                                             : ($signed({2'b00, c_whi}) > blk_bnd));
    wire c_new  = c_rowstart || !blk_open || rule_a || rule_b || rule_c;      // pixel starts a new block
    wire [1:0] c_reason = c_rowstart ? 2'd0 : rule_a ? 2'd1 : rule_b ? 2'd2 : 2'd3;
    wire c_close = c_tok && blk_open && (c_flush || c_new);
    wire n_full  = (blk_n + 1'b1 == k_len[CNT_BITS-1:0]);   // blk_full if the block goes on

    // closed block (stage D1 input)
    reg                  j_v, j_hasv, j_x0last, j_last;
    reg  [SIZE_BITS-1:0] j_u, j_v0, j_x0;
    reg  [CNT_BITS-1:0]  j_n, j_nvalid;
    reg  [1:0]           j_reason;                          // 0 row end, 1 x0, 2 BLOCK_LEN, 3 SPAN_MAX
    reg  [WB-1:0]        j_wlo, j_whi;

    always @(posedge aclk) begin
        if (!aresetn || frame_start) begin
            blk_open <= 1'b0; blk_hasv <= 1'b0; blk_x0last <= 1'b0; blk_full <= 1'b0; blk_u <= 0; blk_v0 <= 0;
            blk_x0 <= 0; blk_n <= 0; blk_nvalid <= 0; blk_wlo <= 0; blk_whi <= 0; blk_bnd <= 0;
            row_hasv <= 1'b0; row_key <= 0;
            j_v <= 1'b0; j_hasv <= 1'b0; j_x0last <= 1'b0; j_last <= 1'b0; j_u <= 0; j_v0 <= 0; j_x0 <= 0;
            j_n <= 0; j_nvalid <= 0; j_reason <= 0; j_wlo <= 0; j_whi <= 0;
        end else if (ce) begin
            j_v <= c_close;
            if (c_close) begin
                j_hasv <= blk_hasv; j_x0last <= blk_x0last; j_u <= blk_u; j_v0 <= blk_v0; j_x0 <= blk_x0;
                j_n <= blk_n; j_nvalid <= blk_nvalid; j_wlo <= blk_wlo; j_whi <= blk_whi;
                j_last <= c_flush;
                j_reason <= c_flush ? 2'd0 : c_reason;
            end
            if (c_tok) begin
                if (c_flush) begin
                    blk_open <= 1'b0;
                end else begin
                    // row state (rule a looks at the state before this pixel)
                    if (c_rowstart) begin
                        row_hasv <= c_pv;
                        row_key  <= c_x0;
                    end else if (c_pv) begin
                        row_hasv <= 1'b1;
                        row_key  <= c_x0;
                    end
                    if (c_new) begin
                        blk_open <= 1'b1; blk_u <= c_u; blk_v0 <= c_v; blk_n <= 1; blk_full <= k_len1;
                        blk_hasv <= c_pv; blk_nvalid <= c_pv ? 1 : 0;
                        blk_x0 <= c_x0; blk_x0last <= c_x0last; blk_wlo <= c_wlo; blk_whi <= c_whi;
                        blk_bnd <= c_bnd;
                    end else begin
                        blk_n <= blk_n + 1'b1;
                        blk_full <= n_full;
                        if (c_pv) begin
                            blk_nvalid <= blk_nvalid + 1'b1;
                            blk_hasv <= 1'b1;
                            if (blk_hasv) begin                   // x0 unchanged (rule a); monotonic columns
                                if (k_neg) blk_wlo <= c_wlo;      // new minimum
                                else       blk_whi <= c_whi;      // new maximum
                            end else begin
                                blk_x0 <= c_x0; blk_x0last <= c_x0last; blk_wlo <= c_wlo; blk_whi <= c_whi;
                                blk_bnd <= c_bnd;
                            end
                        end
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------ stage D1: rows, reuse (D14 P1)
    reg                  pv_has, pv_two;                    // previous block WITH valid pixels (rows, range)
    reg  [SIZE_BITS-1:0] pv_top, pv_bot;                    // pv_bot = pv_top + 1
    reg  [WB-1:0]        pv_wlo, pv_whi;

    wire                 j_two    = !j_x0last;               // rows x0 and x0 + 1 (else only x0 = H-1)
    wire [SIZE_BITS-1:0] j_bot    = j_two ? j_x0 + 1'b1 : j_x0;
    wire                 range_ok = pv_has && (pv_wlo <= j_wlo) && (pv_whi >= j_whi);
    wire                 t_in0    = (j_x0 == pv_top);
    wire                 t_in1    = pv_two && (j_x0 == pv_bot);
    wire                 b_in0    = (j_bot == pv_top);
    wire                 b_in1    = pv_two && (j_bot == pv_bot);

    // stage D2 input
    reg                  d_v, d_hasv, d_two, d_last, d_rt, d_rb, d_t0, d_b0;
    reg  [SIZE_BITS-1:0] d_u, d_v0, d_x0, d_bot;
    reg  [CNT_BITS-1:0]  d_n, d_nvalid;
    reg  [1:0]           d_reason;
    reg  [WB-1:0]        d_wlo, d_whi;

    always @(posedge aclk) begin
        if (!aresetn || frame_start) begin
            pv_has <= 1'b0; pv_two <= 1'b0; pv_top <= 0; pv_bot <= 0; pv_wlo <= 0; pv_whi <= 0;
            d_v <= 1'b0; d_hasv <= 1'b0; d_two <= 1'b0; d_last <= 1'b0; d_rt <= 1'b0; d_rb <= 1'b0;
            d_t0 <= 1'b0; d_b0 <= 1'b0; d_u <= 0; d_v0 <= 0; d_x0 <= 0; d_bot <= 0; d_n <= 0; d_nvalid <= 0;
            d_reason <= 0; d_wlo <= 0; d_whi <= 0;
        end else if (ce) begin
            d_v <= j_v;
            if (j_v) begin
                d_hasv <= j_hasv; d_two <= j_two; d_last <= j_last; d_u <= j_u; d_v0 <= j_v0; d_x0 <= j_x0;
                d_bot <= j_bot; d_n <= j_n; d_nvalid <= j_nvalid; d_reason <= j_reason; d_wlo <= j_wlo;
                d_whi <= j_whi;
                d_rt <= range_ok && (t_in0 || t_in1);
                d_rb <= j_two && range_ok && (b_in0 || b_in1);
                d_t0 <= t_in0;
                d_b0 <= b_in0;
                if (j_hasv) begin                               // this block is the next one's "previous"
                    pv_has <= 1'b1; pv_two <= j_two; pv_top <= j_x0; pv_bot <= j_x0 + 1'b1;
                    pv_wlo <= j_wlo; pv_whi <= j_whi;
                end
            end
        end
    end

    // ------------------------------------------------------------------ stage D2: slots (ring), FIFO writes
    reg  [SLOT_BITS-1:0] pv_st, pv_sb, ptr;                 // slots of the previous fetching block; ring pointer

    wire [SLOT_BITS-1:0] rs_t   = d_t0 ? pv_st : pv_sb;
    wire [SLOT_BITS-1:0] rs_b   = d_b0 ? pv_st : pv_sb;
    // ring: a fetched row takes the pointer slot, skipping a slot this block already uses; pointer + 1 each
    wire [SLOT_BITS-1:0] p_t    = (d_rb && ptr == rs_b) ? ptr + 1'b1 : ptr;
    wire [SLOT_BITS-1:0] s_top  = d_rt ? rs_t : p_t;
    wire [SLOT_BITS-1:0] ptr1   = d_rt ? ptr : p_t + 1'b1;
    wire [SLOT_BITS-1:0] p_b    = (ptr1 == s_top) ? ptr1 + 1'b1 : ptr1;
    wire [SLOT_BITS-1:0] s_bot  = !d_two ? s_top : d_rb ? rs_b : p_b;
    wire [SLOT_BITS-1:0] ptr2   = (d_two && !d_rb) ? p_b + 1'b1 : ptr1;
    wire [CNT_BITS-1:0]  r_words = d_whi - d_wlo + 1'b1;
    wire [SIZE_BITS-1:0] r_scol = {d_wlo, 3'b000};

    wire d_push = ce && d_v && !frame_start;                 // descriptor FIFO write (none from an aborted frame)
    wire f_push = d_push && d_hasv;                          // fetch FIFO write (same cycle)

    always @(posedge aclk) begin
        if (!aresetn || frame_start) begin
            pv_st <= 0; pv_sb <= 0; ptr <= 0;
        end else if (f_push) begin
            pv_st <= s_top; pv_sb <= s_bot;
            ptr <= ptr2;
        end
    end

    wire [DESC_W-1:0] d_din = {d_u, d_v0, d_n,
                               d_hasv ? (d_two ? 2'd2 : 2'd1) : 2'd0,
                               d_hasv ? s_top : {SLOT_BITS{1'b0}},
                               d_hasv ? s_bot : {SLOT_BITS{1'b0}},
                               d_hasv ? r_scol : {SIZE_BITS{1'b0}},
                               d_last};
    wire [FETCH_W-1:0] f_din = {d_x0, d_bot, s_top, s_bot, !d_rt, d_two && !d_rb, r_scol, r_words};

    // ------------------------------------------------------------------ FIFOs (distributed RAM)
    reg  [DESC_W-1:0]  d_mem [0:DESC_DEPTH-1];
    reg  [FETCH_W-1:0] f_mem [0:FETCH_DEPTH-1];
    reg  [DA_B-1:0]    d_wp, d_rp;
    reg  [FA_B-1:0]    f_wp, f_rp;
    wire               d_pop = desc_valid && desc_ready;
    wire               f_pop = fetch_valid && fetch_ready;

    always @(posedge aclk) begin
        if (d_push) d_mem[d_wp] <= d_din;
        if (f_push) f_mem[f_wp] <= f_din;
    end

    always @(posedge aclk) begin
        if (!aresetn || frame_start) begin
            d_wp <= 0; d_rp <= 0; d_cnt <= 0;
            f_wp <= 0; f_rp <= 0; f_cnt <= 0;
        end else begin
            if (d_push) d_wp <= d_wp + 1'b1;
            if (d_pop)  d_rp <= d_rp + 1'b1;
            d_cnt <= d_cnt + d_push - d_pop;
            if (f_push) f_wp <= f_wp + 1'b1;
            if (f_pop)  f_rp <= f_rp + 1'b1;
            f_cnt <= f_cnt + f_push - f_pop;
        end
    end

    assign desc_valid = (d_cnt != 0);
    assign fetch_valid = (f_cnt != 0);
    assign {desc_u, desc_v0, desc_n, desc_nrows, desc_slot_top, desc_slot_bot, desc_s_col, desc_last} = d_mem[d_rp];
    assign {fetch_row_top, fetch_row_bot, fetch_slot_top, fetch_slot_bot, fetch_top, fetch_bot, fetch_s_col,
            fetch_words} = f_mem[f_rp];

endmodule
