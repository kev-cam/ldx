`timescale 1ns/1ps
module tb_raccel;
  logic clk=0, reset=1; always #5 clk=~clk;
  logic load_we=0; logic [9:0] load_addr=0; logic [31:0] load_data=0; logic cpu_rst_req=1;
  logic egr_valid, egr_ready=1, egr_last; logic [31:0] egr_data;
  logic ingr_valid=0, ingr_ready, ingr_last=0; logic [31:0] ingr_data=0;
  logic cyc_par, cyc_adv, quiesc;
  mb_array_soc #(.ARRAY_Y(1), .ARRAY_X(1), .HOST_INGRESS(1)) dut(
    .clk,.reset,.load_we,.load_addr,.load_data,.cpu_rst_req,
    .egr_valid,.egr_ready,.egr_data,.egr_last,
    .ingr_valid,.ingr_ready,.ingr_data,.ingr_last,
    .cycle_parity(cyc_par),.cycle_advance(cyc_adv),.quiescent(quiesc));

  // ARM reads DUT top-output (result) from egress
  int outn=0; reg [31:0] dh;
  always @(posedge clk) if (egr_valid && egr_ready) begin
    if (!egr_last) dh <= egr_data;
    else begin $display("RACCEL_OUT %0d", egr_data); outn++; end
  end

  // ARM drives DUT top-input: inject a 1-word packet (x) to core (0,0)
  task automatic inject(input [31:0] val);
    @(posedge clk);
    ingr_valid <= 1'b1; ingr_data <= 32'h0000_0001; ingr_last <= 1'b0;  // word0 dst(0,0) size1
    @(posedge clk); while (!ingr_ready) @(posedge clk);
    ingr_data <= val; ingr_last <= 1'b1;                                 // payload x
    @(posedge clk); while (!ingr_ready) @(posedge clk);
    ingr_valid <= 1'b0; ingr_last <= 1'b0;
  endtask

  reg [31:0] prog[0:1023]; integer i,nw,k;
  initial begin
    for(i=0;i<1024;i++) prog[i]=32'hx;
    $readmemh("mb_raccel.hex", prog);
    nw=0; for(i=0;i<1024;i++) if(prog[i]!==32'hx) nw=i+1;
    $display("program words: %0d", nw);
    @(negedge clk);
    for(i=0;i<nw;i++) begin load_we<=1; load_addr<=i[9:0]; load_data<=prog[i]; @(negedge clk); end
    load_we<=0; repeat(4)@(negedge clk); cpu_rst_req<=0; reset<=0;
    repeat(20) @(posedge clk);                 // let the DUT boot
    for (k=0;k<12;k++) begin
      inject(k);                               // drive DUT top-input x = k
      @(posedge clk); while(!cyc_adv) @(posedge clk);   // one DUT cycle
    end
    repeat(50) @(posedge clk);
    $display("captured %0d outputs", outn);
    $finish;
  end
  initial begin repeat(400000) @(posedge clk); $display("TIMEOUT"); $finish; end
endmodule
