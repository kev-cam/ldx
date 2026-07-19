// tb_soc_mb.sv — M1 loopback: one ldx_soc_mailbox node, egress looped to
// ingress. The CPU program (mb_worker) posts a self-addressed packet; it
// returns through the mailbox; the CPU reads it and stashes RESULT in BRAM.
`timescale 1ns/1ps
module tb_soc_mb;
  logic clk=0, reset=1; always #5 clk=~clk;
  logic        load_we=0; logic [9:0] load_addr=0; logic [31:0] load_data=0;
  logic        cpu_rst_req=1;

  logic m_valid, m_ready, m_last, m_off; logic [31:0] m_data;
  logic s_valid, s_ready, s_last;        logic [31:0] s_data;
  logic core_busy, nif_busy, pkt_sent, pkt_deliv;

  ldx_soc_mailbox #(.MY_X(4'd1), .MY_Y(4'd1)) dut (
    .clk, .reset, .load_we, .load_addr, .load_data, .cpu_rst_req,
    .m_valid, .m_ready, .m_data, .m_last, .m_off_array(m_off),
    .s_valid, .s_ready, .s_data, .s_last,
    .cycle_parity(1'b0), .cycle_advance(1'b0),
    .core_busy, .nif_busy, .pkt_sent, .pkt_deliv
  );

  // network loopback: egress -> ingress
  assign s_valid = m_valid;
  assign s_data  = m_data;
  assign s_last  = m_last;
  assign m_ready = s_ready;

  reg [31:0] prog [0:1023];
  integer i, nwords;
  initial begin
    for (i=0;i<1024;i=i+1) prog[i]=32'hx;
    $readmemh("mb_worker.hex", prog);
    nwords=0; for (i=0;i<1024;i=i+1) if (prog[i]!==32'hx) nwords=i+1;
    $display("loaded %0d program words", nwords);

    @(negedge clk);
    for (i=0;i<nwords;i=i+1) begin
      load_we<=1'b1; load_addr<=i[9:0]; load_data<=prog[i]; @(negedge clk);
    end
    load_we<=1'b0;
    repeat (4) @(negedge clk);
    cpu_rst_req<=1'b0; reset<=1'b0;          // release the CPU

    repeat (3000) @(posedge clk);

    $display("RESULT[0]=%08x (want abcd1234)", dut.dpram['h3C0]);
    $display("RESULT[1]=%08x (rx header)",     dut.dpram['h3C1]);
    $display("RESULT[2]=%08x (want 0000d09e)", dut.dpram['h3C2]);
    if (dut.dpram['h3C0]==32'hABCD1234 && dut.dpram['h3C2]==32'h0000D09E)
      $display("M1 LOOPBACK PASS");
    else
      $display("M1 LOOPBACK FAIL");
    $finish;
  end
  initial begin repeat (60000) @(posedge clk); $display("TIMEOUT"); $finish; end
endmodule
