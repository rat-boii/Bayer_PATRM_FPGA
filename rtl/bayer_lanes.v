// MODE 2. Scan R coordinates, collect a bounded logical block, then fetch
// and consume its physical groups. Only the oversized path enumerates words.
module bayer_lanes #(parameter ENABLE_FALLBACK=1)(
    input aclk, aresetn, frame_start,
    input [12:0] width,height,block_len,
    input [31:0] src,b11,b12,b21,b22, input [127:0] tx,ty,
    output cmd_valid,input cmd_ready,output [31:0] cmd_addr,output [6:0] cmd_words,
    output [4:0] cmd_slot,input rd_valid,input [63:0] rd_data,input [4:0] rd_slot,input [5:0] rd_word,input rd_cmd_last,
    output wq_valid,input wq_ready,output [63:0] wq_data,output [6:0] wq_count,
    output rd_stall,wr_stall
);
    localparam IDLE=0,SCAN=1,BEGIN_GROUP=2,RECT=3,SORT=4,SPARSE=5,SEAL=6,EXECUTE=7;
    reg [3:0] state;
    wire [12:0] pw=width>>1, ph=height>>1;
    reg [12:0] du,dv;
    wire [12:0] left_in_row=pw-dv;
    wire [6:0] chunk=left_in_row>64 ? 7'd64 : left_in_row[6:0];
    reg descriptors;
    wire desc_ready, coord_valid, coord_take;
    wire [31:0] scan_x,scan_y;
    coord_gen coords(.aclk(aclk),.aresetn(aresetn),.frame_start(frame_start),
        .cfg_b11(b11),.cfg_b12(b12),.cfg_b13(tx[31:0]),.cfg_b21(b21),.cfg_b22(b22),.cfg_b23(ty[31:0]),
        .desc_valid(descriptors),.desc_ready(desc_ready),.desc_u(du),.desc_v0(dv),.desc_n(chunk),
        .desc_nrows(2'd0),.desc_slot_top(5'd0),.desc_slot_bot(5'd0),.desc_s_col(13'd0),.desc_last(1'b0),
        .pix_valid(coord_valid),.pix_ready(coord_take),.pix_X(scan_x),.pix_Y(scan_y),
        .pix_first(),.pix_last(),.pix_nrows(),.pix_slot_top(),.pix_slot_bot(),.pix_s_col(),.pix_frame_last());
    always @(posedge aclk) begin
        if(!aresetn || frame_start) begin du<=0; dv<=0; descriptors<=aresetn && frame_start; end
        else if(descriptors && desc_ready) begin
            if(dv+chunk==pw) begin dv<=0; du<=du+1'b1; if(du+1'b1==ph) descriptors<=0; end
            else dv<=dv+chunk;
        end
    end
    reg [31:0] xs[0:63],ys[0:63];
    reg [6:0] count;
    reg [5:0] pos;
    reg [12:0] scan_col,scan_row;
    reg last_block;
    reg [127:0] dx,dy;
    genvar k;
    generate for(k=0;k<4;k=k+1) begin: offset
        always @(posedge aclk) if(frame_start) begin
            `ifdef PATRM_FAULT_B_OFFSET
            dx[k*32+:32]<=tx[k*32+:32]-tx[31:0]+(k==1);
`else
            dx[k*32+:32]<=tx[k*32+:32]-tx[31:0];
