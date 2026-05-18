// Crc32.v — straightforward LFSR-style CRC-32 (IEEE 802.3 polynomial).
// One byte ingested per cycle; ~8 inner XOR-shifts.
module Crc32 (
    input  wire        clk,
    input  wire        rst,
    input  wire        en,
    input  wire [7:0]  data,
    output reg  [31:0] crc
);
    function [31:0] crc32_step;
        input [31:0] state;
        input [7:0]  byte_in;
        integer i;
        reg [31:0] s;
        begin
            s = state ^ {24'b0, byte_in};
            for (i = 0; i < 8; i = i + 1)
                s = (s >> 1) ^ (32'hEDB88320 & {32{s[0]}});
            crc32_step = s;
        end
    endfunction

    always @(posedge clk) begin
        if (rst)     crc <= 32'hFFFFFFFF;
        else if (en) crc <= crc32_step(crc, data);
    end
endmodule
