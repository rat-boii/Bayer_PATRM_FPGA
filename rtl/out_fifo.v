// out_fifo: output byte packer and word FIFO, spec/interface.md section 9.
//
// Packs 8 consecutive output bytes into one 64-bit word, byte k of the word = output pixel 8j + k of the frame
// (address order, little endian), and buffers OUT_DEPTH words for axi_wr_master. W is a multiple of 8 (D3), so a
// word never spans two output rows and the frame ends on a word boundary.
//
// Packer: pidx = bytes held (0..7) in pbuf. The 8th byte and the 7 held bytes are written into the FIFO as one
// word at the same clock edge (the word is in the FIFO from the cycle after its 8th byte).
//     op_ready = !(pidx == 7 && FIFO full)      (spec section 9; "full" = count == OUT_DEPTH, no bypass for a
//                                                word leaving in the same cycle)
// op_ready depends on registers only. FIFO: OUT_DEPTH x 64 bit distributed RAM, wq_valid = count != 0,
// wq_data = word at the read pointer (asynchronous read), wq_count = count (axi_wr_master issues a burst only
// when all its words are here). frame_start clears the packer and the FIFO.
// op_last is not needed by the logic (axi_wr_master knows W and H); in simulation it is checked to arrive as
// the last byte of a word.
// Bayer Option A (step 5.2, spec 18.3): with cfg_stride2 = 1 a word holds 4 plane pixels, pixel k of the group in
// byte 2k + o_col; the other bytes are 0 (masked by WSTRB in axi_wr_master). A plane row of W/2 pixels is still
// W/8 words. pbuf is cleared at frame_start and after every word, so the unused bytes are 0.
module out_fifo #(
    parameter OUT_DEPTH = 64,                            // words (spec section 0)
    parameter CNT_W     = 7                              // wq_count width: 0..OUT_DEPTH
) (
    input  wire             aclk,
    input  wire             aresetn,                     // synchronous, active low
    input  wire             frame_start,
    input  wire             cfg_stride2,                 // Bayer Option A pass (bayer_seq)
    input  wire             cfg_o_col,
    // from bilinear_interp
    input  wire             op_valid,
    output wire             op_ready,
    input  wire [7:0]       op_d,
    input  wire             op_last,                     // simulation check only
    // to axi_wr_master
    output wire             wq_valid,
    input  wire             wq_ready,
    output wire [63:0]      wq_data,
    output wire [CNT_W-1:0] wq_count
);

    localparam PTR_W = (OUT_DEPTH > 1) ? $clog2(OUT_DEPTH) : 1;

    reg [2:0]       pidx;
    reg [63:0]      pbuf;
    reg             s2, ocol;                            // latched at frame_start
    reg [63:0]      mem [0:OUT_DEPTH-1];
    reg [PTR_W-1:0] wp, rp;
    reg [CNT_W-1:0] count;

    wire full = (count == OUT_DEPTH[CNT_W-1:0]);
    wire lastb = s2 ? (pidx[1:0] == 2'd3) : (pidx == 3'd7);   // this byte completes the word
    wire [2:0] pos = s2 ? {pidx[1:0], ocol} : pidx;            // byte of the word it goes to
    assign op_ready = !(lastb && full);
    assign wq_valid = (count != {CNT_W{1'b0}});
    assign wq_data  = mem[rp];
    assign wq_count = count;

    wire in_hs = op_valid && op_ready;
    wire push  = in_hs && lastb;
    wire pop   = wq_valid && wq_ready;

    function [PTR_W-1:0] inc;
        input [PTR_W-1:0] p;
        begin
            inc = (p == OUT_DEPTH - 1) ? {PTR_W{1'b0}} : p + 1'b1;
        end
    endfunction

    always @(posedge aclk) begin
        if (!aresetn || frame_start) begin
            pidx  <= 3'd0;
            wp    <= {PTR_W{1'b0}};
            rp    <= {PTR_W{1'b0}};
            count <= {CNT_W{1'b0}};
        end else begin
            if (in_hs) pidx <= lastb ? 3'd0 : pidx + 3'd1;
            if (push) wp <= inc(wp);
            if (pop)  rp <= inc(rp);
            if (push && !pop)      count <= count + 1'b1;
            else if (pop && !push) count <= count - 1'b1;
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            s2 <= 1'b0; ocol <= 1'b0;
        end else if (frame_start) begin
            s2 <= cfg_stride2; ocol <= cfg_o_col;
        end
    end

    // the word with this byte inserted (gray: byte 7 = op_d, bytes 0..6 = pbuf)
    reg [63:0] word;
    integer bi;
    always @(*) begin
        for (bi = 0; bi < 8; bi = bi + 1)
            word[8*bi +: 8] = (pos == bi) ? op_d : pbuf[8*bi +: 8];
    end

    always @(posedge aclk) begin
        if (!aresetn || frame_start) pbuf <= 64'd0;
        else if (push)               pbuf <= 64'd0;
        else if (in_hs)              pbuf[8*pos +: 8] <= op_d;
        if (push) mem[wp] <= word;
    end

    // synthesis translate_off
    integer sim_err;
    initial sim_err = 0;
    always @(posedge aclk) begin
        if (aresetn === 1'b1 && !frame_start && in_hs && op_last === 1'b1 && !lastb) begin
            sim_err = sim_err + 1;
            $display("OUT_FIFO ERROR at %0t: op_last on byte %0d of a word (W not a multiple of 8?)", $time, pidx);
        end
    end
    // synthesis translate_on

endmodule
