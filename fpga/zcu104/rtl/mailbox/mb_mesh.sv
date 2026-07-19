// mb_mesh.sv — nearest-neighbor mailbox fabric (replaces the flat mb_router).
//
// Mailboxes connect a tile only to its N/S/E/W neighbors (NOT a global crossbar).
// A tile may send only to an ADJACENT tile (or off-array at the host edge); the
// SOFTWARE copy-through relays distant packets hop-by-hop (see mesh/mb_relay.c).
// So each tile's ingress (eject) is a small arbiter over just its ≤4 neighbors +
// (host, at tile 0) — O(N) total, vs the flat router's O(N²). Built with generate
// over constant neighbor indices so synthesis prunes to the 4-ish-input muxes.
//
// Drop-in port-compatible with mb_router. Tile output index t = y*ARRAY_X + x.
// off_array / out-of-range packets exit at egress — reachable only from tile 0
// (interior tiles relay to tile 0 in software).

`include "mailbox_pkg.sv"

module mb_mesh
  import mailbox_pkg::*;
#(
  parameter int N_CORES      = 64,
  parameter int ARRAY_Y      = 8,
  parameter int ARRAY_X      = 8,
  parameter int HOST_INGRESS = 0,
  parameter int N_IN         = N_CORES + HOST_INGRESS   // host (if any) at index N_CORES
) (
  input  logic                              clk,
  input  logic                              rst,

  input  logic [N_IN-1:0]                   in_valid,
  output logic [N_IN-1:0]                   in_ready,
  input  logic [N_IN-1:0][WORD_W-1:0]       in_data,
  input  logic [N_IN-1:0]                   in_last,
  input  logic [N_IN-1:0]                   in_off,

  output logic [N_CORES-1:0]                out_valid,
  input  logic [N_CORES-1:0]                out_ready,
  output logic [N_CORES-1:0][WORD_W-1:0]    out_data,
  output logic [N_CORES-1:0]                out_last,

  output logic                              egr_valid,
  input  logic                              egr_ready,
  output logic [WORD_W-1:0]                 egr_data,
  output logic                              egr_last
);

  localparam int EGR = N_CORES;                  // pseudo-dst for off-array
  localparam int OW  = $clog2(N_CORES+1);

  // ---- per-input header decode + latched route (as in the flat router) -----
  logic [N_IN-1:0]    hdr_phase;
  logic [OW-1:0]      route_reg [N_IN];
  logic [OW-1:0]      cur_dst   [N_IN];
  always_comb begin
    for (int i = 0; i < N_IN; i++) begin
      word0_t w0 = unpack_w0(in_data[i]);
      logic   off = in_off[i] | w0.off_array |
                    (w0.dst_y >= ARRAY_Y[DST_W-1:0]) | (w0.dst_x >= ARRAY_X[DST_W-1:0]);
      logic [OW-1:0] dec = off ? EGR[OW-1:0] : (w0.dst_y*ARRAY_X + w0.dst_x);
      cur_dst[i] = hdr_phase[i] ? dec : route_reg[i];
    end
  end
  always_ff @(posedge clk)
    if (rst) hdr_phase <= '1;
    else for (int i = 0; i < N_IN; i++)
      if (in_valid[i] && in_ready[i]) begin
        hdr_phase[i] <= in_last[i];
        if (hdr_phase[i]) route_reg[i] <= cur_dst[i];
      end

  // ir_grant[t][i] = tile t's eject is granting input i this cycle (one-hot per t)
  logic [N_IN-1:0] ir_grant [N_CORES];

  // ---- per-tile eject arbiter (neighbors + host, NO self) ------------------
  for (genvar gy = 0; gy < ARRAY_Y; gy++) begin : row
    for (genvar gx = 0; gx < ARRAY_X; gx++) begin : col
      localparam int T  = gy*ARRAY_X + gx;
      localparam int HN = (gy > 0)          ? 1 : 0;
      localparam int HS = (gy < ARRAY_Y-1)  ? 1 : 0;
      localparam int HE = (gx < ARRAY_X-1)  ? 1 : 0;
      localparam int HW = (gx > 0)          ? 1 : 0;
      localparam int HH = ((T == 0) && (HOST_INGRESS != 0)) ? 1 : 0;
      localparam int CN = HN ? (gy-1)*ARRAY_X + gx     : T;  // neighbor global indices
      localparam int CS = HS ? (gy+1)*ARRAY_X + gx     : T;  // (safe = T when absent)
      localparam int CE = HE ? gy*ARRAY_X + (gx+1)     : T;
      localparam int CW = HW ? gy*ARRAY_X + (gx-1)     : T;
      localparam int CH = N_CORES;                            // host input index

      // a candidate requests this tile when its current route == T
      wire rN = HN && in_valid[CN] && (cur_dst[CN] == T[OW-1:0]);
      wire rS = HS && in_valid[CS] && (cur_dst[CS] == T[OW-1:0]);
      wire rE = HE && in_valid[CE] && (cur_dst[CE] == T[OW-1:0]);
      wire rW = HW && in_valid[CW] && (cur_dst[CW] == T[OW-1:0]);
      wire rH = HH && in_valid[CH] && (cur_dst[CH] == T[OW-1:0]);

      logic       lk_v;
      logic [2:0] lk_k;                 // 0=N 1=S 2=E 3=W 4=H
      logic       lk_last;
      always_comb begin                 // last-beat of the locked source transferring
        case (lk_k)
          3'd0: lk_last = in_valid[CN] && in_last[CN];
          3'd1: lk_last = in_valid[CS] && in_last[CS];
          3'd2: lk_last = in_valid[CE] && in_last[CE];
          3'd3: lk_last = in_valid[CW] && in_last[CW];
          default: lk_last = in_valid[CH] && in_last[CH];
        endcase
      end
      always_ff @(posedge clk)
        if (rst) lk_v <= 1'b0;
        else if (lk_v) begin
          if (lk_last && out_ready[T]) lk_v <= 1'b0;   // release after last beat
        end else begin                                  // arbitrate (fixed priority)
          if      (rN) begin lk_v <= 1'b1; lk_k <= 3'd0; end
          else if (rS) begin lk_v <= 1'b1; lk_k <= 3'd1; end
          else if (rE) begin lk_v <= 1'b1; lk_k <= 3'd2; end
          else if (rW) begin lk_v <= 1'b1; lk_k <= 3'd3; end
          else if (rH) begin lk_v <= 1'b1; lk_k <= 3'd4; end
        end

      always_comb begin                 // datapath: stream the locked source to out[T]
        out_valid[T] = 1'b0; out_data[T] = '0; out_last[T] = 1'b0; ir_grant[T] = '0;
        if (lk_v) begin
          case (lk_k)
            3'd0: begin out_valid[T]=in_valid[CN]; out_data[T]=in_data[CN]; out_last[T]=in_last[CN]; ir_grant[T][CN]=out_ready[T]; end
            3'd1: begin out_valid[T]=in_valid[CS]; out_data[T]=in_data[CS]; out_last[T]=in_last[CS]; ir_grant[T][CS]=out_ready[T]; end
            3'd2: begin out_valid[T]=in_valid[CE]; out_data[T]=in_data[CE]; out_last[T]=in_last[CE]; ir_grant[T][CE]=out_ready[T]; end
            3'd3: begin out_valid[T]=in_valid[CW]; out_data[T]=in_data[CW]; out_last[T]=in_last[CW]; ir_grant[T][CW]=out_ready[T]; end
            default: begin out_valid[T]=in_valid[CH]; out_data[T]=in_data[CH]; out_last[T]=in_last[CH]; ir_grant[T][CH]=out_ready[T]; end
          endcase
        end
      end
    end
  end

  // ---- egress: only tile 0 reaches the host (interior tiles relay to it) ----
  logic egr_lk;
  always_ff @(posedge clk)
    if (rst) egr_lk <= 1'b0;
    else if (egr_lk) begin
      if (in_valid[0] && in_last[0] && egr_ready) egr_lk <= 1'b0;
    end else if (in_valid[0] && (cur_dst[0] == EGR[OW-1:0])) egr_lk <= 1'b1;
  assign egr_valid = egr_lk && in_valid[0];
  assign egr_data  = in_data[0];
  assign egr_last  = in_last[0];
  wire   egr_grant = egr_lk && egr_ready;

  // ---- combine grants into in_ready (each input is granted by ≤1 tile) -----
  always_comb begin
    for (int i = 0; i < N_IN; i++) begin
      in_ready[i] = 1'b0;
      for (int t = 0; t < N_CORES; t++) in_ready[i] |= ir_grant[t][i];
    end
    in_ready[0] |= egr_grant;
  end

endmodule
