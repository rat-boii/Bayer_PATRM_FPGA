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
// the 8th byte of a word.
module out_fifo #(
    parameter OUT_DEPTH = 64,                            // words (spec section 0)
    parameter CNT_W     = 7                              // wq_count width: 0..OUT_DEPTH
) (
    input  wire             aclk,
    input  wire             aresetn,                     // synchronous, active low
    input  wire             frame_start,
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
    reg [55:0]      pbuf;
    reg [63:0]      mem [0:OUT_DEPTH-1];
    reg [PTR_W-1:0] wp, rp;
    reg [CNT_W-1:0] count;

    wire full = (count == OUT_DEPTH[CNT_W-1:0]);
    assign op_ready = !((pidx == 3'd7) && full);
    assign wq_valid = (count != {CNT_W{1'b0}});
    assign wq_data  = mem[rp];
    assign wq_count = count;

    wire in_hs = op_valid && op_ready;
    wire push  = in_hs && (pidx == 3'd7);
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
            if (in_hs) pidx <= pidx + 3'd1;              // 7 -> 0 wraps
            if (push) wp <= inc(wp);
            if (pop)  rp <= inc(rp);
            if (push && !pop)      count <= count + 1'b1;
            else if (pop && !push) count <= count - 1'b1;
        end
    end

    always @(posedge aclk) begin
        if (in_hs && pidx != 3'd7) pbuf[8*pidx +: 8] <= op_d;
        if (push) mem[wp] <= {op_d, pbuf};
    end

    // synthesis translate_off
    integer sim_err;
    initial sim_err = 0;
    always @(posedge aclk) begin
        if (aresetn === 1'b1 && !frame_start && in_hs && op_last === 1'b1 && pidx != 3'd7) begin
            sim_err = sim_err + 1;
            $display("OUT_FIFO ERROR at %0t: op_last on byte %0d of a word (W not a multiple of 8?)", $time, pidx);
        end
    end
    // synthesis translate_on

endmodule
