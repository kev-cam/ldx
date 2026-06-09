`timescale 1ns/1ps
// tb_hwrt.sv — validate the HW XY-routing fabric (mb_mesh_hw) in isolation:
// drive the stream ports directly (no VexRiscv cores). Checks multi-hop delivery
// (host -> far corner), core->core, and off-array egress from a non-tile-0 core.
`include "mailbox_pkg.sv"
module tb_hwrt;
  import mailbox_pkg::*;
  localparam int AY=4, AX=4, NC=AY*AX, NIN=NC+1;
  logic clk=0, rst=1; always #5 clk=~clk;

  logic [NIN-1:0]              inv=0, inl=0, inoff=0, inr;
  logic [NIN-1:0][WORD_W-1:0]  ind='{default:0};
  logic [NC-1:0]               ov, ol; logic [NC-1:0] orr;
  logic [NC-1:0][WORD_W-1:0]   od;
  logic egv, egl, egr_rdy=1; logic [WORD_W-1:0] egd;

  logic [NC-1:0] orr_r = '1;                 // core sink readiness (settable: hung core = 0)
  assign orr = orr_r;

  mb_mesh_hw #(.N_CORES(NC), .ARRAY_Y(AY), .ARRAY_X(AX), .HOST_INGRESS(1), .LINK_DEPTH(16)) dut(
    .clk,.rst,
    .in_valid(inv),.in_ready(inr),.in_data(ind),.in_last(inl),.in_off(inoff),
    .out_valid(ov),.out_ready(orr),.out_data(od),.out_last(ol),
    .egr_valid(egv),.egr_ready(egr_rdy),.egr_data(egd),.egr_last(egl));

  // capture per-core received payloads + egress
  reg [31:0] rcv_pay [NC]; int rcv_n [NC];
  reg [31:0] egr_pay [0:31]; int egr_n=0;
  reg [31:0] ow0 [NC]; reg [31:0] egw0;
  integer t;
  always @(posedge clk) begin
    for (t=0;t<NC;t++) if (ov[t] && orr[t]) begin
      if (!ol[t]) ow0[t] <= od[t];
      else begin rcv_pay[t] <= od[t]; rcv_n[t] <= rcv_n[t]+1; end
    end
    if (egv && egr_rdy) begin
      if (!egl) egw0 <= egd; else begin egr_pay[egr_n%32] <= egd; egr_n <= egr_n+1; end
    end
  end

  // drive a 1-word packet from input `src` to (dy,dx) (off=off-array), race-free
  task automatic send(input int src, input [7:0] dy, input [7:0] dx, input off, input [31:0] pay);
    @(negedge clk); inv[src]=1'b1; ind[src]={off,1'b0,6'd0,dy,dx,8'd1}; inl[src]=1'b0;
    @(posedge clk); while(!inr[src]) @(posedge clk);
    @(negedge clk); ind[src]=pay; inl[src]=1'b1;
    @(posedge clk); while(!inr[src]) @(posedge clk);
    @(negedge clk); inv[src]=1'b0; inl[src]=1'b0;
  endtask

  function automatic int tile(input int y, input int x); return y*AX+x; endfunction

  initial begin
    for (t=0;t<NC;t++) rcv_n[t]=0;
    repeat(8) @(posedge clk); rst=0; repeat(4) @(posedge clk);

    // 1) host -> far corner (3,3): multi-hop across the mesh
    send(NC, 3, 3, 1'b0, 32'hC0FFEE00);
    // 2) core 5 (1,1) -> (0,0): multi-hop back
    send(tile(1,1), 0, 0, 1'b0, 32'hA5A50001);
    // 3) core 0 (0,0) -> off-array: egress from tile 0
    send(tile(0,0), 0, 0, 1'b1, 32'hE0000000);
    // 4) core 10 (2,2) -> off-array: must route to tile 0 then egress (any-tile egress)
    send(tile(2,2), 0, 0, 1'b1, 32'hE0000022);

    repeat(400) @(posedge clk);

    // 5) HUNG CORE: tile 10 (2,2) never accepts. Send it a packet (will back up),
    //    then send host -> (3,3) again — its XY path (E along row0, S down col3)
    //    avoids tile 10, so it must STILL be delivered despite the hung core.
    orr_r[10] = 1'b0;                          // tile 10 hangs
    send(NC, 2, 2, 1'b0, 32'hDEAD0010);        // -> hung core 10 (never delivered)
    send(NC, 3, 3, 1'b0, 32'h600D0015);        // -> (3,3), path avoids tile 10
    repeat(400) @(posedge clk);

    $display("rcv[15]=%08x n=%0d  rcv[0]=%08x n=%0d  rcv[10]_n=%0d  egr_n=%0d egr[0]=%08x egr[1]=%08x",
             rcv_pay[15], rcv_n[15], rcv_pay[0], rcv_n[0], rcv_n[10], egr_n, egr_pay[0], egr_pay[1]);
    begin int ok=1;
      if (!(rcv_pay[15]==32'h600D0015 && rcv_n[15]==2)) begin ok=0; $display("FAIL: delivery past hung core"); end
      if (!(rcv_n[0]==1  && rcv_pay[0]==32'hA5A50001))  begin ok=0; $display("FAIL: (1,1)->(0,0)"); end
      if (!(rcv_n[10]==0))                              begin ok=0; $display("FAIL: hung core got %0d", rcv_n[10]); end
      if (!(egr_n==2))                                  begin ok=0; $display("FAIL: egress count %0d != 2", egr_n); end
      if (ok) $display("HWRT PASS (multi-hop + any-tile egress + transit past a hung core)");
      else    $display("HWRT FAIL");
    end
    $finish;
  end
  initial begin repeat(20000) @(posedge clk); $display("TIMEOUT"); $finish; end
endmodule
