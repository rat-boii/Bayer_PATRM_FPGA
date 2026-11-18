// pixel_fetch: D1 validity, integer / fraction split, block-ready wait, four neighbours from line_buf
// (spec/interface.md section 7), step 3.6b.
//
// Pipeline (ce rule, spec section 0: ce = !(ip_valid && !ip_ready), F2 / F3 advance on ce):
//   F1  register holding the pixel from coord_gen. Combinational: D1 valid (signed compares against (H-1) << 16
//       and (W-1) << 16 latched at frame_start), x0 = X >>> 16, y0 = Y >>> 16, xf = X[15:0], yf = Y[15:0],
//       y1 = min(y0 + 1, W - 1), slot words w0 = (y0 >> 3) mod 64 and w1 = (y1 >> 3) mod 64 (words are stored by
//       source column, spec 6.2 option A), bank entries even = ((w0 + 1) mod 64) >> 1, odd = w0 >> 1, and the
//       block-ready check. A pixel of fetching block k (k = fetching blocks whose last pixel already left F1) leaves
//       F1 only when k < blocks_ready (16-bit modulo compare); pixels of blocks without valid pixels (nrows = 0)
//       never wait. When F1 waits, F2 gets a bubble.
//   F2  line_buf read (the RAM output registers; read only for D1-valid pixels, invalid pixels skip the read).
//   F3  byte muxes -> r1..r4 registered (r1 = byte y0 mod 8 of word w0 of row x0 = slot_top, r2 = byte y1 mod 8 of
//       word w1, r3 / r4 the same in row x1 = slot_bot; slot_bot = slot_top at the bottom edge, nrows = 1).
//       Invalid pixels give r1..r4 = 0.
// blk_done: registered pulse one cycle after the last pixel of a fetching block moved F1 -> F2 (its last read is
// done at that edge; later writes to its slots cannot change the RAM output registers).
// rd_stall (spec 13, decided 2026-11-18): F1 holds a pixel whose block is not ready AND ip_ready = 1
// (ip_ready = 0 exactly when bilinear_interp has WR_STALL, so RD_STALL and WR_STALL never count the same cycle).
// x0 / y0 are carried to F3 for the testbench only (no port; removed by synthesis).
module pixel_fetch #(
    parameter SIZE_BITS = 13,
    parameter SLOT_BITS = 5,
    parameter WORD_BITS = 6,                              // SLOT_WORDS = 64
    parameter BLK_BITS  = 16
) (
    input  wire                     aclk,
    input  wire                     aresetn,
    input  wire                     frame_start,
    input  wire [SIZE_BITS-1:0]     cfg_width,
    input  wire [SIZE_BITS-1:0]     cfg_height,
    // pixels (coord_gen)
    input  wire                     pix_valid,
    output wire                     pix_ready,
    input  wire signed [31:0]       pix_X,
    input  wire signed [31:0]       pix_Y,
    input  wire                     pix_first,           // not used
    input  wire                     pix_last,             // last pixel of its block
    input  wire [1:0]               pix_nrows,
    input  wire [SLOT_BITS-1:0]     pix_slot_top,
    input  wire [SLOT_BITS-1:0]     pix_slot_bot,
    input  wire [SIZE_BITS-1:0]     pix_s_col,            // not used (option A: words by source column)
    input  wire                     pix_frame_last,
    // block counters
    input  wire [BLK_BITS-1:0]      blocks_ready,
    output reg                      blk_done,
    // line_buf read
    output wire                     buf_re,
    output wire [SLOT_BITS+WORD_BITS-2:0] buf_raddr_te,
    output wire [SLOT_BITS+WORD_BITS-2:0] buf_raddr_to,
    output wire [SLOT_BITS+WORD_BITS-2:0] buf_raddr_be,
    output wire [SLOT_BITS+WORD_BITS-2:0] buf_raddr_bo,
    input  wire [63:0]              buf_rdata_te,
    input  wire [63:0]              buf_rdata_to,
    input  wire [63:0]              buf_rdata_be,
    input  wire [63:0]              buf_rdata_bo,
    // to bilinear_interp
    output reg                      ip_valid,
    input  wire                     ip_ready,
    output reg  [15:0]              ip_xf,
    output reg  [15:0]              ip_yf,
    output reg  [7:0]               ip_r1,
    output reg  [7:0]               ip_r2,
    output reg  [7:0]               ip_r3,
    output reg  [7:0]               ip_r4,
    output reg                      ip_ok,
    output reg                      ip_last,
    output wire                     rd_stall
);

    // ------------------------------------------------------------------ frame configuration
    reg signed [31:0]   hmax, wmax;                       // (H-1) << 16, (W-1) << 16
    reg [SIZE_BITS-1:0] wm1;                              // W - 1
    always @(posedge aclk) begin
        if (frame_start) begin
            hmax <= {{(16-SIZE_BITS){1'b0}}, cfg_height - 1'b1, 16'd0};
            wmax <= {{(16-SIZE_BITS){1'b0}}, cfg_width  - 1'b1, 16'd0};
            wm1  <= cfg_width - 1'b1;
        end
    end

    // ------------------------------------------------------------------ F1
    reg                     f1_v, f1_last, f1_flast;
    reg  signed [31:0]      f1_X, f1_Y;
    reg  [1:0]              f1_nrows;
    reg  [SLOT_BITS-1:0]    f1_st, f1_sb;
    reg  [BLK_BITS-1:0]     k;                            // fetching block of the pixel in F1

    wire                    ce      = !(ip_valid && !ip_ready);
    wire                    ok      = !f1_X[31] && (f1_X <= hmax) && !f1_Y[31] && (f1_Y <= wmax);
    wire [BLK_BITS-1:0]     kdiff   = k - blocks_ready;
    wire                    waitblk = (f1_nrows != 2'd0) && !kdiff[BLK_BITS-1];   // k >= blocks_ready
    wire                    go      = f1_v && !waitblk;
    wire                    adv     = ce && go;           // F1 -> F2
    assign pix_ready = !f1_v || adv;
    assign rd_stall  = f1_v && waitblk && ip_ready;

    always @(posedge aclk) begin
        if (!aresetn || frame_start) begin
            f1_v <= 1'b0;
        end else if (pix_valid && pix_ready) begin
            f1_v <= 1'b1;
        end else if (adv) begin
            f1_v <= 1'b0;
        end
    end
    always @(posedge aclk) begin
        if (pix_valid && pix_ready) begin
            f1_X <= pix_X;  f1_Y <= pix_Y;
            f1_last <= pix_last;  f1_flast <= pix_frame_last;
            f1_nrows <= pix_nrows;
            f1_st <= pix_slot_top;  f1_sb <= pix_slot_bot;
        end
    end

    wire fetch_end = adv && f1_last && (f1_nrows != 2'd0);
    always @(posedge aclk) begin
        if (!aresetn || frame_start) begin
            k <= {BLK_BITS{1'b0}};
            blk_done <= 1'b0;
        end else begin
            if (fetch_end) k <= k + 1'b1;
            blk_done <= fetch_end;
        end
    end

    // columns and slot words
    wire [2:0]              yb0   = f1_Y[18:16];          // y0 mod 8
    wire [WORD_BITS-1:0]    w0    = f1_Y[WORD_BITS+18:19];  // (y0 >> 3) mod 64
`ifdef PATRM_FAULT_CLAMP
    wire                    clamp = 1'b0;                 // deliberate fault (step 3.6b): no clamp of y1 at W-1
`else
    wire                    clamp = (f1_Y[SIZE_BITS+15:16] == wm1);   // y0 = W-1 (valid pixels: y0 <= W-1)
`endif
    wire                    nextw = !clamp && (yb0 == 3'd7);          // y1 in word w0 + 1
    wire [2:0]              yb1   = clamp ? yb0 : yb0 + 1'b1;         // y1 mod 8
    wire [WORD_BITS-1:0]    w0p1  = w0 + 1'b1;                        // mod 64, stays inside the slot
    wire [WORD_BITS-2:0]    ee    = w0p1[WORD_BITS-1:1];              // even bank entry
    wire [WORD_BITS-2:0]    eo    = w0[WORD_BITS-1:1];                // odd bank entry
    assign buf_raddr_te = {f1_st, ee};
    assign buf_raddr_to = {f1_st, eo};
    assign buf_raddr_be = {f1_sb, ee};
    assign buf_raddr_bo = {f1_sb, eo};
    assign buf_re       = adv && ok;

    // ------------------------------------------------------------------ F2 (RAM output registers valid)
    reg                 f2_v, f2_ok, f2_last, f2_b0, f2_b1;
    reg  [2:0]          f2_yb0, f2_yb1;
    reg  [15:0]         f2_xf, f2_yf;
    reg  signed [15:0]  f2_x0, f2_y0;
    always @(posedge aclk) begin
        if (!aresetn || frame_start) f2_v <= 1'b0;
        else if (ce)                 f2_v <= go;
    end
    always @(posedge aclk) begin
        if (ce) begin
            f2_ok   <= ok;
            f2_last <= f1_flast;
            f2_xf   <= f1_X[15:0];
            f2_yf   <= f1_Y[15:0];
            f2_x0   <= f1_X[31:16];
            f2_y0   <= f1_Y[31:16];
            f2_yb0  <= yb0;
            f2_yb1  <= yb1;
            f2_b0   <= w0[0];                             // bank of word w0
            f2_b1   <= w0[0] ^ nextw;                     // bank of word w1
        end
    end

    // byte muxes
    wire [63:0] t0 = f2_b0 ? buf_rdata_to : buf_rdata_te;     // row x0, word w0
    wire [63:0] t1 = f2_b1 ? buf_rdata_to : buf_rdata_te;     // row x0, word w1
    wire [63:0] b0 = f2_b0 ? buf_rdata_bo : buf_rdata_be;     // row x1, word w0
    wire [63:0] b1 = f2_b1 ? buf_rdata_bo : buf_rdata_be;     // row x1, word w1
    wire [7:0]  m1 = t0[8*f2_yb0 +: 8];
    wire [7:0]  m2 = t1[8*f2_yb1 +: 8];
    wire [7:0]  m3 = b0[8*f2_yb0 +: 8];
    wire [7:0]  m4 = b1[8*f2_yb1 +: 8];

    // ------------------------------------------------------------------ F3 (outputs)
    reg signed [15:0] f3_x0, f3_y0;                       // testbench only
    always @(posedge aclk) begin
        if (!aresetn || frame_start) ip_valid <= 1'b0;
        else if (ce)                 ip_valid <= f2_v;
    end
    always @(posedge aclk) begin
        if (ce) begin
            ip_xf   <= f2_xf;
            ip_yf   <= f2_yf;
            ip_ok   <= f2_ok;
            ip_last <= f2_last;
            ip_r1   <= f2_ok ? m1 : 8'd0;
            ip_r2   <= f2_ok ? m2 : 8'd0;
            ip_r3   <= f2_ok ? m3 : 8'd0;
            ip_r4   <= f2_ok ? m4 : 8'd0;
            f3_x0   <= f2_x0;
            f3_y0   <= f2_y0;
        end
    end

endmodule
