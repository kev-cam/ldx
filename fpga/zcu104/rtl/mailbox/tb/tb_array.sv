// tb_array.sv — 4x4 smoke test. Each tile's behavioral core runs the ring
// personality; the array should advance simulated cycles (barrier), flipping
// cycle_parity each time, with every core receiving one message per cycle.

`include "mailbox_pkg.sv"

module tb_array;
  import mailbox_pkg::*;

  localparam int AY = 4, AX = 4, NC = AY*AX;

  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  logic                  egr_valid, egr_ready = 1, egr_last;
  logic [WORD_W-1:0]     egr_data;
  logic                  cyc_par, cyc_adv, quiesc;
  logic [NC-1:0][15:0]   recv;

  mb_array #(.ARRAY_Y(AY), .ARRAY_X(AX)) dut (
    .clk, .rst, .egr_valid, .egr_ready, .egr_data, .egr_last,
    .cycle_parity(cyc_par), .cycle_advance(cyc_adv), .quiescent(quiesc),
    .recv_total(recv)
  );

  int  adv_count = 0, par_edges = 0;
  logic par_d = 0;
  always @(posedge clk) begin
    if (cyc_adv) begin
      adv_count++;
      $display("  [adv %0d] recv[0]=%0d recv[1]=%0d recv[7]=%0d", adv_count, recv[0], recv[1], recv[7]);
    end
    par_d <= cyc_par;
    if (cyc_par !== par_d) par_edges++;
  end

  int errors = 0;
  task automatic chk(input bit c, input string m);
    if (c) $display("  ok  : %s", m); else begin $display("  FAIL: %s", m); errors++; end
  endtask

  localparam int TARGET = 8;
  initial begin
    repeat (4) @(posedge clk); @(negedge clk); rst = 0;

    // run until TARGET simulated cycles have advanced (or give up)
    for (int t = 0; t < 5000 && adv_count < TARGET; t++) @(posedge clk);
    repeat (10) @(posedge clk);

    $display("\n4x4 smoke: advanced %0d simulated cycles, parity edges %0d", adv_count, par_edges);
    begin
      int mn = 32'h7fffffff, mx = 0;
      for (int i = 0; i < NC; i++) begin
        if (recv[i] < mn) mn = recv[i];
        if (recv[i] > mx) mx = recv[i];
      end
      $display("  recv_total across 16 cores: min=%0d max=%0d", mn, mx);
      chk(adv_count >= TARGET, "array advanced >= 8 simulated cycles (no deadlock)");
      chk(par_edges  >= TARGET, "cycle_parity toggled on each advance");
      chk(mn == mx, "all 16 cores in lockstep (identical recv counts)");
      chk(mn >= adv_count && mn <= adv_count + 1,
          "exactly one message per core per simulated cycle (clean 1:1 cadence)");
    end

    $display("\n==== errors = %0d ====", errors);
    if (errors == 0) $display("4x4 SMOKE PASS");
    $finish;
  end

  initial begin repeat (8000) @(posedge clk); $display("HARD TIMEOUT"); $finish; end

endmodule
