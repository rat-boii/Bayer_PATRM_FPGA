// line_buf: on-chip copy of the source row segments (spec/interface.md section 6), step 3.6b.
//
// NSLOT slots x SLOT_WORDS words x 64 bit. Words are stored by source column (spec 6.2, option A): word w of a
// source row (bytes 8w .. 8w+7 of the row) sits at slot word (w mod SLOT_WORDS). Banking for 4 reads per clock:
//   even / odd word banks   slot word p is in bank p[0], entry slot * (SLOT_WORDS/2) + p[5:1]; two consecutive
//                           words are always in different banks
//   two copies              copy T serves row x0 (r1, r2), copy B serves row x1 (r3, r4); every write goes to
//                           both copies of its bank
// = 4 memories (T-even, T-odd, B-even, B-odd) of NSLOT * SLOT_WORDS / 2 entries x 64 bit, each simple dual port:
// one write port (prefetch_ctrl), one read port (pixel_fetch). Inferred block RAM, 1-cycle synchronous read,
// no output register (spec 6: can be switched on in step 3.8, then pixel_fetch adds one stage).
// No reset on the contents (don't care until written). re = 0 holds the read data.
// A slot is never read and written in the same cycle (spec 6.2), so the read-during-write mode does not matter.
module line_buf #(
    parameter NSLOT      = 32,
    parameter SLOT_WORDS = 64,                            // = SPAN_MAX / 8
    parameter AW         = 10                             // log2(NSLOT * SLOT_WORDS / 2)
) (
    input  wire          aclk,
    input  wire          we,                              // write (prefetch_ctrl)
    input  wire          wbank,                           // 0 even, 1 odd word
    input  wire [AW-1:0] waddr,
    input  wire [63:0]   wdata,
    input  wire          re,                              // read enable (pixel_fetch)
    input  wire [AW-1:0] raddr_te,                        // copy T, even bank
    input  wire [AW-1:0] raddr_to,                        // copy T, odd bank
    input  wire [AW-1:0] raddr_be,                        // copy B, even bank
    input  wire [AW-1:0] raddr_bo,                        // copy B, odd bank
    output reg  [63:0]   rdata_te,
    output reg  [63:0]   rdata_to,
    output reg  [63:0]   rdata_be,
    output reg  [63:0]   rdata_bo
);

    localparam DEPTH = NSLOT * SLOT_WORDS / 2;

    (* ram_style = "block" *) reg [63:0] mem_te [0:DEPTH-1];
    (* ram_style = "block" *) reg [63:0] mem_to [0:DEPTH-1];
    (* ram_style = "block" *) reg [63:0] mem_be [0:DEPTH-1];
    (* ram_style = "block" *) reg [63:0] mem_bo [0:DEPTH-1];

    wire we_e = we && !wbank;
    wire we_o = we &&  wbank;

    // one always block per memory: one write port, one read port
    always @(posedge aclk) begin
        if (we_e) mem_te[waddr] <= wdata;
        if (re)   rdata_te <= mem_te[raddr_te];
    end
    always @(posedge aclk) begin
        if (we_o) mem_to[waddr] <= wdata;
        if (re)   rdata_to <= mem_to[raddr_to];
    end
    always @(posedge aclk) begin
        if (we_e) mem_be[waddr] <= wdata;
        if (re)   rdata_be <= mem_be[raddr_be];
    end
    always @(posedge aclk) begin
        if (we_o) mem_bo[waddr] <= wdata;
        if (re)   rdata_bo <= mem_bo[raddr_bo];
    end

endmodule
