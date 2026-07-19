// mailbox_pkg.sv — shared types/constants for the Mailbox array fabric.
// See ../../../../doc/mailbox.md for the architecture. The fabric is pure
// routing + addressing; op[29:24] is TARGET-SPECIFIC and never decoded here
// except for the single active/inactive bit the signal port needs.

`ifndef MAILBOX_PKG_SV
`define MAILBOX_PKG_SV

package mailbox_pkg;

  // ---- fabric-wide sizing (synthesis-time) ---------------------------------
  localparam int WORD_W      = 32;            // mailbox word width
  localparam int N_SLOTS_MAX = 32;            // <=32 so masks fit one RV32 word
  localparam int SLOT_WORDS  = 4;             // words per slot (header + payload)
  localparam int SLOT_ID_W   = $clog2(N_SLOTS_MAX);          // 5
  localparam int SIZE_W      = 8;             // size_words field

  // flat destination namespace
  localparam int DST_W       = 8;             // per-axis (dst_y, dst_x)
  localparam int ADDR_HANDLE_W = 2*DST_W;     // 16-bit off-array handle

  // ---- Word 0 layout (the fabric's ONLY header commitment) -----------------
  //  [31]     off_array    sign bit -> bltz
  //  [30]     addr_mode    0: absolute BRAM offset | 1: region_base-relative
  //  [29:24]  op           TARGET-SPECIFIC (fabric opaque, routed whole off-array)
  //  [23:16]  dst_y        on-array y | high byte of off-array handle
  //  [15:8]   dst_x        on-array x | low  byte of off-array handle
  //  [7:0]    size_words   count of following payload words (0..SLOT_WORDS-1)
  localparam int W0_OFF_ARRAY = 31;
  localparam int W0_ADDR_MODE = 30;
  localparam int W0_OP_HI     = 29;
  localparam int W0_OP_LO     = 24;
  localparam int W0_DSTY_HI   = 23;
  localparam int W0_DSTY_LO   = 16;
  localparam int W0_DSTX_HI   = 15;
  localparam int W0_DSTX_LO   = 8;
  localparam int W0_SIZE_HI   = 7;
  localparam int W0_SIZE_LO   = 0;
  localparam int OP_W         = W0_OP_HI - W0_OP_LO + 1;     // 6

  typedef struct packed {
    logic                 off_array;
    logic                 addr_mode;
    logic [OP_W-1:0]      op;          // target-specific
    logic [DST_W-1:0]     dst_y;
    logic [DST_W-1:0]     dst_x;
    logic [SIZE_W-1:0]    size_words;
  } word0_t;

  function automatic word0_t unpack_w0(input logic [WORD_W-1:0] w);
    unpack_w0.off_array  = w[W0_OFF_ARRAY];
    unpack_w0.addr_mode  = w[W0_ADDR_MODE];
    unpack_w0.op         = w[W0_OP_HI:W0_OP_LO];
    unpack_w0.dst_y      = w[W0_DSTY_HI:W0_DSTY_LO];
    unpack_w0.dst_x      = w[W0_DSTX_HI:W0_DSTX_LO];
    unpack_w0.size_words = w[W0_SIZE_HI:W0_SIZE_LO];
  endfunction

  function automatic logic [WORD_W-1:0] pack_w0(input word0_t s);
    pack_w0 = '0;
    pack_w0[W0_OFF_ARRAY]        = s.off_array;
    pack_w0[W0_ADDR_MODE]        = s.addr_mode;
    pack_w0[W0_OP_HI:W0_OP_LO]   = s.op;
    pack_w0[W0_DSTY_HI:W0_DSTY_LO]= s.dst_y;
    pack_w0[W0_DSTX_HI:W0_DSTX_LO]= s.dst_x;
    pack_w0[W0_SIZE_HI:W0_SIZE_LO]= s.size_words;
  endfunction

  // ---- LOGIC-SIM personality: the only op bit the fabric port consumes -----
  // The active/inactive selector. Positioned so the signal port can XOR the
  // free-running cycle parity straight into the region-select address bit.
  // (Personalities other than logic-sim are free to reuse op[] differently;
  //  a non-banked personality simply never sets addr_mode=1.)
  localparam int OP_ACTIVE_INACTIVE = 0;      // op[0]

  // ---- consumer signal-store geometry (the banked BRAM array) --------------
  // dst_slot (a payload word) addresses inside the consumer:
  //   [DST_SLOT_W-1 : BRAM_OFS_W]  bank_id  -> which BRAM (FIXED, never flips)
  //   [BRAM_OFS_W-1 : 0]           offset   -> within the BRAM
  localparam int DST_SLOT_W  = 16;
  localparam int BRAM_OFS_W  = 11;            // 2K words / BRAM (placeholder)
  localparam int BANK_ID_W   = DST_SLOT_W - BRAM_OFS_W;
  // region-select bit within the offset for addr_mode=1 (active vs inactive).
  localparam int REGION_SEL_BIT = BRAM_OFS_W - 1;

endpackage

`endif
