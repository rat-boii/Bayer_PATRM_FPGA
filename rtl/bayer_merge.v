// Collect one RGGB row pair. The two synchronous word memories drain in DDR
// row order. Count only words whose data is available or reserved for this pair.
module bayer_merge(
    input aclk, aresetn, frame_start,
    input [12:0] width,
    input tile_valid, output tile_ready, input [31:0] tile,
    output word_valid, input word_ready, output [63:0] word_data,
    output [6:0] word_count
);
    reg [47:0] even_partial, odd_partial;
    reg [10:0] col;
    reg [63:0] even_ram [0:511], odd_ram [0:511];
`ifdef PATRM_FAULT_B_GREENS
    wire [7:0] gr=tile[23:16],gb=tile[15:8];
`else
    wire [7:0] gr=tile[15:8],gb=tile[23:16];
`endif
    wire [63:0] even_word = {gr,tile[7:0],even_partial};
    wire [63:0] odd_word = {tile[31:24],gb,odd_partial};
    reg [10:0] remaining;
    reg [9:0] pos;
    reg draining;
    reg [63:0] even_q, odd_q;
    reg odd_select, valid_q;
    assign tile_ready = !draining && !valid_q;
    wire take = tile_valid && tile_ready;
    wire advance = !valid_q || word_ready;
    wire [9:0] row_words = width >> 3;
    wire odd = pos >= row_words;
    wire [8:0] addr = odd ? pos-row_words : pos;
    always @(posedge aclk) begin
        if(take && col[1:0]==3) begin
            even_ram[col[10:2]] <= even_word;
            odd_ram[col[10:2]] <= odd_word;
        end
        if(draining && advance) begin
            even_q <= even_ram[addr];
            odd_q <= odd_ram[addr];
            odd_select <= odd;
        end
    end
    assign word_valid = valid_q;
    assign word_data = odd_select ? odd_q : even_q;
    assign word_count = remaining > 64 ? 7'd64 : remaining[6:0];
    always @(posedge aclk) begin
        if(!aresetn || frame_start) begin
            col<=0; pos<=0; draining<=0; valid_q<=0; remaining<=0;
        end else begin
            if(take) begin
                even_partial <= even_word[63:16];
                odd_partial <= odd_word[63:16];
                col <= col+1'b1;
                if(col+13'd1 == (width>>1)) begin
                    col<=0; draining<=1; pos<=0; remaining<=width>>2;
                end
            end
            if(advance) begin
                valid_q<=draining;
                if(draining) begin
                    pos<=pos+1'b1;
                    if(pos+11'd1 == (width>>2)) draining<=0;
                end
            end
            if(valid_q && word_ready) remaining<=remaining-1'b1;
        end
    end
endmodule
