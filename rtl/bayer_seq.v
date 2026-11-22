// bayer_seq: job -> pass sequencer, spec/interface.md section 18.2 (step 5.2).
//
// One accepted job runs one pass (gray, MODE 0) or four plane passes R, Gr, Gb, B (Bayer Option A, MODE 1).
// Every data-path module latches its frame configuration at frame_start; this module gives them the per-pass values:
//
//   value         gray                Option A pass k (k = 0 R, 1 Gr, 2 Gb, 3 B; o_row = k[1], o_col = k[0])
//   pass_b13/b23  B13 / B23           T_<plane>_X / T_<plane>_Y (D12, registers; B13 / B23 unused)
//   pass_width    W                   W / 2   (plane grid: scan, D1, clamps)
//   pass_height   H                   H / 2
//   pass_o_row    0                   k[1]
//   pass_o_col    0                   k[0]
//   pass_stride2  0                   1       (memory row 2x + o_row, column 2y + o_col)
//   pass_wstrb    8'hFF               8'h55 << o_col
//
// Timing. start_accept in cycle S: pass 0 values and frame_start = 1 in S+1 (the cycle ctrl_fsm's frame_start had
// before step 5.2, so gray timing is unchanged). pass_done (wr_frame_done of the pass) in cycle D:
//   - last pass (gray, or Option A pass 3): job_done = 1 in D (combinational, so done_set comes in the same cycle
//     as before: CYCLES unchanged in gray);
//   - otherwise: next pass values and frame_start = 1 in D+1.
// All pass_* outputs are registers that change only together with a frame_start pulse, so they are stable for
// the whole pass. CTRL.MODE is sampled at start_accept (axil_regs updates it at the end of the START write cycle,
// one cycle before start_accept).
// MODES bit 1 = Option A built. With MODES[1] = 0 every Option A value is a constant and synthesis removes it.
module bayer_seq #(
    parameter MODES     = 1,                     // bit n = CTRL.MODE n supported (spec/regs.json BUILD_ID.MODES)
    parameter SIZE_BITS = 13                     // WIDTH / HEIGHT fields
) (
    input  wire                 aclk,
    input  wire                 aresetn,         // synchronous, active low
    input  wire                 start_accept,    // from axil_regs: a job was accepted
    input  wire [1:0]           cfg_mode,        // CTRL.MODE
    input  wire [SIZE_BITS-1:0] cfg_width,       // W (full mosaic)
    input  wire [SIZE_BITS-1:0] cfg_height,      // H
    input  wire [31:0]          cfg_b13,
    input  wire [31:0]          cfg_b23,
    input  wire [31:0]          cfg_t_r_x,  cfg_t_r_y,
    input  wire [31:0]          cfg_t_gr_x, cfg_t_gr_y,
    input  wire [31:0]          cfg_t_gb_x, cfg_t_gb_y,
    input  wire [31:0]          cfg_t_b_x,  cfg_t_b_y,
    input  wire                 pass_done,       // wr_frame_done: the current pass is complete in DDR
    output reg                  frame_start,     // one pulse per pass, to every data-path module
    output wire                 job_done,        // last pass complete (to ctrl_fsm, done_set)
    output reg  [1:0]           pass_index,
    output reg  [31:0]          pass_b13,
    output reg  [31:0]          pass_b23,
    output reg  [SIZE_BITS-1:0] pass_width,
    output reg  [SIZE_BITS-1:0] pass_height,
    output reg                  pass_o_row,
    output reg                  pass_o_col,
    output reg                  pass_stride2,
    output reg  [7:0]           pass_wstrb
);

    localparam       HAS_A  = (MODES >> 1) & 1;
    localparam [1:0] MODE_A = 2'd1;

    reg running;                                 // a job is in progress (frame_start .. job_done)
    reg bayer;                                   // the job is Option A

    wire last = !bayer || (pass_index == 2'd3);
    assign job_done = running && pass_done && last;

    // values of pass k for a job with Option A flag a (registered by the caller)
    wire        a_new  = (HAS_A != 0) && (cfg_mode == MODE_A);       // at start_accept
    wire [1:0]  k_next = pass_index + 2'd1;                          // after pass_done

    task load_pass;
        input       a;
        input [1:0] k;
        begin
            pass_index   <= k;
            pass_o_row   <= a & k[1];
            pass_o_col   <= a & k[0];
            pass_stride2 <= a;
            pass_wstrb   <= !a ? 8'hFF : (k[0] ? 8'hAA : 8'h55);
            pass_width   <= a ? {1'b0, cfg_width[SIZE_BITS-1:1]}  : cfg_width;
            pass_height  <= a ? {1'b0, cfg_height[SIZE_BITS-1:1]} : cfg_height;
            case ({a, k})
                3'b100:  begin pass_b13 <= cfg_t_r_x;  pass_b23 <= cfg_t_r_y;  end
                3'b101:  begin pass_b13 <= cfg_t_gr_x; pass_b23 <= cfg_t_gr_y; end
                3'b110:  begin pass_b13 <= cfg_t_gb_x; pass_b23 <= cfg_t_gb_y; end
                3'b111:  begin pass_b13 <= cfg_t_b_x;  pass_b23 <= cfg_t_b_y;  end
                default: begin pass_b13 <= cfg_b13;    pass_b23 <= cfg_b23;    end
            endcase
        end
    endtask

    always @(posedge aclk) begin
        if (!aresetn) begin
            frame_start  <= 1'b0;
            running      <= 1'b0;
            bayer        <= 1'b0;
            pass_index   <= 2'd0;
            pass_b13     <= 32'd0;
            pass_b23     <= 32'd0;
            pass_width   <= {SIZE_BITS{1'b0}};
            pass_height  <= {SIZE_BITS{1'b0}};
            pass_o_row   <= 1'b0;
            pass_o_col   <= 1'b0;
            pass_stride2 <= 1'b0;
            pass_wstrb   <= 8'hFF;
        end else begin
            frame_start <= 1'b0;
            if (start_accept) begin
                running     <= 1'b1;
                bayer       <= a_new;
                frame_start <= 1'b1;
                load_pass(a_new, 2'd0);
            end else if (running && pass_done) begin
                if (last) begin
                    running <= 1'b0;
                end else begin
                    frame_start <= 1'b1;
                    load_pass(bayer, k_next);
                end
            end
        end
    end

endmodule
