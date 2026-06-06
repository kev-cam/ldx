`timescale 1ns/1ps
module tb_array_soc;
  localparam AY=4, AX=4;
  logic clk=0, reset=1; always #5 clk=~clk;
  logic load_we=0; logic [9:0] load_addr=0; logic [31:0] load_data=0; logic cpu_rst_req=1;
  logic egr_valid, egr_ready=1, egr_last; logic [31:0] egr_data;
  logic cyc_par, cyc_adv, quiesc;
  mb_array_soc #(.ARRAY_Y(AY), .ARRAY_X(AX)) dut(
    .clk,.reset,.load_we,.load_addr,.load_data,.cpu_rst_req,
    .egr_valid,.egr_ready,.egr_data,.egr_last,
    .cycle_parity(cyc_par),.cycle_advance(cyc_adv),.quiescent(quiesc));
  int adv=0; always @(posedge clk) if (cyc_adv) adv++;
  reg [31:0] prog[0:1023]; integer i,nw;
  initial begin
    for(i=0;i<1024;i++) prog[i]=32'hx;
    $readmemh("mb_ring.hex", prog);
    nw=0; for(i=0;i<1024;i++) if(prog[i]!==32'hx) nw=i+1;
    $display("program words: %0d", nw);
    @(negedge clk);
    for(i=0;i<nw;i++) begin load_we<=1; load_addr<=i[9:0]; load_data<=prog[i]; @(negedge clk); end
    load_we<=0; repeat(4)@(negedge clk); cpu_rst_req<=0; reset<=0;
    for(i=0;i<40000;i++) @(posedge clk);     // let the ring run (boot-window advances are spurious)
    begin
      automatic int r00 = dut.row[0].col[0].node.dpram['h3C0];
      automatic int r11 = dut.row[1].col[1].node.dpram['h3C0];
      automatic int r33 = dut.row[3].col[3].node.dpram['h3C0];
      $display("advanced %0d barrier cycles", adv);
      $display("node(0,0): id=%0d recv=%0d", dut.row[0].col[0].node.dpram['h3C1], r00);
      $display("node(1,1): id=%0d recv=%0d", dut.row[1].col[1].node.dpram['h3C1], r11);
      $display("node(3,3): id=%0d recv=%0d", dut.row[3].col[3].node.dpram['h3C1], r33);
      if (r00 >= 20 && r00 == r11 && r11 == r33)   // every core in lockstep, many cycles, no deadlock
        $display("M2 4x4 RING PASS");
      else $display("M2 4x4 RING FAIL");
    end
    $finish;
  end
  initial begin repeat(600000) @(posedge clk); $display("TIMEOUT"); $finish; end
endmodule
