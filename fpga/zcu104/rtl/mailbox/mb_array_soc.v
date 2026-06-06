// mb_array_soc.v — M2: ARRAY_Y x ARRAY_X real VexRiscv SoC nodes
// (ldx_soc_mailbox) around mb_router + mb_barrier. One program is broadcast to
// every node's BRAM (the ring worker self-computes its peer from MY_YX).
// cycle_parity / cycle_advance are broadcast from the barrier; core_busy is the
// worker-driven busy flag (| ready), in-flight credits gate the advance.

`timescale 1ns/1ps
`include "mailbox_pkg.sv"

module mb_array_soc
  import mailbox_pkg::*;
#(
  parameter int ARRAY_Y = 4,
  parameter int ARRAY_X = 4
) (
  input  logic clk,
  input  logic reset,

  // broadcast program load (host writes every node's BRAM while held in reset)
  input  logic        load_we,
  input  logic [9:0]  load_addr,
  input  logic [31:0] load_data,
  input  logic        cpu_rst_req,

  // off-array egress (from the router)
  output logic                 egr_valid,
  input  logic                 egr_ready,
  output logic [WORD_W-1:0]    egr_data,
  output logic                 egr_last,

  // observability
  output logic                 cycle_parity,
  output logic                 cycle_advance,
  output logic                 quiescent
);
  localparam int N_CORES = ARRAY_Y * ARRAY_X;

  logic [N_CORES-1:0]              t_s_valid, t_s_ready, t_s_last;
  logic [N_CORES-1:0][WORD_W-1:0]  t_s_data;
  logic [N_CORES-1:0]              t_m_valid, t_m_ready, t_m_last, t_m_off;
  logic [N_CORES-1:0][WORD_W-1:0]  t_m_data;
  logic [N_CORES-1:0]              t_core_busy, t_nif_busy, t_pkt_sent, t_pkt_deliv;

  genvar gy, gx;
  generate
    for (gy = 0; gy < ARRAY_Y; gy++) begin : row
      for (gx = 0; gx < ARRAY_X; gx++) begin : col
        localparam int I = gy*ARRAY_X + gx;
        ldx_soc_mailbox #(.MY_X(gx[3:0]), .MY_Y(gy[3:0])) node (
          .clk(clk), .reset(reset),
          .load_we(load_we), .load_addr(load_addr), .load_data(load_data),
          .cpu_rst_req(cpu_rst_req),
          .m_valid(t_m_valid[I]), .m_ready(t_m_ready[I]), .m_data(t_m_data[I]),
          .m_last(t_m_last[I]), .m_off_array(t_m_off[I]),
          .s_valid(t_s_valid[I]), .s_ready(t_s_ready[I]), .s_data(t_s_data[I]),
          .s_last(t_s_last[I]),
          .cycle_parity(cycle_parity), .cycle_advance(cycle_advance),
          .core_busy(t_core_busy[I]), .nif_busy(t_nif_busy[I]),
          .pkt_sent(t_pkt_sent[I]), .pkt_deliv(t_pkt_deliv[I])
        );
      end
    end
  endgenerate

  mb_router #(.N_CORES(N_CORES), .ARRAY_Y(ARRAY_Y), .ARRAY_X(ARRAY_X)) u_router (
    .clk(clk), .rst(reset),
    .in_valid(t_m_valid), .in_ready(t_m_ready), .in_data(t_m_data),
    .in_last(t_m_last),   .in_off(t_m_off),
    .out_valid(t_s_valid), .out_ready(t_s_ready), .out_data(t_s_data),
    .out_last(t_s_last),
    .egr_valid(egr_valid), .egr_ready(egr_ready), .egr_data(egr_data), .egr_last(egr_last)
  );

  logic [$clog2(N_CORES+1)-1:0] n_sent_c, n_deliv_c;
  always_comb begin
    n_sent_c = '0; n_deliv_c = '0;
    for (int i = 0; i < N_CORES; i++) begin
      n_sent_c  += t_pkt_sent[i];
      n_deliv_c += t_pkt_deliv[i];
    end
  end

  mb_barrier #(.N_CORES(N_CORES)) u_barrier (
    .clk(clk), .rst(reset),
    .core_busy(t_core_busy), .nif_busy(t_nif_busy),
    .n_sent(n_sent_c), .n_deliv(n_deliv_c),
    .quiescent(quiescent), .cycle_advance(cycle_advance), .cycle_parity(cycle_parity)
  );

endmodule
