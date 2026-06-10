`timescale 1ns/1ps
module tb_gather #(parameter AY=4, AX=4, USE_MESH=0, USE_HWROUTER=0);
  logic clk=0, reset=1; always #5 clk=~clk;
  logic lwe=0; logic [11:0] la=0; logic [31:0] ld=0; logic crq=1;
  logic egv, egr=1, egl; logic [31:0] egd;
  logic iv=0, ir, il=0; logic [31:0] idat=0; logic cp, ca, q;
  mb_array_soc #(.ARRAY_Y(AY),.ARRAY_X(AX),.HOST_INGRESS(0),.USE_MESH(USE_MESH),.USE_HWROUTER(USE_HWROUTER)) dut(
    .clk,.reset,.load_we(lwe),.load_addr(la),.load_data(ld),.cpu_rst_req(crq),
    .egr_valid(egv),.egr_ready(egr),.egr_data(egd),.egr_last(egl),
    .ingr_valid(iv),.ingr_ready(ir),.ingr_data(idat),.ingr_last(il),
    .cycle_parity(cp),.cycle_advance(ca),.quiescent(q));
  int maxn=0; reg w0=0;
  always @(posedge clk) if(egv && egr) begin
    if(!egl) w0<=1; else if(egd[31:16]==16'hC011 && egd[15:0]>maxn) maxn=egd[15:0];
  end
  reg [31:0] prog[0:4095]; integer i,nw;
  initial begin
    for(i=0;i<4096;i++) prog[i]=0; $readmemh("mb_gather.hex", prog);
    if(!$value$plusargs("NW=%d", nw)) nw=4096;
    @(negedge clk);
    for(i=0;i<nw;i++) begin lwe<=1; la<=i[11:0]; ld<=prog[i]; @(negedge clk); end
    lwe<=0; repeat(4)@(negedge clk); crq<=0; reset<=0;
    repeat(60000) @(posedge clk);
    $display("collector received %0d of %0d senders", maxn, AY*AX-1);
    $finish;
  end
endmodule
