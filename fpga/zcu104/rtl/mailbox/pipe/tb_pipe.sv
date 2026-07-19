`timescale 1ns/1ps
module tb_pipe #(parameter AY=4, AX=4, PIPE_LEN=4, USE_MESH=1);
  logic clk=0, reset=1; always #5 clk=~clk;
  logic load_we=0; logic [9:0] load_addr=0; logic [31:0] load_data=0; logic cpu_rst_req=1;
  logic egr_valid, egr_ready=1, egr_last; logic [31:0] egr_data;
  logic cyc_par, cyc_adv, quiesc;
  mb_array_soc #(.ARRAY_Y(AY), .ARRAY_X(AX), .USE_MESH(USE_MESH)) dut(
    .clk,.reset,.load_we,.load_addr,.load_data,.cpu_rst_req,
    .egr_valid,.egr_ready,.egr_data,.egr_last,
    .cycle_parity(cyc_par),.cycle_advance(cyc_adv),.quiescent(quiesc));
  reg [31:0] prog[0:1023]; integer i,nw; int bad; reg [31:0] o[0:13];
  initial begin
    for(i=0;i<1024;i++) prog[i]=32'hx;
    $readmemh("mb_pipe.hex", prog);
    nw=0; for(i=0;i<1024;i++) if(prog[i]!==32'hx) nw=i+1;
    $display("program words: %0d  array %0dx%0d  PIPE_LEN %0d", nw, AY, AX, PIPE_LEN);
    @(negedge clk);
    for(i=0;i<nw;i++) begin load_we<=1; load_addr<=i[9:0]; load_data<=prog[i]; @(negedge clk); end
    load_we<=0; repeat(4)@(negedge clk); cpu_rst_req<=0; reset<=0;
    repeat(60000) @(posedge clk);
    for(i=0;i<14;i++) o[i]=dut.row[0].col[PIPE_LEN-1].node.dpram['h3C2+i];
    $write("outputs at (0,%0d):", PIPE_LEN-1); for(i=0;i<14;i++) $write(" %0d", o[i]); $display("");
    bad=0;
    for(i=10;i<14;i++) begin
      if (o[i] % 10 != PIPE_LEN % 10) bad++;
      if (i>10 && o[i] != o[i-1]+10)  bad++;
    end
    if (bad==0 && o[13]>0) $display("PIPE PASS (all outputs == %0d mod 10, +10/step -> data crossed %0d stages)", PIPE_LEN%10, PIPE_LEN);
    else $display("PIPE FAIL (bad=%0d)", bad);
    $finish;
  end
  initial begin repeat(300000) @(posedge clk); $display("TIMEOUT"); $finish; end
endmodule
