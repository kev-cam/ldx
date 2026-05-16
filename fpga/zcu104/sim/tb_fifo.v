// tb_fifo.v — random push/pop, check the FIFO doesn't drop or duplicate.

`timescale 1ns/1ps

module tb_fifo;
    localparam W = 32;
    localparam D = 8;

    reg clk = 0; always #5 clk = ~clk;
    reg reset = 1;

    reg              push_valid;
    wire             push_ready;
    reg  [W-1:0]     push_data;
    reg              pop_ready;
    wire             pop_valid;
    wire [W-1:0]     pop_data;
    wire [$clog2(D+1)-1:0] count;

    fifo #(.WIDTH(W), .DEPTH(D)) dut (
        .clk(clk), .reset(reset),
        .push_valid(push_valid), .push_ready(push_ready), .push_data(push_data),
        .pop_valid(pop_valid),   .pop_ready(pop_ready),   .pop_data(pop_data),
        .count(count)
    );

    // Reference queue: track everything we successfully pushed
    integer fails;
    integer pushes, pops;
    reg [W-1:0] expected_queue [0:1023];
    integer head, tail;

    task push(input [W-1:0] v);
        begin
            @(negedge clk);
            push_data  = v;
            push_valid = 1;
            @(posedge clk);
            if (push_ready) begin
                expected_queue[tail] = v;
                tail = tail + 1;
                pushes = pushes + 1;
            end
            @(negedge clk);
            push_valid = 0;
        end
    endtask

    task pop_one;
        begin
            @(negedge clk);
            pop_ready = 1;
            @(posedge clk);
            if (pop_valid) begin
                if (pop_data !== expected_queue[head]) begin
                    $display("FAIL [%0d] got=%h want=%h", pops, pop_data, expected_queue[head]);
                    fails = fails + 1;
                end
                head = head + 1;
                pops = pops + 1;
            end
            @(negedge clk);
            pop_ready = 0;
        end
    endtask

    integer i;
    reg [31:0] s;
    initial begin
        $dumpfile("tb_fifo.vcd");
        $dumpvars(0, tb_fifo);
        push_valid = 0; pop_ready = 0; push_data = 0;
        fails = 0; pushes = 0; pops = 0;
        head = 0; tail = 0;
        repeat (4) @(posedge clk);
        reset = 0;
        @(posedge clk);

        // Fill to full
        for (i = 0; i < D; i = i + 1) push(32'h1000 + i);
        if (push_ready !== 1'b0) begin $display("FAIL: push_ready should be 0 at full"); fails = fails + 1; end

        // Try to overfill — should not accept
        push(32'hDEADBEEF);
        if (pushes != D) begin $display("FAIL: overfill push accepted"); fails = fails + 1; end

        // Drain
        for (i = 0; i < D; i = i + 1) pop_one();
        if (pop_valid !== 1'b0) begin $display("FAIL: pop_valid should be 0 at empty"); fails = fails + 1; end

        // Random interleaved push/pop
        s = 32'hC0DEC0DE;
        for (i = 0; i < 500; i = i + 1) begin
            s = {s[30:0], s[31] ^ s[21] ^ s[1] ^ s[0]};
            if (s[1:0] == 2'b00 && push_ready) push(s);
            else if (s[1:0] == 2'b11 && pop_valid) pop_one();
            else if (push_ready) push(s);
            else if (pop_valid) pop_one();
        end

        // Drain remaining
        while (pop_valid) pop_one();

        if (pushes != pops) begin $display("FAIL: %0d pushes vs %0d pops", pushes, pops); fails = fails + 1; end

        if (fails == 0) $display("ALL PASS (%0d pushes, %0d pops)", pushes, pops);
        else            $display("FAIL: %0d errors", fails);
        $finish;
    end

    initial begin #500000; $display("TIMEOUT"); $finish; end
endmodule
