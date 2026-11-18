// patrm_top: the grayscale PATRM engine, spec/interface.md section 12 (data path: section 0).
//
//   s_axi -> axil_regs -> ctrl_fsm --frame_start--> all
//   block_planner --desc--> coord_gen --pix--> pixel_fetch --> bilinear_interp --> out_fifo --> axi_wr_master -> m_axi_hp1
//         |                                         ^
//         +--fetch--> prefetch_ctrl --cmd--> axi_rd_master <- m_axi_hp0
//                          +------> line_buf <------+
//
// m_axi_hp0 and m_axi_hp1 are complete AXI3 interfaces for the S_AXI_HP ports of the PS. HP0 uses only the read
// channels and HP1 only the write channels; the outputs of the unused channels are constants (no valid, BREADY /
// RREADY = 1) and their inputs are ignored.
//
// Test-only fault (never set in a build): PATRM_FAULT_DONE_EARLY ends the frame when the last pixel leaves
// bilinear_interp instead of after the last write response.
`timescale 1ns/1ps
module patrm_top #(
    parameter VERSION          = 1,                      // BUILD_ID.VERSION (= regs.json version)
    parameter BUILD_TYPE       = 0,                      // gray build
    parameter MODES            = 1,                      // only CTRL.MODE = 0 accepted
    parameter BLOCK_LEN_MAX    = 64,                     // D15
    parameter SPAN_MAX         = 512,                    // D16 rule (c), bytes = one buffer slot
    parameter NSLOT            = 32,                     // line buffer row slots (power of 2)
    parameter RD_OUTSTANDING   = 8,                      // read bursts in flight on HP0
    parameter WR_OUTSTANDING   = 8,                      // write bursts without B response on HP1
    parameter DESC_DEPTH       = 16,                     // block descriptor FIFO
    parameter FETCH_DEPTH      = 16,                     // fetch FIFO
    parameter OUT_DEPTH        = 64,                     // out_fifo depth, 64-bit words
    parameter SIZE_BITS        = 13,                     // WIDTH / HEIGHT / BLOCK_LEN / row / column fields
    parameter S_AXI_ADDR_WIDTH = 7,                      // regs.json addr_bits
    parameter AXI_ID_WIDTH     = 6                       // HP port ID width
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:m_axi_hp0:m_axi_hp1, ASSOCIATED_RESET aresetn, FREQ_HZ 100000000" *)
    input  wire                        aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                        aresetn,
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 interrupt INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "SENSITIVITY LEVEL_HIGH" *)
    output wire                        interrupt,

    // ---- AXI4-Lite slave (M_AXI_GP0 through the interconnect) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 7, READ_WRITE_MODE READ_WRITE" *)
    input  wire [S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWPROT" *)
    input  wire [2:0]                  s_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *)
    input  wire                        s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *)
    output wire                        s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA" *)
    input  wire [31:0]                 s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB" *)
    input  wire [3:0]                  s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID" *)
    input  wire                        s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY" *)
    output wire                        s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP" *)
    output wire [1:0]                  s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID" *)
    output wire                        s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY" *)
    input  wire                        s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR" *)
    input  wire [S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARPROT" *)
    input  wire [2:0]                  s_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *)
    input  wire                        s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *)
    output wire                        s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA" *)
    output wire [31:0]                 s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP" *)
    output wire [1:0]                  s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID" *)
    output wire                        s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY" *)
    input  wire                        s_axi_rready,

    // ---- AXI3 master to S_AXI_HP0: reads the source image; write channels tied off ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWID" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axi_hp0, PROTOCOL AXI3, DATA_WIDTH 64, ADDR_WIDTH 32, ID_WIDTH 6, MAX_BURST_LENGTH 16, READ_WRITE_MODE READ_WRITE" *)
    output wire [AXI_ID_WIDTH-1:0]     m_axi_hp0_awid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWADDR" *)
    output wire [31:0]                 m_axi_hp0_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWLEN" *)
    output wire [3:0]                  m_axi_hp0_awlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWSIZE" *)
    output wire [2:0]                  m_axi_hp0_awsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWBURST" *)
    output wire [1:0]                  m_axi_hp0_awburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWLOCK" *)
    output wire [1:0]                  m_axi_hp0_awlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWCACHE" *)
    output wire [3:0]                  m_axi_hp0_awcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWPROT" *)
    output wire [2:0]                  m_axi_hp0_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWQOS" *)
    output wire [3:0]                  m_axi_hp0_awqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWVALID" *)
    output wire                        m_axi_hp0_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWREADY" *)
    input  wire                        m_axi_hp0_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 WID" *)
    output wire [AXI_ID_WIDTH-1:0]     m_axi_hp0_wid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 WDATA" *)
    output wire [63:0]                 m_axi_hp0_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 WSTRB" *)
    output wire [7:0]                  m_axi_hp0_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 WLAST" *)
    output wire                        m_axi_hp0_wlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 WVALID" *)
    output wire                        m_axi_hp0_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 WREADY" *)
    input  wire                        m_axi_hp0_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 BID" *)
    input  wire [AXI_ID_WIDTH-1:0]     m_axi_hp0_bid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 BRESP" *)
    input  wire [1:0]                  m_axi_hp0_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 BVALID" *)
    input  wire                        m_axi_hp0_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 BREADY" *)
    output wire                        m_axi_hp0_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARID" *)
    output wire [AXI_ID_WIDTH-1:0]     m_axi_hp0_arid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARADDR" *)
    output wire [31:0]                 m_axi_hp0_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARLEN" *)
    output wire [3:0]                  m_axi_hp0_arlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARSIZE" *)
    output wire [2:0]                  m_axi_hp0_arsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARBURST" *)
    output wire [1:0]                  m_axi_hp0_arburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARLOCK" *)
    output wire [1:0]                  m_axi_hp0_arlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARCACHE" *)
    output wire [3:0]                  m_axi_hp0_arcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARPROT" *)
    output wire [2:0]                  m_axi_hp0_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARQOS" *)
    output wire [3:0]                  m_axi_hp0_arqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARVALID" *)
    output wire                        m_axi_hp0_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARREADY" *)
    input  wire                        m_axi_hp0_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 RID" *)
    input  wire [AXI_ID_WIDTH-1:0]     m_axi_hp0_rid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 RDATA" *)
    input  wire [63:0]                 m_axi_hp0_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 RRESP" *)
    input  wire [1:0]                  m_axi_hp0_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 RLAST" *)
    input  wire                        m_axi_hp0_rlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 RVALID" *)
    input  wire                        m_axi_hp0_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 RREADY" *)
    output wire                        m_axi_hp0_rready,

    // ---- AXI3 master to S_AXI_HP1: writes the output image; read channels tied off ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWID" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axi_hp1, PROTOCOL AXI3, DATA_WIDTH 64, ADDR_WIDTH 32, ID_WIDTH 6, MAX_BURST_LENGTH 16, READ_WRITE_MODE READ_WRITE" *)
    output wire [AXI_ID_WIDTH-1:0]     m_axi_hp1_awid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWADDR" *)
    output wire [31:0]                 m_axi_hp1_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWLEN" *)
    output wire [3:0]                  m_axi_hp1_awlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWSIZE" *)
    output wire [2:0]                  m_axi_hp1_awsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWBURST" *)
    output wire [1:0]                  m_axi_hp1_awburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWLOCK" *)
    output wire [1:0]                  m_axi_hp1_awlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWCACHE" *)
    output wire [3:0]                  m_axi_hp1_awcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWPROT" *)
    output wire [2:0]                  m_axi_hp1_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWQOS" *)
    output wire [3:0]                  m_axi_hp1_awqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWVALID" *)
    output wire                        m_axi_hp1_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWREADY" *)
    input  wire                        m_axi_hp1_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 WID" *)
    output wire [AXI_ID_WIDTH-1:0]     m_axi_hp1_wid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 WDATA" *)
    output wire [63:0]                 m_axi_hp1_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 WSTRB" *)
    output wire [7:0]                  m_axi_hp1_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 WLAST" *)
    output wire                        m_axi_hp1_wlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 WVALID" *)
    output wire                        m_axi_hp1_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 WREADY" *)
    input  wire                        m_axi_hp1_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 BID" *)
    input  wire [AXI_ID_WIDTH-1:0]     m_axi_hp1_bid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 BRESP" *)
    input  wire [1:0]                  m_axi_hp1_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 BVALID" *)
    input  wire                        m_axi_hp1_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 BREADY" *)
    output wire                        m_axi_hp1_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARID" *)
    output wire [AXI_ID_WIDTH-1:0]     m_axi_hp1_arid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARADDR" *)
    output wire [31:0]                 m_axi_hp1_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARLEN" *)
    output wire [3:0]                  m_axi_hp1_arlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARSIZE" *)
    output wire [2:0]                  m_axi_hp1_arsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARBURST" *)
    output wire [1:0]                  m_axi_hp1_arburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARLOCK" *)
    output wire [1:0]                  m_axi_hp1_arlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARCACHE" *)
    output wire [3:0]                  m_axi_hp1_arcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARPROT" *)
    output wire [2:0]                  m_axi_hp1_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARQOS" *)
    output wire [3:0]                  m_axi_hp1_arqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARVALID" *)
    output wire                        m_axi_hp1_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARREADY" *)
    input  wire                        m_axi_hp1_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 RID" *)
    input  wire [AXI_ID_WIDTH-1:0]     m_axi_hp1_rid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 RDATA" *)
    input  wire [63:0]                 m_axi_hp1_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 RRESP" *)
    input  wire [1:0]                  m_axi_hp1_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 RLAST" *)
    input  wire                        m_axi_hp1_rlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 RVALID" *)
    input  wire                        m_axi_hp1_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 RREADY" *)
    output wire                        m_axi_hp1_rready
);

    localparam SLOT_BITS  = $clog2(NSLOT);
    localparam SLOT_WORDS = SPAN_MAX / 8;                // words per slot
    localparam WORD_BITS  = $clog2(SLOT_WORDS);
    localparam CNT_BITS   = WORD_BITS + 1;               // desc_n, fetch_words, cmd_words: 1..SLOT_WORDS
    localparam BUF_AW     = SLOT_BITS + WORD_BITS - 1;   // line_buf entry: slot, word >> 1
    localparam OUT_CNT_W  = $clog2(OUT_DEPTH + 1);
    localparam BLK_BITS   = 16;                          // block counters (spec section 5)

    // ---- unused channels of the HP ports (spec sections 10 and 11) ----
    localparam [2:0] AXI_SIZE_8 = 3'b011;
    localparam [1:0] AXI_INCR   = 2'b01;

    assign m_axi_hp0_awid    = {AXI_ID_WIDTH{1'b0}};
    assign m_axi_hp0_awaddr  = 32'd0;
    assign m_axi_hp0_awlen   = 4'd0;
    assign m_axi_hp0_awsize  = AXI_SIZE_8;
    assign m_axi_hp0_awburst = AXI_INCR;
    assign m_axi_hp0_awlock  = 2'b00;
    assign m_axi_hp0_awcache = 4'b0000;
    assign m_axi_hp0_awprot  = 3'b000;
    assign m_axi_hp0_awqos   = 4'b0000;
    assign m_axi_hp0_awvalid = 1'b0;
    assign m_axi_hp0_wid     = {AXI_ID_WIDTH{1'b0}};
    assign m_axi_hp0_wdata   = 64'd0;
    assign m_axi_hp0_wstrb   = 8'h00;
    assign m_axi_hp0_wlast   = 1'b0;
    assign m_axi_hp0_wvalid  = 1'b0;
    assign m_axi_hp0_bready  = 1'b1;

    assign m_axi_hp1_arid    = {AXI_ID_WIDTH{1'b0}};
    assign m_axi_hp1_araddr  = 32'd0;
    assign m_axi_hp1_arlen   = 4'd0;
    assign m_axi_hp1_arsize  = AXI_SIZE_8;
    assign m_axi_hp1_arburst = AXI_INCR;
    assign m_axi_hp1_arlock  = 2'b00;
    assign m_axi_hp1_arcache = 4'b0000;
    assign m_axi_hp1_arprot  = 3'b000;
    assign m_axi_hp1_arqos   = 4'b0000;
    assign m_axi_hp1_arvalid = 1'b0;
    assign m_axi_hp1_rready  = 1'b1;

    // ---- configuration and control ----
    wire [31:0]          cfg_src_addr, cfg_dst_addr;
    wire [SIZE_BITS-1:0] cfg_width, cfg_height, cfg_block_len;
    wire [31:0]          cfg_b11, cfg_b12, cfg_b13, cfg_b21, cfg_b22, cfg_b23;
    wire                 start_accept, busy, done_set, frame_start, bus_err;
    wire [31:0]          cnt_cycles, cnt_bytes_rd, cnt_bytes_wr, cnt_rd_stall, cnt_wr_stall;

    // ---- block_planner -> coord_gen / prefetch_ctrl ----
    wire                 desc_valid, desc_ready, desc_last;
    wire [SIZE_BITS-1:0] desc_u, desc_v0, desc_s_col;
    wire [CNT_BITS-1:0]  desc_n;
    wire [1:0]           desc_nrows;
    wire [SLOT_BITS-1:0] desc_slot_top, desc_slot_bot;
    wire                 fetch_valid, fetch_ready, fetch_top, fetch_bot;
    wire [SIZE_BITS-1:0] fetch_row_top, fetch_row_bot, fetch_s_col;
    wire [SLOT_BITS-1:0] fetch_slot_top, fetch_slot_bot;
    wire [CNT_BITS-1:0]  fetch_words;

    // ---- coord_gen -> pixel_fetch ----
    wire                 pix_valid, pix_ready, pix_first, pix_last, pix_frame_last;
    wire [31:0]          pix_X, pix_Y;
    wire [1:0]           pix_nrows;
    wire [SLOT_BITS-1:0] pix_slot_top, pix_slot_bot;
    wire [SIZE_BITS-1:0] pix_s_col;

    // ---- prefetch_ctrl <-> axi_rd_master, line_buf ----
    wire                 cmd_valid, cmd_ready;
    wire [31:0]          cmd_addr;
    wire [CNT_BITS-1:0]  cmd_words;
    wire [SLOT_BITS-1:0] cmd_slot;
    wire                 rd_valid, rd_cmd_last, rd_beat, rd_err;
    wire [63:0]          rd_data;
    wire [SLOT_BITS-1:0] rd_slot;
    wire [WORD_BITS-1:0] rd_word;
    wire                 buf_we, buf_wbank, buf_re;
    wire [BUF_AW-1:0]    buf_waddr, buf_raddr_te, buf_raddr_to, buf_raddr_be, buf_raddr_bo;
    wire [63:0]          buf_wdata, buf_rdata_te, buf_rdata_to, buf_rdata_be, buf_rdata_bo;
    wire [BLK_BITS-1:0]  blocks_ready;
    wire                 blk_done;

    // ---- pixel_fetch -> bilinear_interp -> out_fifo -> axi_wr_master ----
    wire                 ip_valid, ip_ready, ip_ok, ip_last, rd_stall;
    wire [15:0]          ip_xf, ip_yf;
    wire [7:0]           ip_r1, ip_r2, ip_r3, ip_r4;
    wire                 op_valid, op_ready, op_last, wr_stall;
    wire [7:0]           op_d;
    wire                 wq_valid, wq_ready;
    wire [63:0]          wq_data;
    wire [OUT_CNT_W-1:0] wq_count;
    wire                 wr_beat, wr_frame_done, wr_err;

`ifdef PATRM_FAULT_DONE_EARLY
    wire frame_done = op_valid & op_ready & op_last;
