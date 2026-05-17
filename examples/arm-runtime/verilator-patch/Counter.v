// Counter.v — 8-bit counter; eval_nba calls nba_sequent on every clock edge,
// so patching nba_sequent's entry lets us interpose on every increment.
module Counter (
    input  wire        clk,
    input  wire        rst,
    output reg  [7:0]  cnt
);
    always @(posedge clk)
        if (rst) cnt <= 8'd0;
        else     cnt <= cnt + 8'd1;
endmodule
