// counter4: free-running up counter with enable (toolchain smoke test, step 0.1).
// Synchronous active-low reset, wraps from 2^WIDTH-1 to 0.
module counter4 #(
    parameter WIDTH = 4
) (
    input  wire             clk,
    input  wire             aresetn,
    input  wire             en,
    output reg  [WIDTH-1:0] count
);

    always @(posedge clk) begin
        if (!aresetn)
            count <= {WIDTH{1'b0}};
        else if (en)
            count <= count + 1'b1;
    end

endmodule
