// coord_gen: source coordinate (X, Y) of every output pixel, in the order of the block descriptors (step 3.2).
//
// Spec: spec/interface.md section 4 (and section 0 for the handshake / frame_start rules).
// - Block start by a 3-stage multiply-add pipeline, all mod 2^32 (D4):
//     X0 = b11*u + b12*v0 + b13,  Y0 = b21*u + b22*v0 + b23        (u = desc_u, v0 = desc_v0)
//   S1  eight partial products. Each b*k (b 32 bit signed, k 13 bit unsigned) is split as b = bh*2^16 + bl with
//       bl = b[15:0] (unsigned, 17-bit non-negative operand) and bh = b[31:16] (signed): bl*k and bh*k, one
//       DSP48E1 each, registered once inside the DSP48E1.
//   S2  the four products mod 2^32: p = bl*k + ((bh*k) << 16). Only the low 16 bits of bh*k are kept; this drop
//       of the upper bits is the mod 2^32 wrap, not a rounding.
//   S3  X0 = p11 + p12 + b13, Y0 = p21 + p22 + b23 (3-input 32-bit adds), written into the 4-entry start FIFO.
// - Inside a block: add only, +(b12, b22) per pixel (32-bit wrapping adds).
// - Descriptors are popped whenever fewer than START_DEPTH block starts are outstanding (in S1..S3 or in the
//   start FIFO), independent of the stepping of the current block, so S1..S3 never stall and a new block can
//   start every cycle (1 pixel per clock also for 1-pixel blocks).
// - Latency: first pixel 4 cycles after its descriptor is taken (S1, S2, S3, stepper register).
// - Output: valid/ready with the ce rule (ce = !(pix_valid && !pix_ready)); pix_valid and the pixel hold while
//   pix_ready = 0. No combinational path from pix_ready to pix_valid or to desc_ready.
// - frame_start (one-cycle pulse): latches b11..b23 and clears all frame state; nothing is transferred in that
//   cycle (desc_ready = 0). Data registers and the FIFO memories have no reset (valid bits and pointers do).
// - This module does not decide blocks (block_planner, section 3) and does not compute the D1 valid bit or the
//   integer/fraction split (pixel_fetch stage F1, section 7): x0 = X >>> 16, xf = X[15:0], likewise for Y.
// - desc_n must be 1..2^CNT_BITS-1 (the planner sends 1..BLOCK_LEN_MAX); 0 is not allowed.
//
// The descriptor side fields (n, nrows, slots, s_col, last) do not go through S1..S3: they wait in their own
// 4-entry FIFO, written when the descriptor is taken, read together with the block start (same order).
`timescale 1ns/1ps
module coord_gen #(
    parameter SIZE_BITS = 13,                            // u, v0, s_col (spec section 0)
    parameter CNT_BITS  = 7,                             // desc_n: 1..BLOCK_LEN_MAX (64)
    parameter SLOT_BITS = 5                              // line buffer slot index (NSLOT = 32)
) (
    input  wire                     aclk,
    input  wire                     aresetn,
    input  wire                     frame_start,

    input  wire signed [31:0]       cfg_b11,             // Q15.16 inverse mapping
    input  wire signed [31:0]       cfg_b12,
    input  wire signed [31:0]       cfg_b13,
    input  wire signed [31:0]       cfg_b21,
    input  wire signed [31:0]       cfg_b22,
    input  wire signed [31:0]       cfg_b23,

    input  wire                     desc_valid,          // block descriptor from block_planner (DESC FIFO)
    output wire                     desc_ready,
    input  wire [SIZE_BITS-1:0]     desc_u,              // output row of the block
    input  wire [SIZE_BITS-1:0]     desc_v0,             // first output column of the block
    input  wire [CNT_BITS-1:0]      desc_n,              // pixels in the block
    input  wire [1:0]               desc_nrows,
    input  wire [SLOT_BITS-1:0]     desc_slot_top,
    input  wire [SLOT_BITS-1:0]     desc_slot_bot,
    input  wire [SIZE_BITS-1:0]     desc_s_col,
    input  wire                     desc_last,           // last block of the frame

    output wire                     pix_valid,           // pixel stream to pixel_fetch
    input  wire                     pix_ready,
    output wire signed [31:0]       pix_X,               // Q15.16 source row
    output wire signed [31:0]       pix_Y,               // Q15.16 source column
    output wire                     pix_first,           // first pixel of its block
    output wire                     pix_last,            // last pixel of its block
    output wire [1:0]               pix_nrows,
    output wire [SLOT_BITS-1:0]     pix_slot_top,
    output wire [SLOT_BITS-1:0]     pix_slot_bot,
    output wire [SIZE_BITS-1:0]     pix_s_col,
    output wire                     pix_frame_last       // last pixel of the frame
);

    localparam START_AW    = 2;                          // start FIFO: 4 entries (spec section 4)
    localparam START_DEPTH = 1 << START_AW;
    localparam FRAC_BITS   = 16;                         // Q15.16; also the split point of b for the DSPs
    localparam BH_W        = 32 - FRAC_BITS;             // bh = b[31:16], signed
    localparam BL_W        = FRAC_BITS + 1;              // {0, b[15:0]}: non-negative signed operand
    localparam K_W         = SIZE_BITS + 1;              // {0, k}: non-negative signed operand
    localparam ML_W        = BL_W + K_W;                 // bl*k (value < 2^(16+SIZE_BITS))
    localparam MH_W        = BH_W + K_W;                 // bh*k (only bits [15:0] reach the result)
    localparam SIDE_W      = 1 + SIZE_BITS + 2*SLOT_BITS + 2 + CNT_BITS;

    // ---------------- configuration, latched at frame_start ----------------
    reg signed [31:0] b11, b12, b13, b21, b22, b23;
    always @(posedge aclk) begin
        if (frame_start) begin
            b11 <= cfg_b11;  b12 <= cfg_b12;  b13 <= cfg_b13;
            b21 <= cfg_b21;  b22 <= cfg_b22;  b23 <= cfg_b23;
        end
    end

    // ---------------- descriptor pop: at most START_DEPTH block starts outstanding ----------------
    reg  [START_AW:0] side_wptr;                         // descriptors taken
    reg  [START_AW:0] start_wptr;                        // block starts written by S3
    reg  [START_AW:0] rptr;                              // block starts taken by the stepper
    wire [START_AW:0] outstanding = side_wptr - rptr;    // 0..START_DEPTH
    assign desc_ready = (outstanding != START_DEPTH) && !frame_start;
    wire   pop        = desc_valid && desc_ready;

    // ---------------- S1: partial products (DSP48E1 M registers) ----------------
    wire signed [K_W-1:0]  k_u   = {1'b0, desc_u};
    wire signed [K_W-1:0]  k_v   = {1'b0, desc_v0};
    wire signed [BL_W-1:0] b11_l = {1'b0, b11[FRAC_BITS-1:0]};
    wire signed [BL_W-1:0] b12_l = {1'b0, b12[FRAC_BITS-1:0]};
    wire signed [BL_W-1:0] b21_l = {1'b0, b21[FRAC_BITS-1:0]};
    wire signed [BL_W-1:0] b22_l = {1'b0, b22[FRAC_BITS-1:0]};
    wire signed [BH_W-1:0] b11_h = b11[31:FRAC_BITS];
    wire signed [BH_W-1:0] b12_h = b12[31:FRAC_BITS];
    wire signed [BH_W-1:0] b21_h = b21[31:FRAC_BITS];
    wire signed [BH_W-1:0] b22_h = b22[31:FRAC_BITS];

    wire signed [MH_W-1:0] f11_h = b11_h * k_u;          // full products of the high parts
    wire signed [MH_W-1:0] f12_h = b12_h * k_v;
    wire signed [MH_W-1:0] f21_h = b21_h * k_u;
    wire signed [MH_W-1:0] f22_h = b22_h * k_v;

    reg signed [ML_W-1:0]  m11_l, m12_l, m21_l, m22_l;   // bl*k, complete (non-negative)
    reg [FRAC_BITS-1:0]    m11_h, m12_h, m21_h, m22_h;   // (bh*k) mod 2^16: the upper bits wrap away (D4)
    reg                    s1_valid;
    always @(posedge aclk) begin
        m11_l <= b11_l * k_u;   m11_h <= f11_h[FRAC_BITS-1:0];
        m12_l <= b12_l * k_v;   m12_h <= f12_h[FRAC_BITS-1:0];
        m21_l <= b21_l * k_u;   m21_h <= f21_h[FRAC_BITS-1:0];
        m22_l <= b22_l * k_v;   m22_h <= f22_h[FRAC_BITS-1:0];
    end

    // ---------------- S2: products mod 2^32 ----------------
    // p = bl*k + ((bh*k) << 16), low 32 bits. bl*k is non-negative and below 2^(16+SIZE_BITS), so its low 32
    // bits are the whole value.
    function [31:0] prod32;
        input signed [ML_W-1:0] ml;
        input [FRAC_BITS-1:0]   mh;
        reg [31:0] lo;
        begin
            lo     = ml[ML_W-1:0];                       // zero-extended: ml >= 0
            prod32 = lo + {mh, {FRAC_BITS{1'b0}}};
        end
    endfunction

    reg [31:0] p11, p12, p21, p22;
    reg        s2_valid;
    always @(posedge aclk) begin
        p11 <= prod32(m11_l, m11_h);
        p12 <= prod32(m12_l, m12_h);
        p21 <= prod32(m21_l, m21_h);
        p22 <= prod32(m22_l, m22_h);
    end

    // ---------------- S3: block start, written into the start FIFO ----------------
    wire [31:0] x0_s3 = p11 + p12 + b13;                 // 32-bit wrapping adds (D4)
    wire [31:0] y0_s3 = p21 + p22 + b23;

    (* ram_style = "distributed" *) reg [63:0]       start_mem [0:START_DEPTH-1];   // {Y0, X0}
    (* ram_style = "distributed" *) reg [SIDE_W-1:0] side_mem  [0:START_DEPTH-1];
    always @(posedge aclk) begin
        if (s2_valid) start_mem[start_wptr[START_AW-1:0]] <= {y0_s3, x0_s3};
        if (pop)      side_mem[side_wptr[START_AW-1:0]]   <= {desc_last, desc_s_col, desc_slot_bot, desc_slot_top,
                                                              desc_nrows, desc_n};
    end

    wire [63:0]          start_q     = start_mem[rptr[START_AW-1:0]];
    wire [SIDE_W-1:0]    side_q      = side_mem[rptr[START_AW-1:0]];
    wire                 start_avail = (start_wptr != rptr);
    wire [CNT_BITS-1:0]  q_n         = side_q[CNT_BITS-1:0];
    wire [1:0]           q_nrows     = side_q[CNT_BITS +: 2];
    wire [SLOT_BITS-1:0] q_slot_top  = side_q[CNT_BITS+2 +: SLOT_BITS];
    wire [SLOT_BITS-1:0] q_slot_bot  = side_q[CNT_BITS+2+SLOT_BITS +: SLOT_BITS];
    wire [SIZE_BITS-1:0] q_s_col     = side_q[CNT_BITS+2+2*SLOT_BITS +: SIZE_BITS];
    wire                 q_last      = side_q[SIDE_W-1];

    // ---------------- stepper: one pixel per transfer ----------------
    reg                  v_r;                            // pix_valid
    reg [31:0]           x_r, y_r;
    reg [CNT_BITS-1:0]   rem_r;                          // pixels of the block after the current one
    reg                  first_r, last_r, blk_last_r;
    reg [1:0]            nrows_r;
    reg [SLOT_BITS-1:0]  slot_top_r, slot_bot_r;
    reg [SIZE_BITS-1:0]  s_col_r;

    wire ce   = !(v_r && !pix_ready);                    // section 0 ce rule
    wire load = ce && (!v_r || last_r) && start_avail;   // take the next block start
    wire step = ce && v_r && !last_r;                    // next pixel of the current block

`ifdef PATRM_FAULT_COL_STEP                              // fault injection for the testbench only
    wire [31:0] x_step = x_r + b12 + 32'd1;
