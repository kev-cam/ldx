// tb_cfu.v — drive ldx_cfu directly, verify each of the 8 functions against a
// software model. Pure combinational; no clock-domain games.

`timescale 1ns/1ps

module tb_cfu;
    reg         clk = 0;
    reg         reset = 1;
    reg         cmd_valid;
    wire        cmd_ready;
    reg  [2:0]  fid;
    reg  [31:0] in0, in1;
    wire        rsp_valid;
    reg         rsp_ready;
    wire [31:0] rsp;

    ldx_cfu cfu (
        .clk(clk), .reset(reset),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_function_id(fid),
        .cmd_inputs_0(in0), .cmd_inputs_1(in1),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready),
        .rsp_outputs_0(rsp)
    );

    always #5 clk = ~clk;

    function automatic [31:0] sw_popcount(input [31:0] v);
        integer i; begin
            sw_popcount = 0;
            for (i = 0; i < 32; i = i + 1) sw_popcount = sw_popcount + v[i];
        end
    endfunction

    function automatic [31:0] sw_parity(input [31:0] v);
        sw_parity = ^v;
    endfunction

    function automatic [31:0] sw_onehot(input [31:0] v);
        sw_onehot = (sw_popcount(v) == 32'd1);
    endfunction

    function automatic [31:0] sw_onehot0(input [31:0] v);
        sw_onehot0 = (sw_popcount(v) <= 32'd1);
    endfunction

    function automatic [31:0] sw_bswap(input [31:0] v);
        sw_bswap = {v[7:0], v[15:8], v[23:16], v[31:24]};
    endfunction

    function automatic [31:0] sw_bitrev8(input [31:0] v);
        integer i; begin
            sw_bitrev8 = 0;
            for (i = 0; i < 8; i = i + 1)
                sw_bitrev8[7-i] = v[i];
            // upper 24 bits zero (Verilator's vl_bitreverse8 contract: byte-only)
        end
    endfunction

    function automatic [31:0] sw_div(input [31:0] a, input [31:0] b);
        sw_div = (b == 0) ? 32'd0 : a / b;
    endfunction

    function automatic [31:0] sw_mod(input [31:0] a, input [31:0] b);
        sw_mod = (b == 0) ? 32'd0 : a % b;
    endfunction

    integer fails = 0;
    integer i;
    reg [31:0] av, bv;

    task one(input [2:0] f, input [31:0] a, input [31:0] b, input [31:0] expected);
        begin
            @(negedge clk);
            fid = f; in0 = a; in1 = b; cmd_valid = 1; rsp_ready = 1;
            @(posedge clk);
            // CFU is combinational (cmd_ready = rsp_ready, rsp_valid = cmd_valid)
            if (rsp !== expected) begin
                $display("FAIL fid=%0d in0=%h in1=%h got=%h want=%h",
                         f, a, b, rsp, expected);
                fails = fails + 1;
            end else begin
                $display("PASS fid=%0d in0=%h in1=%h got=%h",
                         f, a, b, rsp);
            end
            cmd_valid = 0;
        end
    endtask

    initial begin
        $dumpfile("tb_cfu.vcd");
        $dumpvars(0, tb_cfu);
        cmd_valid = 0; rsp_ready = 0; fid = 0; in0 = 0; in1 = 0;
        fails = 0;
        #20 reset = 0;

        // ---- Deterministic spot checks ----
        one(3'd0, 32'h00000000, 0, sw_popcount(32'h00000000));
        one(3'd0, 32'hFFFFFFFF, 0, sw_popcount(32'hFFFFFFFF));
        one(3'd0, 32'hDEADBEEF, 0, sw_popcount(32'hDEADBEEF));

        one(3'd1, 32'h00000000, 0, sw_parity(32'h00000000));
        one(3'd1, 32'h00000001, 0, sw_parity(32'h00000001));
        one(3'd1, 32'hDEADBEEF, 0, sw_parity(32'hDEADBEEF));

        one(3'd2, 32'h00000000, 0, sw_onehot(32'h00000000));
        one(3'd2, 32'h00000001, 0, sw_onehot(32'h00000001));
        one(3'd2, 32'h00000003, 0, sw_onehot(32'h00000003));

        one(3'd3, 32'h00000000, 0, sw_onehot0(32'h00000000));
        one(3'd3, 32'h00000010, 0, sw_onehot0(32'h00000010));
        one(3'd3, 32'h00000003, 0, sw_onehot0(32'h00000003));

        one(3'd4, 32'h11223344, 0, sw_bswap(32'h11223344));
        one(3'd4, 32'h0000FF00, 0, sw_bswap(32'h0000FF00));

        one(3'd5, 32'h00000001, 0, sw_bitrev8(32'h00000001));
        one(3'd5, 32'h00000080, 0, sw_bitrev8(32'h00000080));
        one(3'd5, 32'h000000A5, 0, sw_bitrev8(32'h000000A5));

        one(3'd6, 32'd100, 32'd7, sw_div(32'd100, 32'd7));
        one(3'd6, 32'd42, 32'd0, sw_div(32'd42, 32'd0));   // safe div by zero
        one(3'd6, 32'd0, 32'd5, sw_div(32'd0, 32'd5));

        one(3'd7, 32'd100, 32'd7, sw_mod(32'd100, 32'd7));
        one(3'd7, 32'd42, 32'd0, sw_mod(32'd42, 32'd0));
        one(3'd7, 32'h12345678, 32'h100, sw_mod(32'h12345678, 32'h100));

        // ---- Randomised sweep ----
        for (i = 0; i < 64; i = i + 1) begin
            av = $random; bv = $random;
            one(3'd0, av, 0, sw_popcount(av));
            one(3'd1, av, 0, sw_parity(av));
            one(3'd2, av, 0, sw_onehot(av));
            one(3'd3, av, 0, sw_onehot0(av));
            one(3'd4, av, 0, sw_bswap(av));
            one(3'd5, av, 0, sw_bitrev8(av));
            one(3'd6, av, bv, sw_div(av, bv));
            one(3'd7, av, bv, sw_mod(av, bv));
        end

        if (fails == 0) $display("ALL PASS");
        else            $display("FAIL: %0d mismatches", fails);
        $finish;
    end

    initial begin #500000; $display("TIMEOUT"); $finish; end

endmodule
