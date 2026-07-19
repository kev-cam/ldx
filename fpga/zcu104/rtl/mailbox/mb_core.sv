// mb_core.sv — BEHAVIORAL placeholder core (throwaway; swap for RV32 + the real
// event-processing loop later). Stands in to exercise the fabric + barrier
// cadence end-to-end. Per simulated cycle it runs a tiny ring "personality":
//   * send one message to the next core ((id+1) mod N) via the NIF direct path
//   * drain every ready mailbox slot: read it, deposit the payload to the
//     signal BRAM, free the slot, count the receive
//   * report busy until it has BOTH sent and received this cycle (the recv-gate
//     also stands in for in-flight credits — the barrier can't advance until
//     every core's expected message has actually arrived)
// cycle_advance (from the barrier) starts the next simulated cycle.

`include "mailbox_pkg.sv"

module mb_core
  import mailbox_pkg::*;
#(
  parameter int N_CORES = 16,
  parameter int ARRAY_X = 4
) (
  input  logic                     clk,
  input  logic                     rst,
  input  logic [$clog2(N_CORES)-1:0] my_id,
  input  logic                     cycle_advance,

  // drain side (slot file)
  input  logic [N_SLOTS_MAX-1:0]   ready_mask,
  output logic [SLOT_ID_W-1:0]     rd_slot,
  output logic [$clog2(SLOT_WORDS)-1:0] rd_woff,
  input  logic [WORD_W-1:0]        rd_data,
  output logic                     done_en,
  output logic [SLOT_ID_W-1:0]     done_slot,

  // send side (NIF direct 2-word)
  output logic                     ds_valid,
  output logic [WORD_W-1:0]        ds_w0,
  output logic [WORD_W-1:0]        ds_d1,
  input  logic                     ds_ack,

  // deposit side (signal port)
  output logic                     dep_valid,
  output word0_t                   dep_w0,
  output logic [DST_SLOT_W-1:0]    dep_dst_slot,
  output logic [WORD_W-1:0]        dep_value,

  output logic                     core_busy,
  output logic [15:0]              recv_total      // observability
);
  localparam int IDW = $clog2(N_CORES);

  // ---- ring peer (next core) -> (y,x) -------------------------------------
  wire [IDW-1:0]   peer_id = (my_id == N_CORES-1) ? '0 : my_id + 1'b1;
  wire [DST_W-1:0] peer_y  = peer_id / ARRAY_X;
  wire [DST_W-1:0] peer_x  = peer_id % ARRAY_X;

  // ---- per-cycle state -----------------------------------------------------
  logic        started, sent, sending;

  // ---- send: hold ds_valid until ack --------------------------------------
  word0_t sw0;
  always_comb begin
    sw0 = '0; sw0.dst_y = peer_y; sw0.dst_x = peer_x; sw0.size_words = 8'd1;
  end
  assign ds_valid = sending && !ds_ack;   // drop on ack so the NIF can't re-fire
  assign ds_w0    = pack_w0(sw0);
  assign ds_d1    = {{(WORD_W-16){1'b0}}, my_id} | (32'd1 << 24);  // tag + sender id

  // ---- drain: lowest ready slot, one per clock ----------------------------
  logic [SLOT_ID_W-1:0] rdy_slot; logic rdy_any;
  always_comb begin
    rdy_any = |ready_mask; rdy_slot = '0;
    for (int i = N_SLOTS_MAX-1; i >= 0; i--) if (ready_mask[i]) rdy_slot = i[SLOT_ID_W-1:0];
  end
  wire drain_fire = rdy_any;

  assign rd_slot   = rdy_slot;
  assign rd_woff   = 1;                       // payload word
  assign done_en   = drain_fire;
  assign done_slot = rdy_slot;

  // deposit the received payload into signal BRAM[0][my_id] (absolute)
  always_comb begin dep_w0 = '0; dep_w0.addr_mode = 1'b0; end
  assign dep_dst_slot = {{(DST_SLOT_W-IDW){1'b0}}, my_id};
  assign dep_value    = rd_data;
  assign dep_valid    = drain_fire;

  // ---- busy: done once we've sent and drained our incoming. The barrier's
  // in-flight credits (not a per-core message-count guess) hold the cycle open
  // until every sent packet has actually been delivered + consumed.
  assign core_busy = !sent || sending || rdy_any;

  always_ff @(posedge clk) begin
    if (rst) begin
      started <= 1'b0; sent <= 1'b0; sending <= 1'b0; recv_total <= '0;
    end else begin
      started <= 1'b1;
      if (drain_fire) recv_total <= recv_total + 1'b1;
      if (sending && ds_ack)              begin sending <= 1'b0; sent <= 1'b1; end
      else if (started && !sent && !sending) sending <= 1'b1;     // kick this cycle's send
      if (cycle_advance) begin sent <= 1'b0; sending <= 1'b0; end // next cycle
    end
  end

endmodule
