// bilinear_interp: D10 (option A2) bilinear interpolator, spec/interface.md section 8.
//
//   w2 = ((65536 - xf) * yf) >> 16      w3 = (xf * (65536 - yf)) >> 16      w4 = (xf * yf) >> 16
//   w1 = 65536 - (w2 + w3 + w4)
//   D  = (w1*r1 + w2*r2 + w3*r3 + w4*r4) >> 16         r1 = (x0,y0), r2 = (x0,y0+1), r3 = (x0+1,y0), r4 = (x0+1,y0+1)
//   op_d = ip_ok ? D : 0                               (D1: the pixel is out of range when ip_ok = 0)
//
// Bit-exact to model/patrm.py interp_d10. All values are unsigned; the only truncations are the two ">> 16"
// (drop the 16 low bits = floor). 7 multipliers (3 weight + 4 pixel), 4 register stages, one pixel per clock:
//   stage 1  p2, p3, p4      products of the fractions (65536 - xf and 65536 - yf are formed in fabric from the inputs)
//   stage 2  w1, w2, w3, w4  weights (w2..w4 = high halves of the products, w1 by one add and one subtract)
//   stage 3  q1 .. q4        weight x pixel
//   stage 4  op_d            sum of the four products, >> 16, forced to 0 when the pixel is invalid
// Latency 4 cycles (input transfer -> op_valid). ce pipeline (spec section 0): all stages advance together,
// ce = !(op_valid && !op_ready), ip_ready = ce. Only the valid bits are reset.
//
// Not in this module (spec section 7, pixel_fetch stage F1): the D1 range compare that produces ip_ok, the
// integer / fraction split of X and Y, and the clamp of the neighbour indices x0+1, y0+1 to H-1, W-1.
//
// PATRM_FAULT_W1 (test only): w1 is 1 too small, so the weights no longer sum to 65536. tb_bilinear_interp
// must fail with it.
module bilinear_interp #(
    parameter FRAC_BITS = 16,                            // fraction bits of Q15.16
    parameter PIX_BITS  = 8                              // pixel width
) (
    input  wire                 aclk,
    input  wire                 aresetn,                 // synchronous, active low
    // from pixel_fetch
    input  wire                 ip_valid,
    output wire                 ip_ready,
    input  wire [FRAC_BITS-1:0] ip_xf,                   // row fraction
    input  wire [FRAC_BITS-1:0] ip_yf,                   // column fraction
    input  wire [PIX_BITS-1:0]  ip_r1,                   // (x0,   y0)
    input  wire [PIX_BITS-1:0]  ip_r2,                   // (x0,   y0+1)  next column
    input  wire [PIX_BITS-1:0]  ip_r3,                   // (x0+1, y0)    next row
    input  wire [PIX_BITS-1:0]  ip_r4,                   // (x0+1, y0+1)
    input  wire                 ip_ok,                   // D1 valid
    input  wire                 ip_last,                 // last pixel of the frame
    // to out_fifo
    output wire                 op_valid,
    input  wire                 op_ready,
    output wire [PIX_BITS-1:0]  op_d,
    output wire                 op_last,
    output wire                 wr_stall                 // to ctrl_fsm (spec section 13): op_valid & !op_ready
);

    localparam W_BITS = FRAC_BITS + 1;                   // 17: a weight can be exactly 65536
    localparam P_BITS = 2 * FRAC_BITS;                   // 32: product of two fractions
    localparam Q_BITS = FRAC_BITS + PIX_BITS;            // 24: weight x pixel and their sum (<= 255 * 65536)
    localparam [W_BITS-1:0] ONE = {1'b1, {FRAC_BITS{1'b0}}};   // 65536

    // ---------------- handshake ----------------
    reg  [3:0] vld;                                      // vld[k] = stage k+1 holds a pixel
    wire       ce = !(vld[3] && !op_ready);
    assign ip_ready = ce;
    assign op_valid = vld[3];
    assign wr_stall = vld[3] && !op_ready;

    always @(posedge aclk) begin
        if (!aresetn) vld <= 4'b0000;
        else if (ce)  vld <= {vld[2:0], ip_valid};
    end

    // ---------------- stage 1: fraction products ----------------
    wire [W_BITS-1:0] nxf = ONE - {1'b0, ip_xf};         // 65536 - xf, 1 .. 65536
    wire [W_BITS-1:0] nyf = ONE - {1'b0, ip_yf};

    (* use_dsp = "yes" *) reg [P_BITS-1:0] p2;           // nxf * yf  (17 x 16, max 4294901760 < 2^32)
    (* use_dsp = "yes" *) reg [P_BITS-1:0] p3;           // xf * nyf  (16 x 17)
    (* use_dsp = "yes" *) reg [P_BITS-1:0] p4;           // xf * yf   (16 x 16)
    reg [PIX_BITS-1:0] r1_a, r2_a, r3_a, r4_a;
    reg                ok_a, last_a;

    always @(posedge aclk) begin
        if (ce) begin
            p2     <= nxf * ip_yf;
            p3     <= ip_xf * nyf;
            p4     <= ip_xf * ip_yf;
            r1_a   <= ip_r1;
            r2_a   <= ip_r2;
            r3_a   <= ip_r3;
            r4_a   <= ip_r4;
            ok_a   <= ip_ok;
            last_a <= ip_last;
        end
    end

    // ---------------- stage 2: weights ----------------
    wire [FRAC_BITS-1:0] w2_c = p2[P_BITS-1:FRAC_BITS];  // truncation 1: >> 16
    wire [FRAC_BITS-1:0] w3_c = p3[P_BITS-1:FRAC_BITS];
    wire [FRAC_BITS-1:0] w4_c = p4[P_BITS-1:FRAC_BITS];
    wire [W_BITS-1:0]    s234 = {1'b0, w2_c} + {1'b0, w3_c} + {1'b0, w4_c};   // always <= 65535
`ifdef PATRM_FAULT_W1
    wire [W_BITS-1:0]    w1_c = ONE - s234 - 1'b1;
`else
    wire [W_BITS-1:0]    w1_c = ONE - s234;              // 1 .. 65536
`endif

    reg [W_BITS-1:0]    w1;
    reg [FRAC_BITS-1:0] w2, w3, w4;
    reg [PIX_BITS-1:0]  r1_b, r2_b, r3_b, r4_b;
    reg                 ok_b, last_b;

    always @(posedge aclk) begin
        if (ce) begin
            w1     <= w1_c;
            w2     <= w2_c;
            w3     <= w3_c;
            w4     <= w4_c;
            r1_b   <= r1_a;
            r2_b   <= r2_a;
            r3_b   <= r3_a;
            r4_b   <= r4_a;
            ok_b   <= ok_a;
            last_b <= last_a;
        end
    end

    // ---------------- stage 3: weight x pixel ----------------
    (* use_dsp = "yes" *) reg [Q_BITS-1:0] q1;           // w1 * r1  (17 x 8, max 16711680 < 2^24)
    (* use_dsp = "yes" *) reg [Q_BITS-1:0] q2;           // w2 * r2  (16 x 8)
    (* use_dsp = "yes" *) reg [Q_BITS-1:0] q3;           // w3 * r3
    (* use_dsp = "yes" *) reg [Q_BITS-1:0] q4;           // w4 * r4
    reg ok_c, last_c;

    always @(posedge aclk) begin
        if (ce) begin
            q1     <= w1 * r1_b;
            q2     <= w2 * r2_b;
            q3     <= w3 * r3_b;
            q4     <= w4 * r4_b;
            ok_c   <= ok_b;
            last_c <= last_b;
        end
    end

    // ---------------- stage 4: sum, >> 16, D1 zero ----------------
    wire [Q_BITS-1:0] acc = (q1 + q2) + (q3 + q4);       // <= 255 * 65536, no carry out of 24 bits
    reg  [PIX_BITS-1:0] d_r;
    reg                 last_r;

    always @(posedge aclk) begin
        if (ce) begin
            d_r    <= ok_c ? acc[Q_BITS-1:FRAC_BITS] : {PIX_BITS{1'b0}};   // truncation 2: >> 16
            last_r <= last_c;
        end
    end

    assign op_d    = d_r;
    assign op_last = last_r;

endmodule
