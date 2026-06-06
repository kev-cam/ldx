`timescale 1ns/1ps
module tb_m3a;
  localparam AY=1, AX=2;
  logic clk=0, reset=1; always #5 clk=~clk;
  logic load_we=0; logic [9:0] load_addr=0; logic [31:0] load_data=0; logic cpu_rst_req=1;
  logic egr_valid, egr_ready=1, egr_last; logic [31:0] egr_data;
  logic cyc_par, cyc_adv, quiesc;
  mb_array_soc #(.ARRAY_Y(AY), .ARRAY_X(AX)) dut(
    .clk,.reset,.load_we,.load_addr,.load_data,.cpu_rst_req,
    .egr_valid,.egr_ready,.egr_data,.egr_last,
    .cycle_parity(cyc_par),.cycle_advance(cyc_adv),.quiescent(quiesc));

  // host-bridge: capture $display off-array packets (word0 handle, then value)
  int dispn=0, errors=0; reg [31:0] dh;
  always @(posedge clk) if (egr_valid && egr_ready) begin
    if (!egr_last) dh <= egr_data;
    else begin
      $display("  $display[h%0d] count=%0d", (dh>>8)&32'hFFFF, egr_data);
      if (egr_data !== dispn[31:0]) errors++;   // expect 0,1,2,...
      dispn++;
    end
  end

  reg [31:0] prog[0:1023]; integer i,nw;
  initial begin
    for(i=0;i<1024;i++) prog[i]=32'hx;
    $readmemh("mb_m3a.hex", prog);
    nw=0; for(i=0;i<1024;i++) if(prog[i]!==32'hx) nw=i+1;
    $display("program words: %0d", nw);
    @(negedge clk);
    for(i=0;i<nw;i++) begin load_we<=1; load_addr<=i[9:0]; load_data<=prog[i]; @(negedge clk); end
    load_we<=0; repeat(4)@(negedge clk); cpu_rst_req<=0; reset<=0;
    for(i=0;i<80000 && dispn<12;i++) @(posedge clk);
    repeat(50) @(posedge clk);
    $display("captured %0d displays, %0d sequence errors", dispn, errors);
    if (dispn>=12 && errors==0) $display("M3a COUNTER+DISPLAY PASS");
    else $display("M3a FAIL");
    $finish;
  end
  initial begin repeat(300000) @(posedge clk); $display("TIMEOUT"); $finish; end
endmodule
