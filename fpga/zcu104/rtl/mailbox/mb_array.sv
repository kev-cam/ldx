// mb_array.sv — top of the mailbox processor array: ARRAY_Y x ARRAY_X tiles,
// a wormhole router over the flat (dst_y,dst_x) namespace, and one barrier.
// cycle_parity / cycle_advance are broadcast from the barrier to every tile.

`include "mailbox_pkg.sv"

module mb_array
  import mailbox_pkg::*;
#(
  parameter int ARRAY_Y = 4,
  parameter int ARRAY_X = 4
) (
  input  logic clk,
  input  logic rst,

  // egress NIF to host / off-cluster (off_array traffic)
  output logic                 egr_valid,
  input  logic                 egr_ready,
  output logic [WORD_W-1:0]    egr_data,
  output logic                 egr_last,

  // observability
  output logic                 cycle_parity,
  output logic                 cycle_advance,
  output logic                 quiescent,
  output logic [ARRAY_Y*ARRAY_X-1:0][15:0] recv_total
);
  localparam int N_CORES = ARRAY_Y * ARRAY_X;
  localparam int IDW     = $clog2(N_CORES);

  logic [N_CORES-1:0]                 t_s_valid, t_s_ready, t_s_last;
  logic [N_CORES-1:0][WORD_W-1:0]     t_s_data;
  logic [N_CORES-1:0]                 t_m_valid, t_m_ready, t_m_last, t_m_off;
  logic [N_CORES-1:0][WORD_W-1:0]     t_m_data;
  logic [N_CORES-1:0]                 t_core_busy, t_nif_busy, t_pkt_sent, t_pkt_deliv;

  genvar gy, gx;
  generate
    for (gy = 0; gy < ARRAY_Y; gy++) begin : row
      for (gx = 0; gx < ARRAY_X; gx++) begin : col
        localparam int I = gy*ARRAY_X + gx;
        mb_tile #(.N_CORES(N_CORES), .ARRAY_X(ARRAY_X)) u_tile (
          .clk, .rst,
          .my_y(gy[DST_W-1:0]), .my_x(gx[DST_W-1:0]), .my_id(I[IDW-1:0]),
          .cycle_parity, .cycle_advance,
          .s_valid(t_s_valid[I]), .s_ready(t_s_ready[I]),
          .s_data (t_s_data[I]),  .s_last (t_s_last[I]),
          .m_valid(t_m_valid[I]), .m_ready(t_m_ready[I]),
          .m_data (t_m_data[I]),  .m_last (t_m_last[I]),
          .m_off_array(t_m_off[I]),
          .core_busy(t_core_busy[I]), .nif_busy(t_nif_busy[I]),
          .pkt_sent(t_pkt_sent[I]), .pkt_deliv(t_pkt_deliv[I]),
          .recv_total(recv_total[I])
        );
      end
    end
  endgenerate

  mb_router #(.N_CORES(N_CORES), .ARRAY_Y(ARRAY_Y), .ARRAY_X(ARRAY_X)) u_router (
    .clk, .rst,
    .in_valid(t_m_valid), .in_ready(t_m_ready), .in_data(t_m_data),
    .in_last(t_m_last),   .in_off(t_m_off),
    .out_valid(t_s_valid), .out_ready(t_s_ready), .out_data(t_s_data),
    .out_last(t_s_last),
    .egr_valid, .egr_ready, .egr_data, .egr_last
  );

  // in-flight credits: popcount the per-NIF sent/delivered pulses this cycle.
  logic [$clog2(N_CORES+1)-1:0] n_sent_c, n_deliv_c;
  always_comb begin
    n_sent_c = '0; n_deliv_c = '0;
    for (int i = 0; i < N_CORES; i++) begin
      n_sent_c  += t_pkt_sent[i];
      n_deliv_c += t_pkt_deliv[i];
    end
  end

  mb_barrier #(.N_CORES(N_CORES)) u_barrier (
    .clk, .rst,
    .core_busy(t_core_busy), .nif_busy(t_nif_busy),
    .n_sent(n_sent_c), .n_deliv(n_deliv_c),
    .quiescent, .cycle_advance, .cycle_parity
  );

endmodule
