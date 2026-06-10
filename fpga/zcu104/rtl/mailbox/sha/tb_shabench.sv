`timescale 1ns/1ps
module tb_shabench;
  logic clk=0, reset=1; always #5 clk=~clk;
  logic lwe=0; logic [11:0] la=0; logic [31:0] ldd=0; logic crq=1;
  logic egv, egr=1, egl; logic [31:0] egd; logic iv=0, ir, il=0; logic [31:0] idat=0; logic cp,ca,q;
  mb_array_soc #(.ARRAY_Y(1),.ARRAY_X(1),.HOST_INGRESS(0),.USE_MESH(1)) dut(
    .clk,.reset,.load_we(lwe),.load_addr(la),.load_data(ldd),.cpu_rst_req(crq),
    .egr_valid(egv),.egr_ready(egr),.egr_data(egd),.egr_last(egl),
    .ingr_valid(iv),.ingr_ready(ir),.ingr_data(idat),.ingr_last(il),
    .cycle_parity(cp),.cycle_advance(ca),.quiescent(q));
  longint cyc=0; always @(posedge clk) cyc++;
  longint t0=0,t1=0; int seen=0; reg w0=0; reg [31:0] res=0;
  always @(posedge clk) if(egv&&egr) begin
    if(!egl) w0<=1; else begin
      if(egd[31:16]==16'hAAAA) t0<=cyc;
      if(egd[31:16]==16'hBBBB) begin t1<=cyc; res<=egd[15:0]; seen<=1; end
    end
  end
  reg [31:0] prog[0:4095]; integer i,nw;
  initial begin
    for(i=0;i<4096;i++) prog[i]=0; $readmemh("mb_shabench.hex", prog);
    if(!$value$plusargs("NW=%d", nw)) nw=4096;
    @(negedge clk);
    for(i=0;i<nw;i++) begin lwe<=1; la<=i[11:0]; ldd<=prog[i]; @(negedge clk); end
    lwe<=0; repeat(4)@(negedge clk); crq<=0; reset<=0;
    for(i=0;i<8000000 && !seen;i++) @(posedge clk);
    $display("100 blocks = %0d cyc => %0d cyc/block  digest[7]&ffff=%04x (abc=16bf)", t1-t0, (t1-t0)/100, res);
    $finish;
  end
  initial begin repeat(10000000) @(posedge clk); $display("TIMEOUT"); $finish; end
endmodule
