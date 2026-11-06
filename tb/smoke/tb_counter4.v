// Self-checking testbench for counter4 (step 0.1 smoke test).
// Checks reset, counting, hold when en = 0, and wrap 15 -> 0.
// Prints exactly one final line: "TEST PASS" or "TEST FAIL: <reason>".
// Define BREAK_EXPECTED to corrupt the reference model on purpose (proves sim.py
// reports failure).
`timescale 1ns/1ps
module tb_counter4;

    localparam WIDTH    = 4;
    localparam N_CYCLES = 40;        // > 2 wraps
    localparam CLK_HALF = 5;         // 100 MHz

    reg              clk = 1'b0;
    reg              aresetn = 1'b0;
    reg              en = 1'b0;
    wire [WIDTH-1:0] count;

    reg  [WIDTH-1:0] expected;
    integer          cycle;
    integer          errors;
    integer          first_cycle;
    reg  [WIDTH-1:0] first_got;
    reg  [WIDTH-1:0] first_exp;
    integer          wraps;

    counter4 #(.WIDTH(WIDTH)) dut (
        .clk(clk), .aresetn(aresetn), .en(en), .count(count)
    );

    always #CLK_HALF clk = ~clk;

    task check;
        begin
            if (count !== expected) begin
                if (errors == 0) begin
                    first_cycle = cycle;
                    first_got   = count;
                    first_exp   = expected;
                end
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        wraps  = 0;
        expected = {WIDTH{1'b0}};

        // Reset for 3 cycles.
        repeat (3) @(posedge clk);
        #1 cycle = -1; check;
        aresetn = 1'b1;

        // Count with a hold window (en = 0) in cycles 10..13.
        for (cycle = 0; cycle < N_CYCLES; cycle = cycle + 1) begin
            en = !(cycle >= 10 && cycle < 14);
            @(posedge clk);
            if (en) begin
                if (expected == {WIDTH{1'b1}}) wraps = wraps + 1;
                expected = expected + 1'b1;
`ifdef BREAK_EXPECTED
                if (cycle == 20) expected = expected + 1'b1;
`endif
            end
            #1 check;
        end

        if (errors != 0)
            $display("TEST FAIL: %0d mismatches, first at cycle %0d (got %0d, expected %0d)",
                     errors, first_cycle, first_got, first_exp);
        else if (wraps < 2)
            $display("TEST FAIL: counter wrapped only %0d times, expected >= 2", wraps);
        else
            $display("TEST PASS");
        $finish;
    end

    // Watchdog: a hang must still give one final line.
    initial begin
        #100000;
        $display("TEST FAIL: timeout");
        $finish;
    end

endmodule
