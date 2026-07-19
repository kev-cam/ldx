// tb_mailbox.sv — unit sim for the implemented fabric pieces:
//   1. NIF + slot_file rx: a packet lands in a slot, ready raises, RAM holds it
//   2. backpressure: s_ready drops when the (capped) file is full
//   3. consumer free: done clears ready, sets free
//   4. NIF tx: a send doorbell streams a slot out the egress
//   5. signal_port: bank_id/addr_mode/region-select address math
//   6. barrier: quiescence -> cycle_parity flip
// Run: verilator --binary --timing (see run.sh).

`include "mailbox_pkg.sv"

module tb_mailbox;
  import mailbox_pkg::*;

  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  int errors = 0;
  task automatic chk(input bit c, input string m);
    if (c) $display("  ok  : %s", m);
    else begin $display("  FAIL: %s", m); errors++; end
  endtask

  // ===================== DUT A: NIF + slot_file =========================
  localparam int LIM = 4;                      // cap to 4 slots for this test
  logic [SLOT_ID_W:0] slot_limit = LIM;

  // ingress / egress
  logic                  s_valid=0, s_ready, s_last=0;
  logic [WORD_W-1:0]     s_data=0;
  logic                  m_valid, m_ready=1, m_last, m_off;
  logic [WORD_W-1:0]     m_data;
  logic                  send_req=0, send_busy;
  logic [SLOT_ID_W-1:0]  send_slot=0;

  // slot-file <-> nif
  logic sf_alloc_req, sf_alloc_gnt;
  logic [SLOT_ID_W-1:0] sf_alloc_slot;
  logic sf_wr_en, sf_commit_en, sf_ack_en;
  logic [SLOT_ID_W-1:0] sf_wr_slot, sf_commit_slot, sf_ack_slot, sf_rd_slot;
  logic [$clog2(SLOT_WORDS)-1:0] sf_wr_woff, sf_rd_woff;
  logic [WORD_W-1:0] sf_wr_data, sf_rd_data;
  logic [N_SLOTS_MAX-1:0] free_mask, ready_mask;
  logic nif_busy;

  // consumer-free strobe (driven by TB to model dispatch done)
  logic done_en=0; logic [SLOT_ID_W-1:0] done_slot=0;

  mb_slot_file u_sf (
    .clk, .rst, .slot_limit,
    .alloc_req(sf_alloc_req), .alloc_gnt(sf_alloc_gnt), .alloc_slot(sf_alloc_slot),
    .wr_en(sf_wr_en), .wr_slot(sf_wr_slot), .wr_woff(sf_wr_woff), .wr_data(sf_wr_data),
    .commit_en(sf_commit_en), .commit_slot(sf_commit_slot),
    .done_en, .done_slot,
    .ack_en(sf_ack_en), .ack_slot(sf_ack_slot),
    .rd_slot(sf_rd_slot), .rd_woff(sf_rd_woff), .rd_data(sf_rd_data),
    .free_mask, .ready_mask
  );

  mb_nif u_nif (
    .clk, .rst, .my_y(8'd0), .my_x(8'd0), .slot_limit,
    .s_valid, .s_ready, .s_data, .s_last,
    .m_valid, .m_ready, .m_data, .m_last, .m_off_array(m_off),
    .send_req, .send_slot, .send_busy,
    .sf_alloc_req, .sf_alloc_gnt, .sf_alloc_slot,
    .sf_wr_en, .sf_wr_slot, .sf_wr_woff, .sf_wr_data,
    .sf_commit_en, .sf_commit_slot,
    .sf_ack_en, .sf_ack_slot,
    .sf_rd_slot, .sf_rd_woff, .sf_rd_data,
    .free_mask, .ready_mask, .nif_busy
  );

  // AXI-Stream master: drive a packet of n words (word0 first)
  task automatic send_packet(input logic [WORD_W-1:0] w [4], input int n);
    for (int i = 0; i < n; i++) begin
      @(negedge clk); s_valid = 1; s_data = w[i]; s_last = (i == n-1);
      @(posedge clk); while (!s_ready) @(posedge clk);
    end
    @(negedge clk); s_valid = 0; s_last = 0;
  endtask

  // helper: build a word0
  function automatic logic [WORD_W-1:0] mkw0(int sz);
    word0_t s; s = '0; s.size_words = sz[SIZE_W-1:0]; return pack_w0(s);
  endfunction

  // ===================== DUT B: signal_port =============================
  logic                  sp_dep=0; word0_t sp_w0;
  logic [DST_SLOT_W-1:0] sp_dst; logic [WORD_W-1:0] sp_val;
  logic                  sp_par; logic [BRAM_OFS_W-1:0] sp_rbase;
  logic                  sp_we;  logic [BANK_ID_W-1:0] sp_sel;
  logic [BRAM_OFS_W-1:0] sp_addr; logic [WORD_W-1:0] sp_wdata;

  mb_signal_port u_port (
    .clk, .dep_valid(sp_dep), .dep_w0(sp_w0), .dep_dst_slot(sp_dst), .dep_value(sp_val),
    .cycle_parity(sp_par), .region_base(sp_rbase),
    .bram_we(sp_we), .bram_sel(sp_sel), .bram_addr(sp_addr), .bram_wdata(sp_wdata)
  );

  // ===================== DUT C: barrier ================================
  localparam int NC = 4;
  logic [NC-1:0] core_busy=0, nif_busy_v=0;
  logic q, adv, par;
  mb_barrier #(.N_CORES(NC), .HOLD(3)) u_bar (
    .clk, .rst, .core_busy, .nif_busy(nif_busy_v),
    .n_sent('0), .n_deliv('0), .quiescent(q), .cycle_advance(adv), .cycle_parity(par)
  );

  // ===================== DUT D: router + a destination tile =============
  localparam int RN = 4, RY = 2, RX = 2;          // 2x2; dst (1,0) -> out index 2
  logic [RN-1:0]             rin_valid=0, rin_last=0, rin_off=0, rin_ready;
  logic [RN-1:0][WORD_W-1:0] rin_data=0;
  logic [RN-1:0]             rout_valid, rout_last, rout_ready;
  logic [RN-1:0][WORD_W-1:0] rout_data;
  logic                      regr_valid, regr_last, regr_ready=1, egr_seen=0;
  logic [WORD_W-1:0]         regr_data;

  mb_router #(.N_CORES(RN), .ARRAY_Y(RY), .ARRAY_X(RX)) u_rt (
    .clk, .rst,
    .in_valid(rin_valid), .in_ready(rin_ready), .in_data(rin_data),
    .in_last(rin_last), .in_off(rin_off),
    .out_valid(rout_valid), .out_ready(rout_ready), .out_data(rout_data), .out_last(rout_last),
    .egr_valid(regr_valid), .egr_ready(regr_ready), .egr_data(regr_data), .egr_last(regr_last)
  );
  always @(posedge clk) if (regr_valid && regr_ready) egr_seen <= 1;
  assign rout_ready[0] = 1'b1;
  assign rout_ready[1] = 1'b1;
  assign rout_ready[3] = 1'b1;

  // destination tile (NIF+slot_file) hanging off router output port 2 = (1,0)
  logic dsf_alloc_req, dsf_alloc_gnt; logic [SLOT_ID_W-1:0] dsf_alloc_slot;
  logic dsf_wr_en, dsf_commit_en, dsf_ack_en;
  logic [SLOT_ID_W-1:0] dsf_wr_slot, dsf_commit_slot, dsf_ack_slot, dsf_rd_slot;
  logic [$clog2(SLOT_WORDS)-1:0] dsf_wr_woff, dsf_rd_woff;
  logic [WORD_W-1:0] dsf_wr_data, dsf_rd_data;
  logic [N_SLOTS_MAX-1:0] dfree, dready;
  logic dnif_busy, dsend_busy, dm_valid, dm_last, dm_off; logic [WORD_W-1:0] dm_data;

  mb_slot_file u_dsf (
    .clk, .rst, .slot_limit(5'd8),
    .alloc_req(dsf_alloc_req), .alloc_gnt(dsf_alloc_gnt), .alloc_slot(dsf_alloc_slot),
    .wr_en(dsf_wr_en), .wr_slot(dsf_wr_slot), .wr_woff(dsf_wr_woff), .wr_data(dsf_wr_data),
    .commit_en(dsf_commit_en), .commit_slot(dsf_commit_slot),
    .done_en(1'b0), .done_slot('0),
    .ack_en(dsf_ack_en), .ack_slot(dsf_ack_slot),
    .rd_slot(dsf_rd_slot), .rd_woff(dsf_rd_woff), .rd_data(dsf_rd_data),
    .free_mask(dfree), .ready_mask(dready)
  );
  mb_nif u_dnif (
    .clk, .rst, .my_y(8'd1), .my_x(8'd0), .slot_limit(5'd8),
    .s_valid(rout_valid[2]), .s_ready(rout_ready[2]), .s_data(rout_data[2]), .s_last(rout_last[2]),
    .m_valid(dm_valid), .m_ready(1'b1), .m_data(dm_data), .m_last(dm_last), .m_off_array(dm_off),
    .send_req(1'b0), .send_slot('0), .send_busy(dsend_busy),
    .sf_alloc_req(dsf_alloc_req), .sf_alloc_gnt(dsf_alloc_gnt), .sf_alloc_slot(dsf_alloc_slot),
    .sf_wr_en(dsf_wr_en), .sf_wr_slot(dsf_wr_slot), .sf_wr_woff(dsf_wr_woff), .sf_wr_data(dsf_wr_data),
    .sf_commit_en(dsf_commit_en), .sf_commit_slot(dsf_commit_slot),
    .sf_ack_en(dsf_ack_en), .sf_ack_slot(dsf_ack_slot),
    .sf_rd_slot(dsf_rd_slot), .sf_rd_woff(dsf_rd_woff), .sf_rd_data(dsf_rd_data),
    .free_mask(dfree), .ready_mask(dready), .nif_busy(dnif_busy)
  );

  // router input driver (AXI master on port `port`)
  task automatic rt_send(input int port, input logic [WORD_W-1:0] w [4],
                         input int n, input bit off);
    for (int i = 0; i < n; i++) begin
      @(negedge clk); rin_valid[port]=1; rin_data[port]=w[i];
      rin_last[port]=(i==n-1); rin_off[port]=off;
      @(posedge clk); while (!rin_ready[port]) @(posedge clk);
    end
    @(negedge clk); rin_valid[port]=0; rin_last[port]=0;
  endtask

  function automatic logic [WORD_W-1:0] mkw0d(int sz, int dy, int dx, bit off);
    word0_t s; s='0; s.size_words=sz[SIZE_W-1:0];
    s.dst_y=dy[DST_W-1:0]; s.dst_x=dx[DST_W-1:0]; s.off_array=off; return pack_w0(s);
  endfunction

  // ===================== stimulus ======================================
  logic [WORD_W-1:0] pkt [4];
  logic [WORD_W-1:0] pkt2a [4], pkt2b [4];
  initial begin
    repeat (3) @(posedge clk); @(negedge clk); rst = 0;

    $display("\n[1] NIF rx: deposit a 2-word packet");
    pkt[0] = mkw0(1) | 32'h0;        // word0, size_words=1
    pkt[1] = 32'hCAFEF00D;           // payload
    send_packet(pkt, 2);
    repeat (3) @(posedge clk);
    chk(ready_mask[0] == 1'b1,        "slot 0 POSTED (ready)");
    chk(free_mask[0]  == 1'b0,        "slot 0 not free");
    chk(u_sf.mem[0*SLOT_WORDS+1] == 32'hCAFEF00D, "payload stored in slot 0 word1");

    $display("\n[2] backpressure: fill the file, s_ready must drop");
    for (int k = 0; k < LIM-1; k++) send_packet(pkt, 2);   // slots 1..3
    repeat (2) @(posedge clk);
    chk((free_mask & 4'hF) == 4'h0,   "all 4 slots used");
    @(negedge clk); s_valid = 1; s_data = mkw0(0); s_last = 1;
    @(posedge clk);
    chk(s_ready == 1'b0,              "s_ready low when full (backpressure)");
    @(negedge clk); s_valid = 0;

    $display("\n[3] consumer free: done clears ready, sets free");
    @(negedge clk); done_en = 1; done_slot = 0;
    @(posedge clk); @(negedge clk); done_en = 0;
    @(posedge clk);
    chk(ready_mask[0] == 1'b0,        "slot 0 ready cleared");
    chk(free_mask[0]  == 1'b1,        "slot 0 freed");

    $display("\n[4] NIF tx: doorbell streams slot 1 out egress");
    @(negedge clk); send_req = 1; send_slot = 1;
    @(posedge clk); @(negedge clk); send_req = 0;
    fork begin : tx_watch
      int beats = 0;
      repeat (20) begin
        @(posedge clk); if (m_valid && m_ready) beats++;
        if (beats > 0 && !send_busy) break;
      end
      chk(beats >= 1,                 "egress produced >=1 beat");
    end join

    $display("\n[5] signal_port address math");
    // addr_mode=0: absolute -> addr = offset
    sp_w0 = '0; sp_w0.addr_mode = 0; sp_dst = {5'h3, 11'h2A0}; sp_rbase = 11'h100; sp_par = 0;
    #1; chk(sp_sel == 5'h3 && sp_addr == 11'h2A0, "addr_mode=0: bank_id + absolute offset");
    // addr_mode=1: region_base+offset, REGION_SEL_BIT = op[0]^parity
    sp_w0.addr_mode = 1; sp_w0.op = 6'b000001;     // active/inactive bit = 1
    sp_dst = {5'h3, 11'h020}; sp_rbase = 11'h100; sp_par = 0;
    #1; chk(sp_addr[REGION_SEL_BIT] == (1 ^ 0),    "addr_mode=1: region bit = op[0]^parity (parity0)");
    sp_par = 1;
    #1; chk(sp_addr[REGION_SEL_BIT] == (1 ^ 1),    "addr_mode=1: region bit flips with parity");

    $display("\n[6] barrier: quiescent -> cycle_parity flips after HOLD");
    @(negedge clk); core_busy = 4'b0010;            // busy
    repeat (4) @(posedge clk);
    chk(q == 1'b0,                   "not quiescent while a core is busy");
    @(negedge clk); core_busy = 0;                  // all idle
    begin logic p0; p0 = par;
      repeat (8) @(posedge clk);
      chk(par != p0,                 "cycle_parity flipped after quiescence+HOLD");
    end

    $display("\n[7] router: in[0] -> dst (1,0) lands in the destination tile's mailbox");
    pkt[0] = mkw0d(1,1,0,0); pkt[1] = 32'hABCD1234;
    rt_send(0, pkt, 2, 0);
    repeat (8) @(posedge clk);
    chk(|dready,                       "destination tile has a POSTED slot");
    chk(u_dsf.mem[1] == 32'hABCD1234,  "destination slot 0 word1 holds the routed payload");

    $display("\n[8] router: off_array packet -> egress");
    pkt[0] = mkw0d(0,0,0,1);
    rt_send(1, pkt, 1, 1);
    repeat (4) @(posedge clk);
    chk(egr_seen,                      "egress saw the off_array packet");

    $display("\n[9] router arbitration: in[0] + in[3] both -> dst (1,0)");
    fork
      begin pkt2a[0]=mkw0d(1,1,0,0); pkt2a[1]=32'h11111111; rt_send(0, pkt2a, 2, 0); end
      begin pkt2b[0]=mkw0d(1,1,0,0); pkt2b[1]=32'h22222222; rt_send(3, pkt2b, 2, 0); end
    join
    repeat (10) @(posedge clk);
    chk($countones(dready) >= 3,       "both arbitrated packets delivered (>=3 ready total)");

    $display("\n==== errors = %0d ====", errors);
    if (errors == 0) $display("ALL PASS");
    $finish;
  end

  // safety timeout
  initial begin repeat (2000) @(posedge clk); $display("TIMEOUT"); $finish; end

endmodule
