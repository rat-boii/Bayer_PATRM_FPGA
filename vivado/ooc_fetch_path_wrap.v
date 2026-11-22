// ooc_fetch_path_wrap: SYNTHESIS-ONLY wrapper for the step 3.6b OOC run (vivado/ooc_fetch_path.tcl), not part of
// the engine RTL (patrm_top comes in step 3.7). It joins prefetch_ctrl -> line_buf -> pixel_fetch so that the paths
// between them are timed register to register: line_buf write port (prefetch_ctrl registers -> RAM) and, above
// all, RAM output -> byte muxes -> F3 registers in pixel_fetch, which a pixel_fetch-only run cannot see (the RAM
// data are module inputs there). All other signals are module ports. Parameters: the build values (section 0).
module ooc_fetch_path_wrap (
    input  wire          aclk,
    input  wire          aresetn,
    input  wire          frame_start,
    input  wire [31:0]   cfg_src_addr,
    input  wire [12:0]   cfg_width,
    input  wire [12:0]   cfg_height,
    input  wire          fetch_valid,
    output wire          fetch_ready,
    input  wire [12:0]   fetch_row_top,
    input  wire [12:0]   fetch_row_bot,
    input  wire [4:0]    fetch_slot_top,
    input  wire [4:0]    fetch_slot_bot,
    input  wire          fetch_top,
    input  wire          fetch_bot,
    input  wire [12:0]   fetch_s_col,
    input  wire [6:0]    fetch_words,
    output wire          cmd_valid,
    input  wire          cmd_ready,
    output wire [31:0]   cmd_addr,
    output wire [6:0]    cmd_words,
    output wire [4:0]    cmd_slot,
    input  wire          rd_valid,
    input  wire [63:0]   rd_data,
    input  wire [4:0]    rd_slot,
    input  wire [5:0]    rd_word,
    input  wire          rd_cmd_last,
    input  wire          pix_valid,
    output wire          pix_ready,
    input  wire [31:0]   pix_X,
    input  wire [31:0]   pix_Y,
    input  wire          pix_first,
    input  wire          pix_last,
    input  wire [1:0]    pix_nrows,
    input  wire [4:0]    pix_slot_top,
    input  wire [4:0]    pix_slot_bot,
    input  wire [12:0]   pix_s_col,
    input  wire          pix_frame_last,
    output wire          ip_valid,
    input  wire          ip_ready,
    output wire [15:0]   ip_xf,
    output wire [15:0]   ip_yf,
    output wire [7:0]    ip_r1,
    output wire [7:0]    ip_r2,
    output wire [7:0]    ip_r3,
    output wire [7:0]    ip_r4,
    output wire          ip_ok,
    output wire          ip_last,
    output wire          rd_stall
);
    wire        buf_we, buf_wbank, buf_re, blk_done;
    wire [9:0]  buf_waddr, raddr_te, raddr_to, raddr_be, raddr_bo;
    wire [63:0] buf_wdata, rdata_te, rdata_to, rdata_be, rdata_bo;
    wire [15:0] blocks_ready;

    prefetch_ctrl u_pc (
        .aclk(aclk), .aresetn(aresetn), .frame_start(frame_start), .cfg_src_addr(cfg_src_addr), .cfg_width(cfg_width), .cfg_stride2(1'b0),
        .fetch_valid(fetch_valid), .fetch_ready(fetch_ready), .fetch_row_top(fetch_row_top),
        .fetch_row_bot(fetch_row_bot), .fetch_slot_top(fetch_slot_top), .fetch_slot_bot(fetch_slot_bot),
        .fetch_top(fetch_top), .fetch_bot(fetch_bot), .fetch_s_col(fetch_s_col), .fetch_words(fetch_words),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_addr(cmd_addr), .cmd_words(cmd_words), .cmd_slot(cmd_slot),
        .rd_valid(rd_valid), .rd_data(rd_data), .rd_slot(rd_slot), .rd_word(rd_word), .rd_cmd_last(rd_cmd_last),
        .buf_we(buf_we), .buf_wbank(buf_wbank), .buf_waddr(buf_waddr), .buf_wdata(buf_wdata),
        .blocks_ready(blocks_ready), .blk_done(blk_done));

    line_buf u_lb (
        .aclk(aclk), .we(buf_we), .wbank(buf_wbank), .waddr(buf_waddr), .wdata(buf_wdata),
        .re(buf_re), .raddr_te(raddr_te), .raddr_to(raddr_to), .raddr_be(raddr_be), .raddr_bo(raddr_bo),
        .rdata_te(rdata_te), .rdata_to(rdata_to), .rdata_be(rdata_be), .rdata_bo(rdata_bo));

    pixel_fetch u_pf (
        .aclk(aclk), .aresetn(aresetn), .frame_start(frame_start), .cfg_width(cfg_width), .cfg_height(cfg_height),
        .cfg_stride2(1'b0), .cfg_o_col(1'b0),
        .pix_valid(pix_valid), .pix_ready(pix_ready), .pix_X(pix_X), .pix_Y(pix_Y), .pix_first(pix_first),
        .pix_last(pix_last), .pix_nrows(pix_nrows), .pix_slot_top(pix_slot_top), .pix_slot_bot(pix_slot_bot),
        .pix_s_col(pix_s_col), .pix_frame_last(pix_frame_last),
        .blocks_ready(blocks_ready), .blk_done(blk_done),
        .buf_re(buf_re), .buf_raddr_te(raddr_te), .buf_raddr_to(raddr_to), .buf_raddr_be(raddr_be),
        .buf_raddr_bo(raddr_bo), .buf_rdata_te(rdata_te), .buf_rdata_to(rdata_to), .buf_rdata_be(rdata_be),
        .buf_rdata_bo(rdata_bo),
        .ip_valid(ip_valid), .ip_ready(ip_ready), .ip_xf(ip_xf), .ip_yf(ip_yf), .ip_r1(ip_r1), .ip_r2(ip_r2),
        .ip_r3(ip_r3), .ip_r4(ip_r4), .ip_ok(ip_ok), .ip_last(ip_last), .rd_stall(rd_stall));
endmodule
