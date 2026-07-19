// mb_slot_file.sv — per-core slot file: message RAM + free/ready bitmaps.
//
// Up to 32 slots so free/ready/alloc are single-word bitmap ops. Slot states:
//   FREE   free=1 ready=0
//   POSTED free=0 ready=1   (incoming, awaiting consumer dispatch)
//   BUSY   free=0 ready=0   (in-flight-out OR being processed)
//
// Mask updates arrive as one-hot set/clear strobes from the agents that own
// each transition; by construction no two strobes hit the same slot/bit in the
// same cycle (alloc picks a FREE slot, commit owns a just-allocated one, etc.).

`include "mailbox_pkg.sv"

module mb_slot_file
  import mailbox_pkg::*;
#(
  parameter int N_SLOTS   = N_SLOTS_MAX,
  parameter int WORDS     = SLOT_WORDS
) (
  input  logic                         clk,
  input  logic                         rst,

  // runtime cap: only the low slot_limit bits are live
  input  logic [SLOT_ID_W:0]           slot_limit,    // 1..32

  // ---- allocator (producer side, and NIF picks an incoming slot too) -------
  input  logic                         alloc_req,
  output logic                         alloc_gnt,
  output logic [SLOT_ID_W-1:0]         alloc_slot,

  // ---- write port (NIF incoming payload, or core outgoing payload) ---------
  input  logic                         wr_en,
  input  logic [SLOT_ID_W-1:0]         wr_slot,
  input  logic [$clog2(WORDS)-1:0]     wr_woff,
  input  logic [WORD_W-1:0]            wr_data,

  // ---- commit (NIF, after payload written): mark POSTED + raise ready ------
  input  logic                         commit_en,
  input  logic [SLOT_ID_W-1:0]         commit_slot,

  // ---- consumer dispatch done: ready->0, free->1 (csrrc/csrrs pair) --------
  input  logic                         done_en,
  input  logic [SLOT_ID_W-1:0]         done_slot,

  // ---- outgoing delivery-ack from NIF: free->1 -----------------------------
  input  logic                         ack_en,
  input  logic [SLOT_ID_W-1:0]         ack_slot,

  // ---- read port (consumer/core reads slot words) --------------------------
  input  logic [SLOT_ID_W-1:0]         rd_slot,
  input  logic [$clog2(WORDS)-1:0]     rd_woff,
  output logic [WORD_W-1:0]            rd_data,

  // ---- bitmaps exposed as CSRs to the core --------------------------------
  output logic [N_SLOTS_MAX-1:0]       free_mask,
  output logic [N_SLOTS_MAX-1:0]       ready_mask
);

  // slot_mask = low slot_limit bits set
  logic [N_SLOTS_MAX-1:0] slot_mask;
  always_comb begin
    slot_mask = '0;
    for (int i = 0; i < N_SLOTS_MAX; i++)
      slot_mask[i] = (i < slot_limit);
  end

  // ---- allocator: first free slot within the limit -------------------------
  logic [N_SLOTS_MAX-1:0] alloc_cand;
  assign alloc_cand = free_mask & slot_mask;
  always_comb begin
    alloc_gnt  = |alloc_cand;
    alloc_slot = '0;
    for (int i = N_SLOTS_MAX-1; i >= 0; i--)   // ctz via priority encoder
      if (alloc_cand[i]) alloc_slot = i[SLOT_ID_W-1:0];
  end

  // ---- free / ready bitmaps ------------------------------------------------
  // one-hot helpers
  function automatic logic [N_SLOTS_MAX-1:0] oh(input logic en,
                                                input logic [SLOT_ID_W-1:0] id);
    oh = en ? (1 << id) : '0;
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      free_mask  <= '1;     // all FREE at reset
      ready_mask <= '0;
    end else begin
      // free: cleared on alloc; set on done or delivery-ack
      free_mask  <= (free_mask  & ~oh(alloc_req & alloc_gnt, alloc_slot))
                                |  oh(done_en, done_slot)
                                |  oh(ack_en,  ack_slot);
      // ready: set on commit; cleared on done
      ready_mask <= (ready_mask | oh(commit_en, commit_slot))
                                & ~oh(done_en, done_slot);
    end
  end

  // ---- slot RAM (distributed LUTRAM) ---------------------------------------
  // flat [slot*WORDS + woff]
  localparam int DEPTH = N_SLOTS * WORDS;
  (* ram_style = "distributed" *)
  logic [WORD_W-1:0] mem [DEPTH];

  wire [$clog2(DEPTH)-1:0] wr_addr = wr_slot * WORDS + wr_woff;
  wire [$clog2(DEPTH)-1:0] rd_addr = rd_slot * WORDS + rd_woff;

  always_ff @(posedge clk)
    if (wr_en) mem[wr_addr] <= wr_data;

  assign rd_data = mem[rd_addr];   // async read (LUTRAM)

  // TODO: CSR read/write decode for free/ready/slot_limit lives in the core
  // wrapper; here we just expose the bitmaps and take strobes.

endmodule
