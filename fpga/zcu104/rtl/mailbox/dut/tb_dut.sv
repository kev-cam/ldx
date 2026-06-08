`timescale 1ns/1ps
module tb_dut #(parameter AY=4, AX=4, USE_MESH=1, NSAMP=12);
  logic clk=0, reset=1; always #5 clk=~clk;
  logic load_we=0; logic [9:0] load_addr=0; logic [31:0] load_data=0; logic cpu_rst_req=1;
  logic egr_valid, egr_ready=1, egr_last; logic [31:0] egr_data;
  logic cyc_par, cyc_adv, quiesc;
  mb_array_soc #(.ARRAY_Y(AY), .ARRAY_X(AX), .USE_MESH(USE_MESH)) dut(
    .clk,.reset,.load_we,.load_addr,.load_data,.cpu_rst_req,
    .egr_valid,.egr_ready,.egr_data,.egr_last,
    .cycle_parity(cyc_par),.cycle_advance(cyc_adv),.quiescent(quiesc));
  int en=0; reg [31:0] dh; reg [31:0] got[0:31];
  always @(posedge clk) if (egr_valid && egr_ready) begin
    if (!egr_last) dh <= egr_data;
    else begin if (en<32) got[en]=egr_data; $display("EGR %0d = %0d", en, egr_data); en++; end
  end
  reg [31:0] prog[0:1023]; integer i,nw;
  initial begin
    for(i=0;i<1024;i++) prog[i]=32'hx;
    $readmemh("mb_dut.hex", prog);
    nw=0; for(i=0;i<1024;i++) if(prog[i]!==32'hx) nw=i+1;
    $display("program words: %0d  array %0dx%0d", nw, AY, AX);
    @(negedge clk);
    for(i=0;i<nw;i++) begin load_we<=1; load_addr<=i[9:0]; load_data<=prog[i]; @(negedge clk); end
    load_we<=0; repeat(4)@(negedge clk); cpu_rst_req<=0; reset<=0;
    for(i=0;i<200000 && en<NSAMP;i++) @(posedge clk);
    $display("captured %0d egress samples in %0d clocks", en, i);
    $finish;
  end
  initial begin repeat(800000) @(posedge clk); $display("TIMEOUT"); $finish; end
endmodule
