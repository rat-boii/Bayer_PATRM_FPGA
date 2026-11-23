// Four independent plane-valid tests around one R-plane coordinate.
// Each sample address is {physical row[11:0], physical byte column[11:0]}.
module bayer_geometry(
    input [31:0] base_x, base_y,
    input [127:0] dx, dy,
    input [12:0] width, height,
    output [3:0] inside_plane,
    output [63:0] xf, yf,
    output [383:0] samples,
    output reg [11:0] min_top, max_top, max_bottom,
    output reg [9:0] first_word, end_word
);
    wire [11:0] last_x = (height >> 1) - 1'b1;
    wire [11:0] last_y = (width >> 1) - 1'b1;
    wire [11:0] top [0:3], bottom [0:3], left_col [0:3], right_col [0:3];
    genvar k;
    generate for (k=0; k<4; k=k+1) begin: lane
        wire [31:0] x = base_x + dx[k*32+:32];
        wire [31:0] y = base_y + dy[k*32+:32];
        assign inside_plane[k] = x <= {4'b0,last_x,16'b0} && y <= {4'b0,last_y,16'b0};
        assign xf[k*16+:16] = x[15:0];
        assign yf[k*16+:16] = y[15:0];
        assign top[k] = x[27:16];
        assign bottom[k] = top[k] == last_x ? top[k] : top[k]+1'b1;
        assign left_col[k] = y[27:16];
        assign right_col[k] = left_col[k] == last_y ? left_col[k] : left_col[k]+1'b1;
        wire [11:0] r0 = {top[k][10:0],k[1]}, r1 = {bottom[k][10:0],k[1]};
        wire [11:0] c0 = {left_col[k][10:0],k[0]}, c1 = {right_col[k][10:0],k[0]};
        assign samples[k*96+:96] = {r1,c1,r1,c0,r0,c1,r0,c0};
    end endgenerate
    integer i;
    always @* begin
        min_top=4095; max_top=0; max_bottom=0; first_word=512; end_word=0;
        for(i=0;i<4;i=i+1) if(inside_plane[i]) begin
            if(top[i]<min_top) min_top=top[i];
            if(top[i]>max_top) max_top=top[i];
            if(bottom[i]>max_bottom) max_bottom=bottom[i];
            if((left_col[i]>>2)<first_word) first_word=left_col[i]>>2;
            if(((right_col[i]>>2)+1)>end_word) end_word=(right_col[i]>>2)+1;
        end
    end
endmodule
