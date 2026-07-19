// mb_barrier.sv — array quiescence detector + cycle-parity generator.
//
// quiescent = !any_busy && in_flight==0 && !nif_busy   (doc: Quiescence)
//   any_busy  : OR of per-core (state!=WFI || ready_mask!=0)
//   in_flight : running sum of (sent - delivered) credits across the network
//   nif_busy  : OR of per-NIF tvalid-on-any-link
// Held high for one barrier-tree depth to absorb settling, then the cycle
// advances: cycle_parity flips (that single bit re-aliases active/inactive for
// every signal port) and cycle_advance pulses. No data moves; no flip packet.

module mb_barrier #(
  parameter int N_CORES   = 64,
  parameter int CREDIT_W  = 16,                 // in_flight counter width
  parameter int HOLD      = 6                   // ~ barrier-tree depth (log N)
) (
  input  logic                 clk,
  input  logic                 rst,

  input  logic [N_CORES-1:0]   core_busy,       // per-core !done
  input  logic [N_CORES-1:0]   nif_busy,        // per-NIF busy

  // network credit pulses (aggregate counts this cycle)
  input  logic [$clog2(N_CORES+1)-1:0] n_sent,
  input  logic [$clog2(N_CORES+1)-1:0] n_deliv,

  output logic                 quiescent,
  output logic                 cycle_advance,   // 1-cycle pulse at barrier
  output logic                 cycle_parity     // the free-running active/inactive bit
);

  // in-flight credit accounting
  logic [CREDIT_W-1:0] in_flight;
  always_ff @(posedge clk)
    if (rst) in_flight <= '0;
    else     in_flight <= in_flight + n_sent - n_deliv;

  wire any_busy = |core_busy;
  wire any_nif  = |nif_busy;

  // Re-engage gate: every core must have asserted core_busy since the last
  // advance before the barrier may fire again. Without this the barrier
  // double-advances during the poll-latency window (a core idle between its
  // own cycles) and CYCLE_CNT jumps by 2 per logical cycle — which breaks the
  // cycle_parity double-buffer. seen_busy clears on advance, fills as cores work.
  logic [N_CORES-1:0] seen_busy;
  always_ff @(posedge clk)
    if (rst)                seen_busy <= '0;
    else if (cycle_advance) seen_busy <= core_busy;          // clear (cores idle at advance)
    else                    seen_busy <= seen_busy | core_busy;
  wire all_engaged = &seen_busy;

  wire q_now    = all_engaged && !any_busy && (in_flight == 0) && !any_nif;

  // hold quiescent for HOLD cycles before advancing
  logic [$clog2(HOLD+1)-1:0] hold_cnt;
  always_ff @(posedge clk) begin
    if (rst) begin
      hold_cnt      <= '0;
      cycle_advance <= 1'b0;
      cycle_parity  <= 1'b0;
    end else begin
      cycle_advance <= 1'b0;
      if (q_now) begin
        if (hold_cnt == HOLD[$bits(hold_cnt)-1:0]) begin
          cycle_advance <= 1'b1;            // barrier fires
          cycle_parity  <= ~cycle_parity;   // flip the one addressing bit
          hold_cnt      <= '0;
        end else
          hold_cnt <= hold_cnt + 1;
      end else
        hold_cnt <= '0;                     // any new work restarts the hold
    end
  end

  assign quiescent = q_now;

endmodule
