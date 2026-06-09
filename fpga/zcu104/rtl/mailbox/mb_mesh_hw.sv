// mb_mesh_hw.sv — hardware-routed nearest-neighbor mailbox fabric.
//
// Drop-in port-compatible with mb_router / mb_mesh, but packets are forwarded
// tile-to-tile in HARDWARE (per-tile mb_xyrt, XY routing) instead of by software
// copy-through. Each N/S/E/W inter-core link is buffered by an mb_fifo in BRAM
// (the dual-port BRAM freed by moving private memory to URAM). Transit traffic
// flows through a tile independent of its core, so a hung core can't block the
// network; off-array packets route to tile 0 and exit at egress.
//
// (First version: input-buffered, single virtual channel — a packet ejecting to
// a hung core can still head-of-line-block transit sharing that input FIFO; VCs/
// VOQ are a later refinement. Still strictly better than software relay.)
`include "mailbox_pkg.sv"

module mb_mesh_hw
  import mailbox_pkg::*;
#(
  parameter int N_CORES      = 64,
  parameter int ARRAY_Y      = 8,
  parameter int ARRAY_X      = 8,
  parameter int HOST_INGRESS = 0,
  parameter int LINK_DEPTH    = 512,                  // per-link BRAM FIFO depth
  parameter int N_IN         = N_CORES + HOST_INGRESS // host (if any) at index N_CORES
) (
  input  logic                              clk,
  input  logic                              rst,
  input  logic [N_IN-1:0]                   in_valid,
  output logic [N_IN-1:0]                   in_ready,
  input  logic [N_IN-1:0][WORD_W-1:0]       in_data,
  input  logic [N_IN-1:0]                   in_last,
  input  logic [N_IN-1:0]                   in_off,    // unused: word0.off_array is authoritative
  output logic [N_CORES-1:0]                out_valid,
  input  logic [N_CORES-1:0]                out_ready,
  output logic [N_CORES-1:0][WORD_W-1:0]    out_data,
  output logic [N_CORES-1:0]                out_last,
  output logic                              egr_valid,
  input  logic                              egr_ready,
  output logic [WORD_W-1:0]                 egr_data,
  output logic                              egr_last
);
  localparam int FW = WORD_W + 1;            // FIFO payload = {last, data}
  // port indices: 0=N 1=S 2=E 3=W 4=L 5=H/EGR
  localparam int PN=0, PS=1, PE=2, PW=3, PL=4, PX=5;

  // per-tile router I/O (6 ports each)
  logic [5:0]              ri_v   [N_CORES];
  logic [5:0][WORD_W-1:0]  ri_d   [N_CORES];
  logic [5:0]              ri_l   [N_CORES];
  logic [5:0]              ri_r   [N_CORES];
  logic [5:0]              ro_v   [N_CORES];
  logic [5:0][WORD_W-1:0]  ro_d   [N_CORES];
  logic [5:0]              ro_l   [N_CORES];
  logic [5:0]              ro_r   [N_CORES];

  genvar gy, gx;
  generate
    for (gy = 0; gy < ARRAY_Y; gy++) begin : row
      for (gx = 0; gx < ARRAY_X; gx++) begin : col
        localparam int T = gy*ARRAY_X + gx;

        mb_xyrt #(.MY_Y(gy), .MY_X(gx), .ARRAY_Y(ARRAY_Y), .ARRAY_X(ARRAY_X)) u_rt (
          .clk(clk), .rst(rst),
          .iv(ri_v[T]), .idata(ri_d[T]), .ilast(ri_l[T]), .iready(ri_r[T]),
          .ov(ro_v[T]), .odata(ro_d[T]), .olast(ro_l[T]), .oready(ro_r[T])
        );

        // ---- local port: core T send -> in[T], core T recv <- out[T] ----------
        assign ri_v[T][PL] = in_valid[T];
        assign ri_d[T][PL] = in_data[T];
        assign ri_l[T][PL] = in_last[T];
        assign in_ready[T] = ri_r[T][PL];
        assign out_valid[T] = ro_v[T][PL];
        assign out_data[T]  = ro_d[T][PL];
        assign out_last[T]  = ro_l[T][PL];
        assign ro_r[T][PL]  = out_ready[T];

        // ---- host (tile 0 only) + egress (tile 0 only) ------------------------
        if (T == 0 && HOST_INGRESS != 0) begin : g_host
          assign ri_v[0][PX] = in_valid[N_CORES];
          assign ri_d[0][PX] = in_data[N_CORES];
          assign ri_l[0][PX] = in_last[N_CORES];
          assign in_ready[N_CORES] = ri_r[0][PX];
        end else begin : g_nohost
          assign ri_v[T][PX] = 1'b0;
          assign ri_d[T][PX] = '0;
          assign ri_l[T][PX] = 1'b0;
        end
        if (T == 0) begin : g_egr
          assign egr_valid = ro_v[0][PX];
          assign egr_data  = ro_d[0][PX];
          assign egr_last  = ro_l[0][PX];
          assign ro_r[0][PX] = egr_ready;
        end else begin : g_noegr
          assign ro_r[T][PX] = 1'b0;            // off-array never routes EGR off tile 0
        end

        // ---- N/S/E/W input link FIFOs (fed by the neighbor's opposite output) -
        // North input <- north neighbor's South output
        if (gy > 0) begin : g_in_n
          localparam int NB = (gy-1)*ARRAY_X + gx;
          mb_fifo #(.W(FW), .DEPTH(LINK_DEPTH)) f (.clk(clk), .rst(rst),
            .s_valid(ro_v[NB][PS]), .s_data({ro_l[NB][PS], ro_d[NB][PS]}), .s_ready(ro_r[NB][PS]),
            .m_valid(ri_v[T][PN]), .m_data({ri_l[T][PN], ri_d[T][PN]}),    .m_ready(ri_r[T][PN]));
        end else begin : g_no_n
          assign ri_v[T][PN] = 1'b0; assign ri_d[T][PN] = '0; assign ri_l[T][PN] = 1'b0;
          assign ro_r[T][PN] = 1'b0;
        end
        // South input <- south neighbor's North output
        if (gy < ARRAY_Y-1) begin : g_in_s
          localparam int NB = (gy+1)*ARRAY_X + gx;
          mb_fifo #(.W(FW), .DEPTH(LINK_DEPTH)) f (.clk(clk), .rst(rst),
            .s_valid(ro_v[NB][PN]), .s_data({ro_l[NB][PN], ro_d[NB][PN]}), .s_ready(ro_r[NB][PN]),
            .m_valid(ri_v[T][PS]), .m_data({ri_l[T][PS], ri_d[T][PS]}),    .m_ready(ri_r[T][PS]));
        end else begin : g_no_s
          assign ri_v[T][PS] = 1'b0; assign ri_d[T][PS] = '0; assign ri_l[T][PS] = 1'b0;
          assign ro_r[T][PS] = 1'b0;
        end
        // East input <- east neighbor's West output
        if (gx < ARRAY_X-1) begin : g_in_e
          localparam int NB = gy*ARRAY_X + (gx+1);
          mb_fifo #(.W(FW), .DEPTH(LINK_DEPTH)) f (.clk(clk), .rst(rst),
            .s_valid(ro_v[NB][PW]), .s_data({ro_l[NB][PW], ro_d[NB][PW]}), .s_ready(ro_r[NB][PW]),
            .m_valid(ri_v[T][PE]), .m_data({ri_l[T][PE], ri_d[T][PE]}),    .m_ready(ri_r[T][PE]));
        end else begin : g_no_e
          assign ri_v[T][PE] = 1'b0; assign ri_d[T][PE] = '0; assign ri_l[T][PE] = 1'b0;
          assign ro_r[T][PE] = 1'b0;
        end
        // West input <- west neighbor's East output
        if (gx > 0) begin : g_in_w
          localparam int NB = gy*ARRAY_X + (gx-1);
          mb_fifo #(.W(FW), .DEPTH(LINK_DEPTH)) f (.clk(clk), .rst(rst),
            .s_valid(ro_v[NB][PE]), .s_data({ro_l[NB][PE], ro_d[NB][PE]}), .s_ready(ro_r[NB][PE]),
            .m_valid(ri_v[T][PW]), .m_data({ri_l[T][PW], ri_d[T][PW]}),    .m_ready(ri_r[T][PW]));
        end else begin : g_no_w
          assign ri_v[T][PW] = 1'b0; assign ri_d[T][PW] = '0; assign ri_l[T][PW] = 1'b0;
          assign ro_r[T][PW] = 1'b0;
        end
      end
    end
  endgenerate
endmodule
