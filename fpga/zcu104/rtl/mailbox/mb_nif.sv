// mb_nif.sv — network interface for one core: AXI-Stream rx/tx against the
// slot file. One 32-bit word per beat; word 0 first, then size_words payload.
//
//   RX: allocate a FREE slot, stream words in, commit -> raise ready, emit a
//       delivery-ack back to the sender.  Backpressure tready when no free slot.
//   TX: on a send doorbell, read the slot out beat-by-beat; route on-array vs
//       egress by off_array / dst range; free the slot on delivery-ack.
//
// Acks and barrier control travel as ordinary op-only packets; routing of the
// whole packet (incl. off_array) is the router's job — see mb_router.

`include "mailbox_pkg.sv"

module mb_nif
  import mailbox_pkg::*;
#(
  parameter int WORDS = SLOT_WORDS
) (
  input  logic                     clk,
  input  logic                     rst,

  input  logic [DST_W-1:0]         my_y,
  input  logic [DST_W-1:0]         my_x,
  input  logic [SLOT_ID_W:0]       slot_limit,

  // ---- ingress AXI-Stream (from router) ------------------------------------
  input  logic                     s_valid,
  output logic                     s_ready,
  input  logic [WORD_W-1:0]        s_data,
  input  logic                     s_last,

  // ---- egress AXI-Stream (to router) ---------------------------------------
  output logic                     m_valid,
  input  logic                     m_ready,
  output logic [WORD_W-1:0]        m_data,
  output logic                     m_last,
  output logic                     m_off_array,   // sideband for the router

  // ---- send doorbell from the core (slot-based, variable length) ----------
  input  logic                     send_req,
  input  logic [SLOT_ID_W-1:0]     send_slot,
  output logic                     send_busy,

  // ---- direct 2-word send (word0 + one payload) — used by the simple core --
  input  logic                     ds_valid,
  input  logic [WORD_W-1:0]        ds_w0,
  input  logic [WORD_W-1:0]        ds_d1,
  output logic                     ds_ack,

  // ---- slot-file handle ----------------------------------------------------
  output logic                     sf_alloc_req,
  input  logic                     sf_alloc_gnt,
  input  logic [SLOT_ID_W-1:0]     sf_alloc_slot,
  output logic                     sf_wr_en,
  output logic [SLOT_ID_W-1:0]     sf_wr_slot,
  output logic [$clog2(WORDS)-1:0] sf_wr_woff,
  output logic [WORD_W-1:0]        sf_wr_data,
  output logic                     sf_commit_en,
  output logic [SLOT_ID_W-1:0]     sf_commit_slot,
  output logic                     sf_ack_en,
  output logic [SLOT_ID_W-1:0]     sf_ack_slot,
  output logic [SLOT_ID_W-1:0]     sf_rd_slot,
  output logic [$clog2(WORDS)-1:0] sf_rd_woff,
  input  logic [WORD_W-1:0]        sf_rd_data,
  input  logic [N_SLOTS_MAX-1:0]   free_mask,
  input  logic [N_SLOTS_MAX-1:0]   ready_mask,

  // ---- quiescence contribution --------------------------------------------
  output logic                     nif_busy,
  output logic                     pkt_sent,    // 1-clock: a tx packet's last beat left
  output logic                     pkt_deliv    // 1-clock: an rx packet committed
);

  // backpressure: no FREE slot within the limit -> stall ingress
  logic [N_SLOTS_MAX-1:0] slot_mask;
  always_comb for (int i=0;i<N_SLOTS_MAX;i++) slot_mask[i] = (i < slot_limit);
  wire have_free = |(free_mask & slot_mask);

  // ======================================================================
  // RX FSM: ALLOC -> RECV (word0..size) -> COMMIT
  // ======================================================================
  typedef enum logic [1:0] {RX_IDLE, RX_RECV, RX_COMMIT} rx_state_e;
  rx_state_e rx_state;
  logic [SLOT_ID_W-1:0]      rx_slot;
  logic [$clog2(WORDS)-1:0]  rx_woff;
  logic [SIZE_W-1:0]         rx_size;       // from word0

  assign sf_alloc_req = (rx_state == RX_IDLE) && s_valid && have_free;
  assign s_ready      = (rx_state == RX_RECV) ||
                        (rx_state == RX_IDLE && have_free && sf_alloc_gnt);

  always_ff @(posedge clk) begin
    if (rst) begin
      rx_state     <= RX_IDLE;
      sf_wr_en     <= 1'b0;
      sf_commit_en <= 1'b0;
    end else begin
      sf_wr_en     <= 1'b0;
      sf_commit_en <= 1'b0;
      case (rx_state)
        RX_IDLE:
          if (s_valid && have_free && sf_alloc_gnt) begin
            rx_slot   <= sf_alloc_slot;
            rx_woff   <= '0;
            // capture word0 (this beat) and its size
            rx_size   <= unpack_w0(s_data).size_words;
            sf_wr_en  <= 1'b1; sf_wr_slot <= sf_alloc_slot;
            sf_wr_woff<= '0;   sf_wr_data <= s_data;
            rx_woff   <= 1;
            rx_state  <= s_last ? RX_COMMIT : RX_RECV;
          end
        RX_RECV:
          if (s_valid) begin
            sf_wr_en  <= 1'b1; sf_wr_slot <= rx_slot;
            sf_wr_woff<= rx_woff; sf_wr_data <= s_data;
            rx_woff   <= rx_woff + 1;
            if (s_last) rx_state <= RX_COMMIT;
          end
        RX_COMMIT: begin
          sf_commit_en   <= 1'b1; sf_commit_slot <= rx_slot;  // POSTED + ready
          // TODO: emit delivery-ack packet back to the sender (op-only) here.
          rx_state       <= RX_IDLE;
        end
        default: rx_state <= RX_IDLE;
      endcase
    end
  end

  // ======================================================================
  // TX FSM: slot-based (send_req, variable length) OR direct 2-word (ds_valid).
  // m_valid/m_data/m_last are combinational; advance only on m_valid & m_ready.
  // ======================================================================
  typedef enum logic [2:0] {TX_IDLE, TX_HDR, TX_SEND, TX_DS0, TX_DS1} tx_state_e;
  tx_state_e tx_state;
  logic [SLOT_ID_W-1:0]     tx_slot;
  logic [$clog2(WORDS)-1:0] tx_woff;
  logic [SIZE_W-1:0]        tx_size;
  word0_t                   tx_w0;
  logic [WORD_W-1:0]        ds_w0_r, ds_d1_r;

  assign send_busy  = (tx_state != TX_IDLE);
  assign sf_rd_slot = tx_slot;
  assign sf_rd_woff = tx_woff;

  always_comb begin
    m_valid     = (tx_state inside {TX_HDR, TX_SEND, TX_DS0, TX_DS1});
    unique case (tx_state)
      TX_HDR:  begin m_data = sf_rd_data; m_last = (unpack_w0(sf_rd_data).size_words == 0); end
      TX_SEND: begin m_data = sf_rd_data; m_last = (tx_woff == tx_size); end
      TX_DS0:  begin m_data = ds_w0_r;    m_last = 1'b0; end
      TX_DS1:  begin m_data = ds_d1_r;    m_last = 1'b1; end
      default: begin m_data = '0;         m_last = 1'b0; end
    endcase
    m_off_array = (tx_state == TX_HDR)                  ? sf_rd_data[W0_OFF_ARRAY] :
                  (tx_state inside {TX_DS0, TX_DS1})    ? ds_w0_r[W0_OFF_ARRAY]    :
                                                          tx_w0.off_array;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      tx_state <= TX_IDLE; ds_ack <= 1'b0;
    end else begin
      ds_ack <= 1'b0;
      case (tx_state)
        TX_IDLE:
          if (send_req) begin tx_slot <= send_slot; tx_woff <= '0; tx_state <= TX_HDR; end
          else if (ds_valid) begin ds_w0_r <= ds_w0; ds_d1_r <= ds_d1; tx_state <= TX_DS0; end
        TX_HDR: if (m_ready) begin
          tx_w0   <= unpack_w0(sf_rd_data);
          tx_size <= unpack_w0(sf_rd_data).size_words;
          if (unpack_w0(sf_rd_data).size_words == 0) tx_state <= TX_IDLE;
          else begin tx_woff <= 1; tx_state <= TX_SEND; end
        end
        TX_SEND: if (m_ready) begin
          if (tx_woff == tx_size) tx_state <= TX_IDLE;
          else tx_woff <= tx_woff + 1;
        end
        TX_DS0: if (m_ready) tx_state <= TX_DS1;
        TX_DS1: if (m_ready) begin tx_state <= TX_IDLE; ds_ack <= 1'b1; end
        default: tx_state <= TX_IDLE;
      endcase
    end
  end

  // delivery-ack inbound frees the outgoing slot.
  // TODO: decode ack packets (op-only) off the rx path and drive sf_ack_*.
  assign sf_ack_en   = 1'b0;
  assign sf_ack_slot = '0;

  assign nif_busy = (rx_state != RX_IDLE) || (tx_state != TX_IDLE) || m_valid;

  // in-flight credits: a packet is "sent" when its last beat leaves tx, and
  // "delivered" when rx commits it. (off_array packets are delivered at the
  // egress NIF — TODO emit the deliv credit there.)
  assign pkt_sent  = m_valid && m_ready && m_last;
  assign pkt_deliv = sf_commit_en;

endmodule
