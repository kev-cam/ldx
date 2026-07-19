// mb_router.sv — wormhole crossbar over the flat (dst_y,dst_x) namespace.
//
// Per input: the first beat of a packet (header) carries word0; decode it once
// to an output port = dst_y*ARRAY_X + dst_x, or the egress port if off_array /
// out-of-range. Latch that route for the rest of the packet (until `last`).
// Per output: arbitrate among inputs requesting it (fixed priority for now —
// TODO round-robin for fairness), lock to the winner until its packet's last
// beat passes, then release. Outputs 0..N_CORES-1 = tiles; index N_CORES =
// egress (host-bridge).
//
// HOST_INGRESS (0/1): when 1, input index N_CORES is the host (ARM) ingress —
// the ARM injects packets to cores by (dst_y,dst_x), symmetric with egress. So
// the input count is N_IN = N_CORES + HOST_INGRESS; outputs are unchanged.

`include "mailbox_pkg.sv"

module mb_router
  import mailbox_pkg::*;
#(
  parameter int N_CORES      = 64,
  parameter int ARRAY_Y      = 8,
  parameter int ARRAY_X      = 8,
  parameter int HOST_INGRESS = 0,
  parameter int N_IN         = N_CORES + HOST_INGRESS   // derived; do not override
) (
  input  logic                              clk,
  input  logic                              rst,

  input  logic [N_IN-1:0]                in_valid,
  output logic [N_IN-1:0]                in_ready,
  input  logic [N_IN-1:0][WORD_W-1:0]    in_data,
  input  logic [N_IN-1:0]                in_last,
  input  logic [N_IN-1:0]                in_off,

  output logic [N_CORES-1:0]                out_valid,
  input  logic [N_CORES-1:0]                out_ready,
  output logic [N_CORES-1:0][WORD_W-1:0]    out_data,
  output logic [N_CORES-1:0]                out_last,

  output logic                              egr_valid,
  input  logic                              egr_ready,
  output logic [WORD_W-1:0]                 egr_data,
  output logic                              egr_last
);

  localparam int N_OUT  = N_CORES + 1;              // + egress
  localparam int EGR    = N_CORES;
  localparam int OW     = $clog2(N_OUT);
  localparam int IW     = (N_IN > 1) ? $clog2(N_IN) : 1;

  // ---- per-input header tracking + latched route --------------------------
  logic [N_IN-1:0]           hdr_phase;       // 1 => current/next beat is header
  logic [OW-1:0]             route_reg [N_IN];
  logic [OW-1:0]             cur_dst   [N_IN];

  always_comb begin
    for (int i = 0; i < N_IN; i++) begin
      word0_t w0 = unpack_w0(in_data[i]);
      logic   off = in_off[i] | w0.off_array |
                    (w0.dst_y >= ARRAY_Y[DST_W-1:0]) | (w0.dst_x >= ARRAY_X[DST_W-1:0]);
      logic [OW-1:0] dec = off ? EGR[OW-1:0]
                               : (w0.dst_y*ARRAY_X + w0.dst_x);
      cur_dst[i] = hdr_phase[i] ? dec : route_reg[i];
    end
  end

  // ---- per-output lock -----------------------------------------------------
  logic [N_OUT-1:0]  lk_valid;
  logic [IW-1:0]     lk_src [N_OUT];

  // which inputs are currently locked somewhere
  logic [N_IN-1:0] in_locked;
  always_comb begin
    in_locked = '0;
    for (int o = 0; o < N_OUT; o++)
      if (lk_valid[o]) in_locked[lk_src[o]] = 1'b1;
  end

  // downstream ready for each internal output
  logic [N_OUT-1:0] ord;
  always_comb begin
    for (int o = 0; o < N_CORES; o++) ord[o] = out_ready[o];
    ord[EGR] = egr_ready;
  end

  // ---- grant + hold --------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      lk_valid <= '0;
    end else begin
      for (int o = 0; o < N_OUT; o++) begin
        if (lk_valid[o]) begin
          // release when the locked input's last beat transfers
          if (in_valid[lk_src[o]] && in_ready[lk_src[o]] && in_last[lk_src[o]])
            lk_valid[o] <= 1'b0;
        end else begin
          // arbitrate: lowest-index requesting, unlocked input wins
          for (int i = N_IN-1; i >= 0; i--)
            if (in_valid[i] && !in_locked[i] && (cur_dst[i] == o[OW-1:0])) begin
              lk_valid[o] <= 1'b1;
              lk_src[o]   <= i[IW-1:0];
            end
        end
      end
    end
  end

  // ---- header phase + route latch -----------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      hdr_phase <= '1;
    end else begin
      for (int i = 0; i < N_IN; i++)
        if (in_valid[i] && in_ready[i]) begin
          hdr_phase[i] <= in_last[i];
          if (hdr_phase[i]) route_reg[i] <= cur_dst[i];
        end
    end
  end

  // ---- datapath ------------------------------------------------------------
  always_comb begin
    out_valid = '0; out_data = '0; out_last = '0;
    egr_valid = 1'b0; egr_data = '0; egr_last = 1'b0;
    in_ready  = '0;

    for (int o = 0; o < N_CORES; o++)
      if (lk_valid[o]) begin
        out_valid[o] = in_valid[lk_src[o]];
        out_data[o]  = in_data[lk_src[o]];
        out_last[o]  = in_last[lk_src[o]];
      end
    if (lk_valid[EGR]) begin
      egr_valid = in_valid[lk_src[EGR]];
      egr_data  = in_data[lk_src[EGR]];
      egr_last  = in_last[lk_src[EGR]];
    end

    // an input is ready only once its target output is locked to it
    for (int i = 0; i < N_IN; i++)
      if (lk_valid[cur_dst[i]] && (lk_src[cur_dst[i]] == i[IW-1:0]))
        in_ready[i] = ord[cur_dst[i]];
  end

endmodule
