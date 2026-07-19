`timescale 1ns/1ps
// Multi-block SHA256 on the array, TB-on-ARM. Streams a block count then the
// blocks; reads back the 8 digest words. Vector = the 56-byte FIPS message
// "abcdbcde…nopq" -> 248d6a61… (2 blocks).
module tb_shamb;
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

  int dn=0; reg [31:0] dig[0:7]; reg [31:0] dh=0;
  always @(posedge clk) if (egr_valid && egr_ready) begin
    if (!egr_last) dh <= egr_data;
    else begin if (dn<8) dig[dn]=egr_data; dn++; end
  end

  // race-free 1-word ingress packet to core (0,0) (see tb_sha.sv)
  task automatic inject(input [31:0] val);
    @(negedge clk); ingr_valid=1'b1; ingr_data=32'h0000_0001; ingr_last=1'b0;
    @(posedge clk); while(!ingr_ready) @(posedge clk);
    @(negedge clk); ingr_data=val; ingr_last=1'b1;
    @(posedge clk); while(!ingr_ready) @(posedge clk);
    @(negedge clk); ingr_valid=1'b0; ingr_last=1'b0;
  endtask
  // inject one word then advance the array one barrier cycle (lockstep w/ worker)
  task automatic feed(input [31:0] val);
    inject(val);
    @(posedge clk); while(!cyc_adv) @(posedge clk);
  endtask

  reg [31:0] prog[0:4095]; integer i,b,nw;
  reg [31:0] blk[0:1][0:15], exp[0:7];
  initial begin
    blk[0][0]=32'h61626364; blk[0][1]=32'h62636465; blk[0][2]=32'h63646566; blk[0][3]=32'h64656667;
    blk[0][4]=32'h65666768; blk[0][5]=32'h66676869; blk[0][6]=32'h6768696a; blk[0][7]=32'h68696a6b;
    blk[0][8]=32'h696a6b6c; blk[0][9]=32'h6a6b6c6d; blk[0][10]=32'h6b6c6d6e; blk[0][11]=32'h6c6d6e6f;
    blk[0][12]=32'h6d6e6f70; blk[0][13]=32'h6e6f7071; blk[0][14]=32'h80000000; blk[0][15]=32'h00000000;
    for(i=0;i<16;i++) blk[1][i]=32'h0; blk[1][15]=32'h000001c0;
    exp[0]='h248d6a61; exp[1]='hd20638b8; exp[2]='he5c02693; exp[3]='h0c3e6039;
    exp[4]='ha33ce459; exp[5]='h64ff2167; exp[6]='hf6ecedd4; exp[7]='h19db06c1;
    for(i=0;i<4096;i++) prog[i]=32'h0;
    $readmemh("mb_shamb.hex", prog);
    if(!$value$plusargs("NW=%d", nw)) nw=4096;
    $display("program words: %0d", nw);
    @(negedge clk);
    for(i=0;i<nw;i++) begin load_we<=1; load_addr<=i[11:0]; load_data<=prog[i]; @(negedge clk); end
    load_we<=0; repeat(4)@(negedge clk); cpu_rst_req<=0; reset<=0;
    repeat(40) @(posedge clk);                     // boot
    feed(32'd2);                                   // block count
    for(b=0;b<2;b++) for(i=0;i<16;i++) feed(blk[b][i]);
    for(i=0;i<400000 && dn<8;i++) @(posedge clk);  // wait for digest (2 blocks ~130 cyc compute)
    $write("digest:"); for(i=0;i<8;i++) $write(" %08x", dig[i]); $display("");
    begin int bad=0; for(i=0;i<8;i++) if (dig[i]!==exp[i]) bad++;
      if (dn>=8 && bad==0) $display("SHA256-MULTIBLOCK-ON-ARRAY PASS");
      else $display("SHAMB FAIL (bad=%0d, dn=%0d)", bad, dn); end
    $finish;
  end
  initial begin repeat(1000000) @(posedge clk); $display("TIMEOUT"); $finish; end
endmodule
