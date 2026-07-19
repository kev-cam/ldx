// mb_tile.sv — one array tile: behavioral core + slot file + NIF + signal port
// + banked signal BRAM. Wiring for the simple (direct-send) core:
//   slot file is incoming-only: NIF rx allocates/writes/commits; the core reads
//   ready slots and frees them. The core sends via the NIF direct 2-word path
//   and deposits received values through the signal port. No port contention.

`include "mailbox_pkg.sv"

module mb_tile
  import mailbox_pkg::*;
#(
  parameter int N_CORES = 16,
  parameter int ARRAY_X = 4,
  parameter int N_BRAMS = 4
) (
  input  logic                  clk,
  input  logic                  rst,
  input  logic [DST_W-1:0]      my_y,
  input  logic [DST_W-1:0]      my_x,
  input  logic [$clog2(N_CORES)-1:0] my_id,
  input  logic                  cycle_parity,
  input  logic                  cycle_advance,

  // tile network links (to the router)
  input  logic                  s_valid, output logic s_ready,
  input  logic [WORD_W-1:0]     s_data,  input  logic s_last,
  output logic                  m_valid, input  logic m_ready,
  output logic [WORD_W-1:0]     m_data,  output logic m_last,
  output logic                  m_off_array,

  output logic                  core_busy,
  output logic                  nif_busy,
  output logic                  pkt_sent,
  output logic                  pkt_deliv,
  output logic [15:0]           recv_total
);
  logic [SLOT_ID_W:0]    slot_limit  = N_SLOTS_MAX;
  logic [BRAM_OFS_W-1:0] region_base = '0;

  // ---- slot file <-> NIF / core wires --------------------------------------
  logic                      sf_alloc_req, sf_alloc_gnt;
  logic [SLOT_ID_W-1:0]      sf_alloc_slot;
  logic                      sf_wr_en, sf_commit_en;
  logic [SLOT_ID_W-1:0]      sf_wr_slot, sf_commit_slot;
  logic [$clog2(SLOT_WORDS)-1:0] sf_wr_woff;
  logic [WORD_W-1:0]         sf_wr_data;
  logic [N_SLOTS_MAX-1:0]    free_mask, ready_mask;

  // core <-> slot file (read/free)
  logic                      c_done_en;
  logic [SLOT_ID_W-1:0]      c_done_slot, c_rd_slot;
  logic [$clog2(SLOT_WORDS)-1:0] c_rd_woff;
  logic [WORD_W-1:0]         c_rd_data;

  // core <-> NIF (direct send)
  logic                      ds_valid, ds_ack;
  logic [WORD_W-1:0]         ds_w0, ds_d1;

  // core <-> signal port (deposit)
  logic                      dep_valid;
  word0_t                    dep_w0;
  logic [DST_SLOT_W-1:0]     dep_dst_slot;
  logic [WORD_W-1:0]         dep_value;

  mb_slot_file u_sf (
    .clk, .rst, .slot_limit,
    .alloc_req(sf_alloc_req), .alloc_gnt(sf_alloc_gnt), .alloc_slot(sf_alloc_slot),
    .wr_en(sf_wr_en), .wr_slot(sf_wr_slot), .wr_woff(sf_wr_woff), .wr_data(sf_wr_data),
    .commit_en(sf_commit_en), .commit_slot(sf_commit_slot),
    .done_en(c_done_en), .done_slot(c_done_slot),
    .ack_en(1'b0), .ack_slot('0),
    .rd_slot(c_rd_slot), .rd_woff(c_rd_woff), .rd_data(c_rd_data),
    .free_mask, .ready_mask
  );

  mb_nif u_nif (
    .clk, .rst, .my_y, .my_x, .slot_limit,
    .s_valid, .s_ready, .s_data, .s_last,
    .m_valid, .m_ready, .m_data, .m_last, .m_off_array,
    .send_req(1'b0), .send_slot('0), .send_busy(),
    .ds_valid, .ds_w0, .ds_d1, .ds_ack,
    .sf_alloc_req, .sf_alloc_gnt, .sf_alloc_slot,
    .sf_wr_en, .sf_wr_slot, .sf_wr_woff, .sf_wr_data,
    .sf_commit_en, .sf_commit_slot,
    .sf_ack_en(), .sf_ack_slot(),
    .sf_rd_slot(), .sf_rd_woff(), .sf_rd_data('0),     // slot-based tx unused here
    .free_mask, .ready_mask, .nif_busy,
    .pkt_sent, .pkt_deliv
  );

  mb_core #(.N_CORES(N_CORES), .ARRAY_X(ARRAY_X)) u_core (
    .clk, .rst, .my_id, .cycle_advance,
    .ready_mask,
    .rd_slot(c_rd_slot), .rd_woff(c_rd_woff), .rd_data(c_rd_data),
    .done_en(c_done_en), .done_slot(c_done_slot),
    .ds_valid, .ds_w0, .ds_d1, .ds_ack,
    .dep_valid, .dep_w0, .dep_dst_slot, .dep_value,
    .core_busy, .recv_total
  );

  // ---- deposit -> signal BRAM port B ---------------------------------------
  logic                   bram_we;
  logic [BANK_ID_W-1:0]   bram_sel;
  logic [BRAM_OFS_W-1:0]  bram_addr;
  logic [WORD_W-1:0]      bram_wdata;

  mb_signal_port u_port (
    .clk,
    .dep_valid, .dep_w0, .dep_dst_slot, .dep_value,
    .cycle_parity, .region_base,
    .bram_we, .bram_sel, .bram_addr, .bram_wdata
  );

  (* ram_style = "block" *)
  logic [WORD_W-1:0] sig_bram [N_BRAMS][2**BRAM_OFS_W];
  always_ff @(posedge clk)
    if (bram_we) sig_bram[bram_sel][bram_addr] <= bram_wdata;

endmodule