`endif
            dy[k*32+:32]<=ty[k*32+:32]-ty[31:0];
        end
    end endgenerate
    wire [383:0] samples;
    wire [3:0] ok;
    wire [63:0] xf,yf;
    wire [11:0] top_lo,top_hi,bot_hi;
    wire [9:0] first_w,end_w;
    bayer_geometry geometry(.base_x(state==SCAN?scan_x:xs[pos]),.base_y(state==SCAN?scan_y:ys[pos]),
        .dx(dx),.dy(dy),.width(width),.height(height),.inside_plane(ok),.xf(xf),.yf(yf),.samples(samples),
        .min_top(top_lo),.max_top(top_hi),.max_bottom(bot_hi),.first_word(first_w),.end_word(end_w));
    reg have_data,have_key;
    reg [11:0] key_lo,key_hi,block_lo,block_hi;
    reg [9:0] first,end_col;
    wire [9:0] next_first=have_data && first<first_w ? first:first_w;
    wire [9:0] next_end=have_data && end_col>end_w ? end_col:end_w;
    wire boundary=count!=0 && (|ok) && ((have_key && (key_lo!=top_lo || key_hi!=top_hi))
                         || next_end-next_first>64);
    assign coord_take=state==SCAN && !boundary;
    wire oversized=ENABLE_FALLBACK && have_data && (block_hi-block_lo>=8 || end_col-first>64);
    reg [11:0] row;
    reg [20:0] cursor_word,run_first,run_last;
    reg cursor_valid,run_valid;
    reg [21:0] smallest;
    integer i;
    always @* begin
        smallest=22'h200000;
        for(i=0;i<16;i=i+1)
            if(ok[i/4] && (!cursor_valid || samples[i*24+3+:21]>cursor_word)
               && samples[i*24+3+:21]<smallest) smallest={1'b0,samples[i*24+3+:21]};
    end
    wire window_ready;
    wire fetch_idle;                     // every issued window of the group has returned its last beat
    wire sample_en;
    wire [127:0] pixels;
    bayer_store store(.aclk(aclk),.aresetn(aresetn),.frame_start(frame_start),
        .group_start(state==BEGIN_GROUP),.group_seal(state==SEAL),
        .window_valid(state==RECT || state==SPARSE),.window_ready(window_ready),
        .window_row(state==RECT?row:run_first[20:9]),
        .window_first(state==RECT?first:{1'b0,run_first[8:0]}),
        .window_end(state==RECT?end_col:({1'b0,run_last[8:0]}+10'd1)),
        .src(src),.width(width),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_addr(cmd_addr),
        .cmd_words(cmd_words),.cmd_slot(cmd_slot),.rd_valid(rd_valid),.rd_data(rd_data),
        .rd_slot(rd_slot),.rd_word(rd_word),.rd_cmd_last(rd_cmd_last),.fetch_idle(fetch_idle),
        .sample_en(sample_en),.samples(samples),.pixels(pixels));
    wire tile_ready,tile_valid;
    reg held;
    reg [3:0] ok_q;
    reg [63:0] xf_q,yf_q;
    wire ip_ready;
    assign sample_en=state==EXECUTE && (!held || ip_ready);
    always @(posedge aclk) begin
        if(!aresetn || frame_start) held<=0;
        else if(!held || ip_ready) begin
            held<=sample_en;
            if(sample_en) begin ok_q<=ok; xf_q<=xf; yf_q<=yf; end
        end
    end
    wire [31:0] tile;
    wire [3:0] readiness,validity;
    assign ip_ready=readiness[0];
    assign tile_valid=validity[0];
    generate for(k=0;k<4;k=k+1) begin: interp
        bilinear_interp lane(.aclk(aclk),.aresetn(aresetn),.ip_valid(held),.ip_ready(readiness[k]),
            .ip_ok(ok_q[k]),.ip_xf(xf_q[k*16+:16]),.ip_yf(yf_q[k*16+:16]),
            .ip_r1(pixels[k*32+:8]),.ip_r2(pixels[k*32+8+:8]),
            .ip_r3(pixels[k*32+16+:8]),.ip_r4(pixels[k*32+24+:8]),.ip_last(1'b0),
            .op_ready(tile_ready),.op_valid(validity[k]),.op_d(tile[k*8+:8]),.op_last(),.wr_stall());
    end endgenerate
    bayer_merge merge_rows(.aclk(aclk),.aresetn(aresetn),.frame_start(frame_start),.width(width),
        .tile_valid(tile_valid),.tile_ready(tile_ready),.tile(tile),
        .word_valid(wq_valid),.word_ready(wq_ready),.word_data(wq_data),.word_count(wq_count));
    assign wr_stall=tile_valid && !tile_ready;
    assign rd_stall=have_data && state>=BEGIN_GROUP && state<=SEAL && !wr_stall;
    always @(posedge aclk) begin
        if(!aresetn || frame_start) begin
            state<=aresetn && frame_start ? SCAN:IDLE;
            count<=0; pos<=0; scan_col<=0; scan_row<=0; have_key<=0; have_data<=0; last_block<=0;
        end else case(state)
            SCAN: if(coord_valid) begin
                if(boundary) state<=BEGIN_GROUP;
                else begin
                    xs[count]<=scan_x; ys[count]<=scan_y; count<=count+1'b1;
                    if(|ok) begin
                        key_lo<=top_lo; key_hi<=top_hi; have_key<=1; have_data<=1;
                        if(!have_data || top_lo<block_lo) block_lo<=top_lo;
                        if(!have_data || bot_hi>block_hi) block_hi<=bot_hi;
                        first<=next_first; end_col<=next_end;
                    end
                    scan_col<=scan_col+1'b1;
                    if(scan_col+1'b1==pw) begin
                        state<=BEGIN_GROUP; scan_col<=0; scan_row<=scan_row+1'b1; have_key<=0;
                        last_block<=scan_row+1'b1==ph;
                    end else if(count+1'b1==block_len) state<=BEGIN_GROUP;
                end
            end
            BEGIN_GROUP: begin
                row<=block_lo<<1; cursor_valid<=0; run_valid<=0;
                if(!have_data) state<=SEAL;
                else if(oversized) state<=SORT;
                else state<=RECT;
            end
            RECT: if(window_ready) begin
                if(row=={block_hi[10:0],1'b1}) state<=SEAL;
                row<=row+1'b1;
            end
            SORT: begin
                if(smallest[21]) state<=run_valid?SPARSE:SEAL;
                else if(!run_valid || (smallest[20:9]==run_last[20:9] && smallest==run_last+1'b1)) begin
                    if(!run_valid) run_first<=smallest;
                    run_last<=smallest; cursor_word<=smallest; cursor_valid<=1; run_valid<=1;
                end else state<=SPARSE;
            end
            SPARSE: if(window_ready) begin run_valid<=0; state<=SORT; end
            // windows are issued back to back (bayer_store); interpolate only once all of them have returned
            SEAL: if(fetch_idle) state<=EXECUTE;
            EXECUTE: if(sample_en) begin
                if({1'b0,pos}+7'd1==count) begin
                    state<=last_block?IDLE:SCAN; pos<=0; count<=0; have_data<=0;
                end else begin pos<=pos+1'b1; if(oversized) state<=BEGIN_GROUP; end
            end
            default: state<=IDLE;
        endcase
    end
endmodule
