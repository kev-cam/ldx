`timescale 1ns/1ps
module tb_sha;
  logic clk=0, reset=1; always #5 clk=~clk;
  logic load_we=0; logic [11:0] load_addr=0; logic [31:0] load_data=0; logic cpu_rst_req=1;
  logic egr_valid, egr_ready=1, egr_last; logic [31:0] egr_data;
  logic ingr_valid=0, ingr_ready, ingr_last=0; logic [31:0] ingr_data=0;
  logic cyc_par, cyc_adv, quiesc;
  mb_array_soc #(.ARRAY_Y(1), .ARRAY_X(1), .HOST_INGRESS(1), .USE_MESH(1)) dut(
    .clk,.reset,.load_we,.load_addr,.load_data,.cpu_rst_req,
    .egr_valid,.egr_ready,.egr_data,.egr_last,
    .ingr_valid,.ingr_ready,.ingr_data,.ingr_last,
    .cycle_parity(cyc_par),.cycle_advance(cyc_adv),.quiescent(quiesc));

  // capture digest payloads (egr framing: word0 last=0, payload last=1)
  int dn=0; reg [31:0] dig[0:7]; reg [31:0] dh=0;
  always @(posedge clk) if (egr_valid && egr_ready) begin
    if (!egr_last) dh <= egr_data;
    else begin if (dn<8) dig[dn]=egr_data; dn++; end
  end

  // ARM drives one block word as a 1-word ingress packet to core (0,0), in order.
  // Race-free BFM: signals change on negedge (stable before the posedge the DUT
  // samples), each beat held until actually accepted (valid && ready at posedge).
  task automatic inject(input [31:0] val);
    @(negedge clk); ingr_valid=1'b1; ingr_data=32'h0000_0001; ingr_last=1'b0; // word0 dst(0,0) size1
    @(posedge clk); while(!ingr_ready) @(posedge clk);                        // word0 accepted
    @(negedge clk); ingr_data=val; ingr_last=1'b1;                            // payload = block word
    @(posedge clk); while(!ingr_ready) @(posedge clk);                        // payload accepted
    @(negedge clk); ingr_valid=1'b0; ingr_last=1'b0;
  endtask

  reg [31:0] prog[0:4095]; integer i,nw;
  reg [31:0] blk[0:15], exp[0:7];
  initial begin
    exp[0]='hba7816bf; exp[1]='h8f01cfea; exp[2]='h414140de; exp[3]='h5dae2223;
    exp[4]='hb00361a3; exp[5]='h96177a9c; exp[6]='hb410ff61; exp[7]='hf20015ad;
    // NIST "abc" padded block: w[0]=0x61626380 … w[15]=0x18
    for(i=0;i<16;i++) blk[i]=32'h0;
    blk[0]=32'h61626380; blk[15]=32'h00000018;
    for(i=0;i<4096;i++) prog[i]=32'h0;
    $readmemh("mb_sha.hex", prog);
    if(!$value$plusargs("NW=%d", nw)) nw=4096;
    $display("program words: %0d", nw);
    @(negedge clk);
    for(i=0;i<nw;i++) begin load_we<=1; load_addr<=i[11:0]; load_data<=prog[i]; @(negedge clk); end
    load_we<=0; repeat(4)@(negedge clk); cpu_rst_req<=0; reset<=0;
    repeat(40) @(posedge clk);                     // let the DUT boot
    for(i=0;i<16;i++) begin
      inject(blk[i]);                              // feed block word i
      @(posedge clk); while(!cyc_adv) @(posedge clk);   // one DUT cycle
    end
    for(i=0;i<200000 && dn<8;i++) @(posedge clk);  // wait for the digest
    $write("digest:"); for(i=0;i<8;i++) $write(" %08x", dig[i]); $display("");
    begin int bad=0; for(i=0;i<8;i++) if (dig[i]!==exp[i]) bad++;
      if (dn>=8 && bad==0) $display("SHA256-ON-ARRAY PASS"); else $display("SHA FAIL (bad=%0d, dn=%0d)", bad, dn); end
    $finish;
  end
  initial begin repeat(600000) @(posedge clk); $display("TIMEOUT"); $finish; end
endmodule
