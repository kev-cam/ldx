`timescale 1ns/1ps
module tb_relay #(parameter AY=4, AX=4, parameter [7:0] DEST=8'h33);
  logic clk=0, reset=1; always #5 clk=~clk;
  logic load_we=0; logic [9:0] load_addr=0; logic [31:0] load_data=0; logic cpu_rst_req=1;
  logic egr_valid, egr_ready=1, egr_last; logic [31:0] egr_data;
  logic cyc_par, cyc_adv, quiesc;
  mb_array_soc #(.ARRAY_Y(AY), .ARRAY_X(AX)) dut(
    .clk,.reset,.load_we,.load_addr,.load_data,.cpu_rst_req,
    .egr_valid,.egr_ready,.egr_data,.egr_last,
    .cycle_parity(cyc_par),.cycle_advance(cyc_adv),.quiescent(quiesc));
  reg [31:0] prog[0:1023]; integer i,nw;
  initial begin
    for(i=0;i<1024;i++) prog[i]=32'hx;
    $readmemh("mb_relay.hex", prog);
    nw=0; for(i=0;i<1024;i++) if(prog[i]!==32'hx) nw=i+1;
    $display("program words: %0d  array %0dx%0d  dest %0h", nw, AY, AX, DEST);
    @(negedge clk);
    for(i=0;i<nw;i++) begin load_we<=1; load_addr<=i[9:0]; load_data<=prog[i]; @(negedge clk); end
    load_we<=0; repeat(4)@(negedge clk); cpu_rst_req<=0; reset<=0;
    repeat(40000) @(posedge clk);
    begin
      automatic int got = dut.row[DEST[7:4]].col[DEST[3:0]].node.dpram['h3C0];
      automatic int n   = dut.row[DEST[7:4]].col[DEST[3:0]].node.dpram['h3C1];
      $display("dest (%0d,%0d): RESULT[0]=%h  hops-consumed=%0d", DEST[7:4], DEST[3:0], got, n);
      if (got == 'hABCD) $display("RELAY COPY-THROUGH PASS");
      else $display("RELAY FAIL");
    end
    $finish;
  end
  initial begin repeat(400000) @(posedge clk); $display("TIMEOUT"); $finish; end
endmodule
