`timescale 1ns/1ps
module tb_bench;
  logic clk=0, reset=1; always #5 clk=~clk;
  logic load_we=0; logic [11:0] load_addr=0; logic [31:0] load_data=0; logic cpu_rst_req=1;
  logic egv, egr=1, egl; logic [31:0] egd;
  logic iv=0, ir, il=0; logic [31:0] idat=0;
  logic cp, ca, q;
  mb_array_soc #(.ARRAY_Y(1),.ARRAY_X(1),.HOST_INGRESS(0),.USE_MESH(1)) dut(
    .clk,.reset,.load_we,.load_addr,.load_data,.cpu_rst_req,
    .egr_valid(egv),.egr_ready(egr),.egr_data(egd),.egr_last(egl),
    .ingr_valid(iv),.ingr_ready(ir),.ingr_data(idat),.ingr_last(il),
    .cycle_parity(cp),.cycle_advance(ca),.quiescent(q));
  longint cyc=0; always @(posedge clk) cyc++;
  longint t_start=0, t_done=0; int seen=0; reg w0v=0;
  always @(posedge clk) if (egv && egr) begin
    if (!egl) w0v<=1; else begin
      if (egd[31:16]==16'hAAAA) t_start<=cyc;
      if (egd[31:16]==16'hBBBB) begin t_done<=cyc; seen<=1; end
    end
  end
  reg [31:0] prog[0:4095]; integer i,nw;
  initial begin
    for(i=0;i<4096;i++) prog[i]=0; $readmemh("mb_bench.hex", prog);
    if(!$value$plusargs("NW=%d", nw)) nw=4096;
    @(negedge clk);
    for(i=0;i<nw;i++) begin load_we<=1; load_addr<=i[11:0]; load_data<=prog[i]; @(negedge clk); end
    load_we<=0; repeat(4)@(negedge clk); cpu_rst_req<=0; reset<=0;
    for(i=0;i<500000 && !seen;i++) @(posedge clk);
    $display("cycles for 1000 evals = %0d  => %0d cyc/eval", t_done-t_start, (t_done-t_start)/1000);
    $finish;
  end
  initial begin repeat(800000) @(posedge clk); $display("TIMEOUT"); $finish; end
endmodule
