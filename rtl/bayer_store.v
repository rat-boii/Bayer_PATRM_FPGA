// A physical group owns up to 16 row windows. Preserve previous-group slots
// for P1 and allocate missing windows from the other slots until group seal.
// Missed windows are issued back to back (axi_rd_master keeps up to RD_OUTSTANDING bursts in flight); each returned
// beat is written by its own command's slot (rd_slot) at that window's first word + rd_word. fetch_idle = no issued
// window still waiting for its last beat; bayer_lanes interpolates a group only then. Until 2026-11-27 the store
// waited for each window's last beat before issuing the next (one read in flight), which made B latency-bound.
module bayer_store(
    input aclk, aresetn, frame_start, group_start, group_seal,
    input window_valid, output window_ready, input [11:0] window_row,
    input [9:0] window_first, window_end,
    input [31:0] src, input [12:0] width,
    output cmd_valid, input cmd_ready, output [31:0] cmd_addr,
    output [6:0] cmd_words, output [4:0] cmd_slot,
    input rd_valid, input [63:0] rd_data, input [4:0] rd_slot, input [5:0] rd_word, input rd_cmd_last,
    output fetch_idle,
    input sample_en, input [383:0] samples, output [127:0] pixels
);
    reg [4:0] count, prev_count;
    reg [11:0] row_tag [0:15], prev_row [0:15];
    reg [9:0] first_tag [0:15], end_tag [0:15], prev_first [0:15], prev_end [0:15];
    reg [4:0] slots [0:15], prev_slots [0:15];
    reg [31:0] pinned, allocated;
    reg hit;
    reg [5:0] pending;                   // issued windows whose last beat has not arrived (at most 16 per group)
    reg [5:0] slot_first [0:31];         // first word (mod 64) of the window held in each slot
    reg [4:0] chosen;
    integer i;
    always @* begin
        chosen=0; hit=0;
        for(i=31;i>=0;i=i-1)
`ifdef PATRM_FAULT_B_OVERWRITE
            if(!allocated[i])
`else
            if(!pinned[i] && !allocated[i])
`endif
                chosen=i;
        for(i=0;i<16;i=i+1)
            if(i<prev_count && window_row==prev_row[i] &&
               prev_first[i]<=window_first && prev_end[i]>=window_end) begin
                hit=1; chosen=prev_slots[i];
            end
    end
    assign cmd_valid = window_valid && !hit;
    assign cmd_addr = src + window_row*width + (window_first*8);
    assign cmd_words = window_end-window_first;
    assign cmd_slot = chosen;
    assign window_ready = hit || cmd_ready;
    wire issue = window_valid && !hit && cmd_ready;
    wire retire = rd_valid && rd_cmd_last;
    assign fetch_idle = pending==0;
    integer j;
    always @(posedge aclk) begin
        if(!aresetn || frame_start) begin
            count<=0; prev_count<=0; pending<=0; pinned<=0; allocated<=0;
        end else begin
            if(group_start) begin count<=0; allocated<=0; end
            if(window_valid && (hit || cmd_ready)) begin
                row_tag[count]<=window_row; first_tag[count]<=window_first;
                end_tag[count]<=window_end; slots[count]<=chosen;
                allocated[chosen]<=1; count<=count+1'b1;
            end
            if(issue) slot_first[chosen]<=window_first[5:0];
            pending<=pending+(issue ? 6'd1 : 6'd0)-(retire ? 6'd1 : 6'd0);
            if(group_seal && count!=0) begin
                prev_count<=count; pinned<=allocated;
                for(j=0;j<16;j=j+1) begin
                    prev_row[j]<=row_tag[j]; prev_first[j]<=first_tag[j];
                    prev_end[j]<=end_tag[j]; prev_slots[j]<=slots[j];
                end
            end
        end
    end
    wire [5:0] fill_word = slot_first[rd_slot]+rd_word;
    wire [9:0] raddr [0:15];
    wire [63:0] bank_q [0:15];
    genvar k;
    generate for(k=0;k<16;k=k+1) begin: neighbour
        wire [23:0] addr = samples[k*24+:24];
        reg [4:0] slot;
        integer n;
        always @* begin
            slot=0;
            for(n=0;n<16;n=n+1)
                if(n<count && row_tag[n]==addr[23:12] && first_tag[n]<=addr[11:3] && end_tag[n]>addr[11:3])
                    slot=slots[n];
        end
        assign raddr[k]={slot,addr[8:4]};
        reg [3:0] select_byte;
        always @(posedge aclk) if(sample_en) select_byte<=addr[3:0];
        wire [63:0] word = select_byte[3] ? bank_q[(k/2)*2+1] : bank_q[(k/2)*2];
        assign pixels[k*8+:8]=word[select_byte[2:0]*8+:8];
    end
    for(k=0;k<4;k=k+1) begin: banks
        localparam N=k*4;
        wire top_odd=samples[N*24+3], bot_odd=samples[(N+2)*24+3];
        line_buf bank(.aclk(aclk),.we(rd_valid),.wbank(fill_word[0]),
            .waddr({rd_slot,fill_word[5:1]}),.wdata(rd_data),.re(sample_en),
            .raddr_te(top_odd?raddr[N+1]:raddr[N]),.raddr_to(top_odd?raddr[N]:raddr[N+1]),
            .raddr_be(bot_odd?raddr[N+3]:raddr[N+2]),.raddr_bo(bot_odd?raddr[N+2]:raddr[N+3]),
            .rdata_te(bank_q[N]),.rdata_to(bank_q[N+1]),.rdata_be(bank_q[N+2]),.rdata_bo(bank_q[N+3]));
    end endgenerate
endmodule