`else
    wire [31:0] x_step = x_r + b12;                      // 32-bit wrapping adds (D4)
`endif
    wire [31:0] y_step = y_r + b22;

    always @(posedge aclk) begin
        if (load) begin
            x_r        <= start_q[31:0];
            y_r        <= start_q[63:32];
            rem_r      <= q_n - 1'b1;
            first_r    <= 1'b1;
            last_r     <= (q_n == 1);
            blk_last_r <= q_last;
            nrows_r    <= q_nrows;
            slot_top_r <= q_slot_top;
            slot_bot_r <= q_slot_bot;
            s_col_r    <= q_s_col;
        end else if (step) begin
            x_r        <= x_step;
            y_r        <= y_step;
            rem_r      <= rem_r - 1'b1;
            first_r    <= 1'b0;
            last_r     <= (rem_r == 1);
        end
    end

    // ---------------- valid bits and pointers (the only registers with reset / frame clear) ----------------
    always @(posedge aclk) begin
        if (!aresetn || frame_start) begin
            side_wptr  <= {(START_AW+1){1'b0}};
            start_wptr <= {(START_AW+1){1'b0}};
            rptr       <= {(START_AW+1){1'b0}};
            s1_valid   <= 1'b0;
            s2_valid   <= 1'b0;
            v_r        <= 1'b0;
        end else begin
            s1_valid <= pop;
            s2_valid <= s1_valid;
            if (pop)      side_wptr  <= side_wptr + 1'b1;
            if (s2_valid) start_wptr <= start_wptr + 1'b1;
            if (load)     rptr       <= rptr + 1'b1;
            if (ce)       v_r        <= load || step;
        end
    end

    assign pix_valid      = v_r;
    assign pix_X          = x_r;
    assign pix_Y          = y_r;
    assign pix_first      = first_r;
    assign pix_last       = last_r;
    assign pix_nrows      = nrows_r;
    assign pix_slot_top   = slot_top_r;
    assign pix_slot_bot   = slot_bot_r;
    assign pix_s_col      = s_col_r;
    assign pix_frame_last = last_r && blk_last_r;

endmodule
