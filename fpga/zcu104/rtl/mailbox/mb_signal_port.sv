// mb_signal_port.sv — port-B deposit into the consumer's banked signal BRAM.
//
// Address resolution (see doc/mailbox.md "Addressing and banking"):
//   dst_slot[hi:BRAM_OFS_W] = bank_id  -> which BRAM (FIXED, never flips)
//   dst_slot[BRAM_OFS_W-1:0]= offset   -> within the BRAM
//   addr_mode = 0 : absolute BRAM offset (config/LUT/scratchpad, non-banked)
//   addr_mode = 1 : region_base + offset, with the region-select address bit =
//                   op[ACTIVE_INACTIVE] ^ cycle_parity.
// cycle_parity is the single free-running bit that flips each (simulated) cycle,
// so "inactive" deposits this cycle are addressed as "active" next cycle —
// a double buffer by addressing alone, no data movement, no flip command.

`include "mailbox_pkg.sv"

module mb_signal_port
  import mailbox_pkg::*;
(
  input  logic                     clk,

  // deposit request (from the dedicated-BRAM path or the core dispatch)
  input  logic                     dep_valid,
  input  word0_t                   dep_w0,
  input  logic [DST_SLOT_W-1:0]    dep_dst_slot,
  input  logic [WORD_W-1:0]        dep_value,

  // global cycle parity (from the barrier) + this core's region base register
  input  logic                     cycle_parity,
  input  logic [BRAM_OFS_W-1:0]    region_base,

  // port-B write to the consumer's banked signal BRAM array
  output logic                     bram_we,
  output logic [BANK_ID_W-1:0]     bram_sel,    // which BRAM
  output logic [BRAM_OFS_W-1:0]    bram_addr,   // offset within that BRAM
  output logic [WORD_W-1:0]        bram_wdata
);

  // split the destination address
  wire [BANK_ID_W-1:0]  bank_id = dep_dst_slot[DST_SLOT_W-1 : BRAM_OFS_W];
  wire [BRAM_OFS_W-1:0] offset  = dep_dst_slot[BRAM_OFS_W-1 : 0];

  // active/inactive half, re-aliased by the free-running cycle parity
  wire region_sel = dep_w0.op[OP_ACTIVE_INACTIVE] ^ cycle_parity;

  // addr_mode mux
  logic [BRAM_OFS_W-1:0] addr_abs, addr_rel;
  assign addr_abs = offset;                       // addr_mode=0: absolute
  always_comb begin
    // addr_mode=1: region-relative; REGION_SEL_BIT carries the active/inactive
    // half. NB: exact placement (force-bit vs add-half) is locked with the
    // per-personality signal address map — see Open in the doc.
    addr_rel                 = region_base + offset;
    addr_rel[REGION_SEL_BIT] = region_sel;
  end

  assign bram_sel   = bank_id;
  assign bram_addr  = dep_w0.addr_mode ? addr_rel : addr_abs;
  assign bram_wdata = dep_value;
  assign bram_we    = dep_valid;

endmodule
