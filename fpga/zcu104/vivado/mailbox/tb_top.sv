`timescale 1ns/1ps
// tb_top.sv — validate mb_array_top's AXI4-Lite slave (esp. the ingress FSM fix)
// with a minimal AXI-Lite master BFM: load the echo worker, inject a word, read
// it back from egress. 1x1 array for fast verilation (the FSM is array-size
// independent). Expect the injected value echoed at EGR.
module tb_top;
  logic clk=0, rstn=0; always #5 clk=~clk;
  logic [11:0] awaddr=0; logic awvalid=0, awready;
  logic [31:0] wdata=0;  logic [3:0] wstrb=4'hF; logic wvalid=0, wready;
  logic [1:0] bresp; logic bvalid, bready=0;
  logic [11:0] araddr=0; logic arvalid=0, arready;
  logic [31:0] rdata; logic [1:0] rresp; logic rvalid, rready=0;

  mb_array_top #(.ARRAY_Y(1), .ARRAY_X(1), .MEM_WORDS(4096)) dut(
    .s_axi_aclk(clk), .s_axi_aresetn(rstn),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready));

  localparam CTRL=12'h00, LOADA=12'h04, LOADD=12'h08, INGRW0=12'h0C, INGRD1=12'h10,
             EGR=12'h14, STATUS=12'h18;

  int pc=0;
  always @(posedge clk) if (dut.ingr_valid && pc<24) begin
    $display("PRB st=%0d iv=%b ir=%b last=%b tsr=%b tsv=%b idata=%08x",
      dut.ingr_st, dut.ingr_valid, dut.ingr_ready, dut.ingr_last,
      dut.u_array.t_s_ready, dut.u_array.t_s_valid, dut.ingr_data);
    pc++;
  end

  task automatic axi_w(input [11:0] a, input [31:0] d);
    @(negedge clk); awaddr=a; awvalid=1; wdata=d; wvalid=1; wstrb=4'hF; bready=1;
    do begin @(posedge clk); if (awready) awvalid=0; if (wready) wvalid=0; end
      while (awvalid || wvalid);
    while (!bvalid) @(posedge clk);
    @(negedge clk); bready=0;
  endtask
  task automatic axi_r(input [11:0] a, output [31:0] d);
    @(negedge clk); araddr=a; arvalid=1; rready=1;
    @(posedge clk); while (!arready) @(posedge clk);
    @(negedge clk); arvalid=0;
    @(posedge clk); while (!rvalid) @(posedge clk);
    d=rdata; @(negedge clk); rready=0;
  endtask

  reg [31:0] prog[0:1023]; integer i,nw; reg [31:0] rv;
  initial begin
    for(i=0;i<1024;i++) prog[i]=32'h0;
    $readmemh(`HEX, prog);
    if(!$value$plusargs("NW=%d", nw)) nw=48;
    $display("echo prog words: %0d", nw);
    repeat(6) @(posedge clk); rstn=1; repeat(4) @(posedge clk);
    axi_w(CTRL, 32'h3);                       // hold array + cpu in reset
    axi_w(LOADA, 0);
    for(i=0;i<nw;i++) axi_w(LOADD, prog[i]);  // load echo program
    axi_w(CTRL, 32'h0);                       // release
    repeat(300) @(posedge clk);               // boot
    axi_r(STATUS, rv); $display("after-boot STATUS=%08x", rv);
    axi_w(INGRW0, 32'h0000_0001);             // dst(0,0) size1
    axi_w(INGRD1, 32'hCAFEF00D);              // inject payload
    axi_r(STATUS, rv); $display("after-inject STATUS=%08x", rv);
    // wait for egress
    rv=0;
    for(i=0;i<5000 && !(rv&1);i++) axi_r(STATUS, rv);
    if (rv & 1) begin
      axi_r(EGR, rv);
      $display("EGR=%08x  %s", rv, (rv==32'hCAFEF00D)?"INGRESS-FSM PASS":"FAIL(wrong data)");
    end else $display("INGRESS-FSM FAIL (no egress)");
    $finish;
  end
  initial begin repeat(200000) @(posedge clk); $display("TIMEOUT"); $finish; end
endmodule
