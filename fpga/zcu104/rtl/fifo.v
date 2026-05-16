// fifo.v — synchronous FIFO, parameterizable WIDTH × DEPTH.
//   Push-side: push_valid + push_ready, push_data
//   Pop-side:  pop_valid  + pop_ready,  pop_data
// DEPTH must be a power of 2. Distributed-RAM friendly for small depths.

`timescale 1ns/1ps

module fifo #(
    parameter WIDTH = 32,
    parameter DEPTH = 8
) (
    input  wire                clk,
    input  wire                reset,

    input  wire                push_valid,
    output wire                push_ready,
    input  wire [WIDTH-1:0]    push_data,

    output wire                pop_valid,
    input  wire                pop_ready,
    output wire [WIDTH-1:0]    pop_data,

    output wire [$clog2(DEPTH+1)-1:0] count
);
    localparam AW = $clog2(DEPTH);

    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [AW:0]      wptr, rptr;   // one extra bit for full/empty distinction

    wire [AW-1:0]   waddr = wptr[AW-1:0];
    wire [AW-1:0]   raddr = rptr[AW-1:0];
    wire full  = (wptr[AW] != rptr[AW]) && (wptr[AW-1:0] == rptr[AW-1:0]);
    wire empty = (wptr == rptr);

    assign push_ready = !full;
    assign pop_valid  = !empty;
    assign pop_data   = mem[raddr];
    assign count      = wptr - rptr;

    always @(posedge clk) begin
        if (reset) begin
            wptr <= 0;
            rptr <= 0;
        end else begin
            if (push_valid && push_ready) begin
                mem[waddr] <= push_data;
                wptr       <= wptr + 1'b1;
            end
            if (pop_valid && pop_ready) begin
                rptr <= rptr + 1'b1;
            end
        end
    end
endmodule