`else
    wire frame_done = wr_frame_done;
`endif

    axil_regs #(
        .VERSION(VERSION), .BUILD_TYPE(BUILD_TYPE), .MODES(MODES), .BLOCK_LEN_MAX(BLOCK_LEN_MAX)
    ) u_regs (
        .aclk(aclk), .aresetn(aresetn),
        .s_axil_awaddr(s_axi_awaddr), .s_axil_awprot(s_axi_awprot), .s_axil_awvalid(s_axi_awvalid),
        .s_axil_awready(s_axi_awready),
        .s_axil_wdata(s_axi_wdata), .s_axil_wstrb(s_axi_wstrb), .s_axil_wvalid(s_axi_wvalid),
        .s_axil_wready(s_axi_wready),
        .s_axil_bresp(s_axi_bresp), .s_axil_bvalid(s_axi_bvalid), .s_axil_bready(s_axi_bready),
        .s_axil_araddr(s_axi_araddr), .s_axil_arprot(s_axi_arprot), .s_axil_arvalid(s_axi_arvalid),
        .s_axil_arready(s_axi_arready),
        .s_axil_rdata(s_axi_rdata), .s_axil_rresp(s_axi_rresp), .s_axil_rvalid(s_axi_rvalid),
        .s_axil_rready(s_axi_rready),
        .cfg_mode(), .cfg_src_addr(cfg_src_addr), .cfg_dst_addr(cfg_dst_addr),
        .cfg_width(cfg_width), .cfg_height(cfg_height),
        .cfg_b11(cfg_b11), .cfg_b12(cfg_b12), .cfg_b13(cfg_b13), .cfg_b21(cfg_b21), .cfg_b22(cfg_b22), .cfg_b23(cfg_b23),
        .cfg_t_r_x(), .cfg_t_r_y(), .cfg_t_gr_x(), .cfg_t_gr_y(), .cfg_t_gb_x(), .cfg_t_gb_y(), .cfg_t_b_x(), .cfg_t_b_y(),
        .cfg_block_len(cfg_block_len),
        .start_accept(start_accept), .busy(busy), .done_set(done_set), .bus_err(bus_err),
        .cnt_cycles(cnt_cycles), .cnt_bytes_rd(cnt_bytes_rd), .cnt_bytes_wr(cnt_bytes_wr),
        .cnt_rd_stall(cnt_rd_stall), .cnt_wr_stall(cnt_wr_stall),
        .interrupt(interrupt));

    ctrl_fsm u_ctrl (
        .aclk(aclk), .aresetn(aresetn), .start_accept(start_accept), .busy(busy), .done_set(done_set),
        .frame_start(frame_start), .wr_frame_done(frame_done),
        .rd_beat(rd_beat), .wr_beat(wr_beat), .rd_stall(rd_stall), .wr_stall(wr_stall),
        .rd_err(rd_err), .wr_err(wr_err), .bus_err(bus_err),
        .cnt_cycles(cnt_cycles), .cnt_bytes_rd(cnt_bytes_rd), .cnt_bytes_wr(cnt_bytes_wr),
        .cnt_rd_stall(cnt_rd_stall), .cnt_wr_stall(cnt_wr_stall));

    block_planner #(
        .SIZE_BITS(SIZE_BITS), .CNT_BITS(CNT_BITS), .SLOT_BITS(SLOT_BITS), .SPAN_MAX(SPAN_MAX),
        .DESC_DEPTH(DESC_DEPTH), .FETCH_DEPTH(FETCH_DEPTH)
    ) u_planner (
        .aclk(aclk), .aresetn(aresetn), .frame_start(frame_start),
        .cfg_width(cfg_width), .cfg_height(cfg_height), .cfg_block_len(cfg_block_len),
        .cfg_b11(cfg_b11), .cfg_b12(cfg_b12), .cfg_b13(cfg_b13), .cfg_b21(cfg_b21), .cfg_b22(cfg_b22), .cfg_b23(cfg_b23),
        .desc_valid(desc_valid), .desc_ready(desc_ready), .desc_u(desc_u), .desc_v0(desc_v0), .desc_n(desc_n),
        .desc_nrows(desc_nrows), .desc_slot_top(desc_slot_top), .desc_slot_bot(desc_slot_bot),
        .desc_s_col(desc_s_col), .desc_last(desc_last),
        .fetch_valid(fetch_valid), .fetch_ready(fetch_ready), .fetch_row_top(fetch_row_top),
        .fetch_row_bot(fetch_row_bot), .fetch_slot_top(fetch_slot_top), .fetch_slot_bot(fetch_slot_bot),
        .fetch_top(fetch_top), .fetch_bot(fetch_bot), .fetch_s_col(fetch_s_col), .fetch_words(fetch_words));

    coord_gen #(
        .SIZE_BITS(SIZE_BITS), .CNT_BITS(CNT_BITS), .SLOT_BITS(SLOT_BITS)
    ) u_coord (
        .aclk(aclk), .aresetn(aresetn), .frame_start(frame_start),
        .cfg_b11(cfg_b11), .cfg_b12(cfg_b12), .cfg_b13(cfg_b13), .cfg_b21(cfg_b21), .cfg_b22(cfg_b22), .cfg_b23(cfg_b23),
        .desc_valid(desc_valid), .desc_ready(desc_ready), .desc_u(desc_u), .desc_v0(desc_v0), .desc_n(desc_n),
        .desc_nrows(desc_nrows), .desc_slot_top(desc_slot_top), .desc_slot_bot(desc_slot_bot),
        .desc_s_col(desc_s_col), .desc_last(desc_last),
        .pix_valid(pix_valid), .pix_ready(pix_ready), .pix_X(pix_X), .pix_Y(pix_Y), .pix_first(pix_first),
        .pix_last(pix_last), .pix_nrows(pix_nrows), .pix_slot_top(pix_slot_top), .pix_slot_bot(pix_slot_bot),
        .pix_s_col(pix_s_col), .pix_frame_last(pix_frame_last));

    prefetch_ctrl #(
        .SIZE_BITS(SIZE_BITS), .CNT_BITS(CNT_BITS), .SLOT_BITS(SLOT_BITS), .WORD_BITS(WORD_BITS), .BLK_BITS(BLK_BITS)
    ) u_prefetch (
        .aclk(aclk), .aresetn(aresetn), .frame_start(frame_start),
        .cfg_src_addr(cfg_src_addr), .cfg_width(cfg_width),
        .fetch_valid(fetch_valid), .fetch_ready(fetch_ready), .fetch_row_top(fetch_row_top),
        .fetch_row_bot(fetch_row_bot), .fetch_slot_top(fetch_slot_top), .fetch_slot_bot(fetch_slot_bot),
        .fetch_top(fetch_top), .fetch_bot(fetch_bot), .fetch_s_col(fetch_s_col), .fetch_words(fetch_words),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_addr(cmd_addr), .cmd_words(cmd_words), .cmd_slot(cmd_slot),
        .rd_valid(rd_valid), .rd_data(rd_data), .rd_slot(rd_slot), .rd_word(rd_word), .rd_cmd_last(rd_cmd_last),
        .buf_we(buf_we), .buf_wbank(buf_wbank), .buf_waddr(buf_waddr), .buf_wdata(buf_wdata),
        .blocks_ready(blocks_ready), .blk_done(blk_done));

    axi_rd_master #(
        .RD_OUTSTANDING(RD_OUTSTANDING), .ID_W(AXI_ID_WIDTH), .SLOT_W(SLOT_BITS), .WORD_W(WORD_BITS), .WORDS_W(CNT_BITS)
    ) u_rd (
        .aclk(aclk), .aresetn(aresetn),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_addr(cmd_addr), .cmd_words(cmd_words), .cmd_slot(cmd_slot),
        .m_axi_hp0_arid(m_axi_hp0_arid), .m_axi_hp0_araddr(m_axi_hp0_araddr), .m_axi_hp0_arlen(m_axi_hp0_arlen),
        .m_axi_hp0_arsize(m_axi_hp0_arsize), .m_axi_hp0_arburst(m_axi_hp0_arburst),
        .m_axi_hp0_arlock(m_axi_hp0_arlock), .m_axi_hp0_arcache(m_axi_hp0_arcache),
        .m_axi_hp0_arprot(m_axi_hp0_arprot), .m_axi_hp0_arqos(m_axi_hp0_arqos),
        .m_axi_hp0_arvalid(m_axi_hp0_arvalid), .m_axi_hp0_arready(m_axi_hp0_arready),
        .m_axi_hp0_rid(m_axi_hp0_rid), .m_axi_hp0_rdata(m_axi_hp0_rdata), .m_axi_hp0_rresp(m_axi_hp0_rresp),
        .m_axi_hp0_rlast(m_axi_hp0_rlast), .m_axi_hp0_rvalid(m_axi_hp0_rvalid), .m_axi_hp0_rready(m_axi_hp0_rready),
        .rd_valid(rd_valid), .rd_data(rd_data), .rd_slot(rd_slot), .rd_word(rd_word), .rd_cmd_last(rd_cmd_last),
        .rd_beat(rd_beat), .rd_err(rd_err));

    line_buf #(
        .NSLOT(NSLOT), .SLOT_WORDS(SLOT_WORDS), .AW(BUF_AW)
    ) u_buf (
        .aclk(aclk), .we(buf_we), .wbank(buf_wbank), .waddr(buf_waddr), .wdata(buf_wdata),
        .re(buf_re), .raddr_te(buf_raddr_te), .raddr_to(buf_raddr_to), .raddr_be(buf_raddr_be),
        .raddr_bo(buf_raddr_bo), .rdata_te(buf_rdata_te), .rdata_to(buf_rdata_to), .rdata_be(buf_rdata_be),
        .rdata_bo(buf_rdata_bo));

    pixel_fetch #(
        .SIZE_BITS(SIZE_BITS), .SLOT_BITS(SLOT_BITS), .WORD_BITS(WORD_BITS), .BLK_BITS(BLK_BITS)
    ) u_fetch (
        .aclk(aclk), .aresetn(aresetn), .frame_start(frame_start), .cfg_width(cfg_width), .cfg_height(cfg_height),
        .pix_valid(pix_valid), .pix_ready(pix_ready), .pix_X(pix_X), .pix_Y(pix_Y), .pix_first(pix_first),
        .pix_last(pix_last), .pix_nrows(pix_nrows), .pix_slot_top(pix_slot_top), .pix_slot_bot(pix_slot_bot),
        .pix_s_col(pix_s_col), .pix_frame_last(pix_frame_last),
        .blocks_ready(blocks_ready), .blk_done(blk_done),
        .buf_re(buf_re), .buf_raddr_te(buf_raddr_te), .buf_raddr_to(buf_raddr_to), .buf_raddr_be(buf_raddr_be),
        .buf_raddr_bo(buf_raddr_bo), .buf_rdata_te(buf_rdata_te), .buf_rdata_to(buf_rdata_to),
        .buf_rdata_be(buf_rdata_be), .buf_rdata_bo(buf_rdata_bo),
        .ip_valid(ip_valid), .ip_ready(ip_ready), .ip_xf(ip_xf), .ip_yf(ip_yf), .ip_r1(ip_r1), .ip_r2(ip_r2),
        .ip_r3(ip_r3), .ip_r4(ip_r4), .ip_ok(ip_ok), .ip_last(ip_last), .rd_stall(rd_stall));

    bilinear_interp u_interp (
        .aclk(aclk), .aresetn(aresetn),
        .ip_valid(ip_valid), .ip_ready(ip_ready), .ip_xf(ip_xf), .ip_yf(ip_yf), .ip_r1(ip_r1), .ip_r2(ip_r2),
        .ip_r3(ip_r3), .ip_r4(ip_r4), .ip_ok(ip_ok), .ip_last(ip_last),
        .op_valid(op_valid), .op_ready(op_ready), .op_d(op_d), .op_last(op_last), .wr_stall(wr_stall));

    out_fifo #(
        .OUT_DEPTH(OUT_DEPTH), .CNT_W(OUT_CNT_W)
    ) u_ofifo (
        .aclk(aclk), .aresetn(aresetn), .frame_start(frame_start),
        .op_valid(op_valid), .op_ready(op_ready), .op_d(op_d), .op_last(op_last),
        .wq_valid(wq_valid), .wq_ready(wq_ready), .wq_data(wq_data), .wq_count(wq_count));

    axi_wr_master #(
        .WR_OUTSTANDING(WR_OUTSTANDING), .ID_W(AXI_ID_WIDTH), .SIZE_BITS(SIZE_BITS), .CNT_W(OUT_CNT_W)
    ) u_wr (
        .aclk(aclk), .aresetn(aresetn), .frame_start(frame_start),
        .cfg_dst_addr(cfg_dst_addr), .cfg_width(cfg_width), .cfg_height(cfg_height),
        .wq_valid(wq_valid), .wq_ready(wq_ready), .wq_data(wq_data), .wq_count(wq_count),
        .m_axi_hp1_awid(m_axi_hp1_awid), .m_axi_hp1_awaddr(m_axi_hp1_awaddr), .m_axi_hp1_awlen(m_axi_hp1_awlen),
        .m_axi_hp1_awsize(m_axi_hp1_awsize), .m_axi_hp1_awburst(m_axi_hp1_awburst),
        .m_axi_hp1_awlock(m_axi_hp1_awlock), .m_axi_hp1_awcache(m_axi_hp1_awcache),
        .m_axi_hp1_awprot(m_axi_hp1_awprot), .m_axi_hp1_awqos(m_axi_hp1_awqos),
        .m_axi_hp1_awvalid(m_axi_hp1_awvalid), .m_axi_hp1_awready(m_axi_hp1_awready),
        .m_axi_hp1_wid(m_axi_hp1_wid), .m_axi_hp1_wdata(m_axi_hp1_wdata), .m_axi_hp1_wstrb(m_axi_hp1_wstrb),
        .m_axi_hp1_wlast(m_axi_hp1_wlast), .m_axi_hp1_wvalid(m_axi_hp1_wvalid), .m_axi_hp1_wready(m_axi_hp1_wready),
        .m_axi_hp1_bid(m_axi_hp1_bid), .m_axi_hp1_bresp(m_axi_hp1_bresp), .m_axi_hp1_bvalid(m_axi_hp1_bvalid),
        .m_axi_hp1_bready(m_axi_hp1_bready),
        .wr_beat(wr_beat), .wr_frame_done(wr_frame_done), .wr_err(wr_err));

endmodule
