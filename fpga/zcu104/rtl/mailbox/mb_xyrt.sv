// mb_xyrt.sv — per-tile hardware router for the mailbox mesh.
//
// Dimension-ordered XY wormhole routing, deadlock-free on a 2D mesh. A packet
// whose dst is THIS tile ejects to the local core (port L); otherwise the router
// forwards it toward the destination on N/S/E/W with NO core involvement — so a
// hung core never blocks transit traffic. Off-array packets route toward tile
// (0,0) and eject at EGR there.
//
// Ports (uniform 6-wide; the mesh ties off directions/host/egr a tile lacks):
//   inputs  i: 0=N 1=S 2=E 3=W 4=L(core send) 5=H(host, tile 0)
//   outputs o: 0=N 1=S 2=E 3=W 4=L(core recv) 5=EGR(off-array, tile 0)
// The link FIFOs live in the mesh between routers and break the cross-tile
// combinational valid/ready paths; this block is pure routing + wormhole locks.
`include "mailbox_pkg.sv"

module mb_xyrt
  import mailbox_pkg::*;
#(
  parameter int MY_Y = 0,
  parameter int MY_X = 0,
  parameter int ARRAY_Y = 8,
  parameter int ARRAY_X = 8
) (
  input  wire                     clk,
  input  wire                     rst,
  input  wire [5:0]               iv,
  input  wire [5:0][WORD_W-1:0]   idata,
  input  wire [5:0]               ilast,
  output logic [5:0]              iready,
  output logic [5:0]              ov,
  output logic [5:0][WORD_W-1:0]  odata,
  output logic [5:0]              olast,
  input  wire [5:0]               oready
);
  localparam int OUT_N=0, OUT_S=1, OUT_E=2, OUT_W=3, OUT_L=4, OUT_EGR=5;

  // desired output port for input i, decoding its head word0 (valid when idle)
  function automatic logic [2:0] xy_route(input logic [WORD_W-1:0] w);
    word0_t w0 = unpack_w0(w);
    logic off = w0.off_array | (w0.dst_y >= ARRAY_Y[DST_W-1:0])
                             | (w0.dst_x >= ARRAY_X[DST_W-1:0]);
    if (off)                                   // off-array: head to (0,0) then egr
      xy_route = (MY_X != 0) ? OUT_W[2:0] : (MY_Y != 0) ? OUT_N[2:0] : OUT_EGR[2:0];
    else if (w0.dst_x > MY_X[DST_W-1:0]) xy_route = OUT_E[2:0];
    else if (w0.dst_x < MY_X[DST_W-1:0]) xy_route = OUT_W[2:0];
    else if (w0.dst_y > MY_Y[DST_W-1:0]) xy_route = OUT_S[2:0];
    else if (w0.dst_y < MY_Y[DST_W-1:0]) xy_route = OUT_N[2:0];
    else                                 xy_route = OUT_L[2:0];
  endfunction

  // per-output wormhole lock: lk_v[o] held, lk_src[o] = the granted input port
  logic [5:0]      lk_v;
  logic [2:0]      lk_src [6];

  // an input is busy (mid-packet) iff some output is locked to it
  logic [5:0] busy;
  always_comb begin
    busy = '0;
    for (int o = 0; o < 6; o++) if (lk_v[o]) busy[lk_src[o]] = 1'b1;
  end

  // desired output of each input when idle (its head is a word0)
  logic [2:0] want [6];
  always_comb for (int i = 0; i < 6; i++) want[i] = xy_route(idata[i]);

  // datapath: a locked output streams its source input's head
  always_comb begin
    ov = '0; odata = '{default:'0}; olast = '0; iready = '0;
    for (int o = 0; o < 6; o++) begin
      if (lk_v[o]) begin
        int s = lk_src[o];
        ov[o]    = iv[s];
        odata[o] = idata[s];
        olast[o] = ilast[s];
        if (oready[o]) iready[s] = 1'b1;     // pop the source FIFO as the beat leaves
      end
    end
  end

  // arbitration + lock update (fixed priority: lowest input index wins an output)
  always_ff @(posedge clk) begin
    if (rst) begin
      lk_v <= '0;
      for (int o = 0; o < 6; o++) lk_src[o] <= '0;
    end else begin
      for (int o = 0; o < 6; o++) begin
        if (lk_v[o]) begin
          // release after the last beat of the locked packet transfers
          if (iv[lk_src[o]] && oready[o] && ilast[lk_src[o]]) lk_v[o] <= 1'b0;
        end else begin
          // grant: lowest idle input whose head wants this output (iterate
          // high→low so index 0 is the last NBA write and therefore wins)
          for (int i = 5; i >= 0; i--)
            if (iv[i] && !busy[i] && want[i] == o[2:0]) begin
              lk_v[o]   <= 1'b1;
              lk_src[o] <= i[2:0];
            end
        end
      end
    end
  end
endmodule
