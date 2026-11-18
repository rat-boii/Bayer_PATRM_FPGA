// ctrl_fsm: frame control and performance counters, spec/interface.md sections 2 and 13.
//
// IDLE -> (start_accept) RUN -> (wr_frame_done) IDLE.
// - start_accept in cycle S: counters and the bus-error flag are cleared at the end of S; busy and the one-cycle
//   frame_start are 1 from S+1. The data path latches its configuration at frame_start; axil_regs keeps the
//   configuration registers locked while busy, so they are stable from the start check to the end of the frame.
// - wr_frame_done (axi_wr_master: last B response of the frame received) in cycle D: done_set = 1 in D and busy falls
//   at the end of D, so all output data are in DDR when STATUS.DONE is set.
// - Counters count while busy = 1 and hold their value afterwards (32-bit, wrapping):
//   CYCLES = cycles with busy = 1, BYTES_RD / BYTES_WR = 8 x rd_beat / wr_beat, RD_STALL / WR_STALL = stall cycles.
// - bus_err = an AXI error response (rd_err, wr_err) was seen in this frame, including in the current cycle. axil_regs
//   samples it at done_set (Q1: the frame completes, STATUS.ERROR with code BUS_ERROR).
`timescale 1ns/1ps
module ctrl_fsm #(
    parameter CNT_W     = 32,                            // counter width (regs.json)
    parameter BEAT_BYTES = 8                             // bytes per HP beat (64-bit ports)
) (
    input  wire             aclk,
    input  wire             aresetn,                     // synchronous, active low
    input  wire             start_accept,                // from axil_regs
    output reg              busy,                        // to axil_regs (STATUS.BUSY)
    output wire             done_set,                    // to axil_regs: frame finished
    output reg              frame_start,                 // to every data-path module, first busy cycle
    input  wire             wr_frame_done,               // last write response of the frame received
    input  wire             rd_beat,                     // axi_rd_master: one R beat accepted
    input  wire             wr_beat,                     // axi_wr_master: one W beat accepted
    input  wire             rd_stall,                    // pixel_fetch (section 13)
    input  wire             wr_stall,                    // bilinear_interp (section 13)
    input  wire             rd_err,                      // axi_rd_master: RRESP != OKAY on this beat
    input  wire             wr_err,                      // axi_wr_master: BRESP != OKAY on this response
    output wire             bus_err,                     // to axil_regs, sampled at done_set
    output reg  [CNT_W-1:0] cnt_cycles,
    output reg  [CNT_W-1:0] cnt_bytes_rd,
    output reg  [CNT_W-1:0] cnt_bytes_wr,
    output reg  [CNT_W-1:0] cnt_rd_stall,
    output reg  [CNT_W-1:0] cnt_wr_stall
);

    localparam [CNT_W-1:0] BEAT_INC = BEAT_BYTES;
    localparam [CNT_W-1:0] ONE      = 1;

    reg err_seen;

    assign done_set = busy & wr_frame_done;
    assign bus_err  = err_seen | rd_err | wr_err;

    always @(posedge aclk) begin
        if (!aresetn) begin
            busy         <= 1'b0;
            frame_start  <= 1'b0;
            err_seen     <= 1'b0;
            cnt_cycles   <= {CNT_W{1'b0}};
            cnt_bytes_rd <= {CNT_W{1'b0}};
            cnt_bytes_wr <= {CNT_W{1'b0}};
            cnt_rd_stall <= {CNT_W{1'b0}};
            cnt_wr_stall <= {CNT_W{1'b0}};
        end else begin
            frame_start <= start_accept;
            if (start_accept) begin
                busy         <= 1'b1;
                err_seen     <= 1'b0;
                cnt_cycles   <= {CNT_W{1'b0}};
                cnt_bytes_rd <= {CNT_W{1'b0}};
                cnt_bytes_wr <= {CNT_W{1'b0}};
                cnt_rd_stall <= {CNT_W{1'b0}};
                cnt_wr_stall <= {CNT_W{1'b0}};
            end else if (busy) begin
                cnt_cycles <= cnt_cycles + ONE;
                if (rd_beat)  cnt_bytes_rd <= cnt_bytes_rd + BEAT_INC;
                if (wr_beat)  cnt_bytes_wr <= cnt_bytes_wr + BEAT_INC;
                if (rd_stall) cnt_rd_stall <= cnt_rd_stall + ONE;
                if (wr_stall) cnt_wr_stall <= cnt_wr_stall + ONE;
                if (rd_err | wr_err) err_seen <= 1'b1;
                if (wr_frame_done) busy <= 1'b0;
            end
        end
    end

endmodule
