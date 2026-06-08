// mb_array_top.v — PL top for the ZCU104: the 8x8 mailbox mesh + an AXI4-Lite
// slave so the ARM PS drives it (program-load, host-ingress, egress, control).
//
// NB: synth_8x8.tcl synthesizes mb_array_soc directly for utilization. This top
// is the bitstream wrapper; the AXI4-Lite slave is standard but UNTESTED here
// (no Vivado in the dev env) — verify on a Vivado machine. Register map (AXI-Lite,
// byte offsets, 32-bit):
//   0x00 CTRL   W : [0]=array reset (1=hold)  [1]=cpu_rst_req (1=hold cores in reset)
//   0x04 LOADA  W : program load address (word index); auto-increments on LOADD write
//   0x08 LOADD  W : write -> load this word at LOADA into every node's BRAM, LOADA++
//   0x0C INGRW0 W : host-ingress packet word0 (dst_y,dst_x,size)
//   0x10 INGRD1 W : write -> inject a 2-beat ingress packet {INGRW0, this}
//   0x14 EGR    R : pop one egress word from the FIFO (read DUT outputs)
//   0x18 STATUS R : [0]=egr fifo not-empty [1]=quiescent [2]=ingr busy [3]=egr fifo full
//   0x1C CYCCNT R : count of barrier cycle_advance pulses
module mb_array_top #(
  parameter integer ARRAY_Y   = 8,
  parameter integer ARRAY_X   = 8,
  parameter integer MEM_WORDS = 4096
)(
  input  wire        s_axi_aclk,
  input  wire        s_axi_aresetn,
  input  wire [11:0] s_axi_awaddr,  input  wire s_axi_awvalid, output reg  s_axi_awready,
  input  wire [31:0] s_axi_wdata,   input  wire [3:0] s_axi_wstrb,
  input  wire        s_axi_wvalid,  output reg  s_axi_wready,
  output reg  [1:0]  s_axi_bresp,   output reg  s_axi_bvalid,  input  wire s_axi_bready,
  input  wire [11:0] s_axi_araddr,  input  wire s_axi_arvalid, output reg  s_axi_arready,
  output reg  [31:0] s_axi_rdata,   output reg  [1:0] s_axi_rresp,
  output reg         s_axi_rvalid,  input  wire s_axi_rready
);
  localparam WORD_W = 32;
  wire clk  = s_axi_aclk;
  wire rstn = s_axi_aresetn;

  // ---- registers (written only by the AXI write block) ------------------
  reg        arr_reset, cpu_rst_req;
  reg [9:0]  load_addr;
  reg [31:0] load_data;  reg load_we;
  reg [31:0] ingr_w0, ingr_pay;
  reg        ingr_fire;                 // 1-cycle pulse -> ingress FSM
  reg [31:0] cyc_cnt;

  // ---- the array --------------------------------------------------------
  wire egr_valid, egr_last;  wire [WORD_W-1:0] egr_data;  wire egr_ready;
  reg  ingr_valid, ingr_last; reg [WORD_W-1:0] ingr_data; wire ingr_ready;
  wire cycle_parity, cycle_advance, quiescent;

  mb_array_soc #(.ARRAY_Y(ARRAY_Y), .ARRAY_X(ARRAY_X),
                 .HOST_INGRESS(1), .USE_MESH(1), .MEM_WORDS(MEM_WORDS)) u_array (
    .clk(clk), .reset(arr_reset || !rstn),
    .load_we(load_we), .load_addr(load_addr), .load_data(load_data),
    .cpu_rst_req(cpu_rst_req),
    .egr_valid(egr_valid), .egr_ready(egr_ready), .egr_data(egr_data), .egr_last(egr_last),
    .ingr_valid(ingr_valid), .ingr_ready(ingr_ready), .ingr_data(ingr_data), .ingr_last(ingr_last),
    .cycle_parity(cycle_parity), .cycle_advance(cycle_advance), .quiescent(quiescent)
  );
  always @(posedge clk) if (!rstn) cyc_cnt<=0; else if (cycle_advance) cyc_cnt<=cyc_cnt+1;

  // ---- egress FIFO (driven only here) -----------------------------------
  localparam EAW = 10;
  reg [WORD_W-1:0] efifo [0:(1<<EAW)-1];
  reg [EAW-1:0] ehead, etail;
  wire efull  = ((etail+1'b1) == ehead);
  wire eempty = (ehead == etail);
  assign egr_ready = !efull;
  wire egr_pop;                          // from the read block
  always @(posedge clk) if (!rstn) begin ehead<=0; etail<=0; end else begin
    if (egr_valid && egr_ready) begin efifo[etail]<=egr_data; etail<=etail+1'b1; end
    if (egr_pop && !eempty) ehead<=ehead+1'b1;
  end

  // ---- ingress FSM (drives ingr_*; reads ingr_fire) ---------------------
  reg [1:0] ingr_st;                     // 0 idle, 1 word0, 2 payload
  wire ingr_busy = (ingr_st != 2'd0) || ingr_fire;
  always @(posedge clk) if (!rstn) begin
    ingr_st<=0; ingr_valid<=0; ingr_last<=0; ingr_data<=0;
  end else case (ingr_st)
    2'd0: begin ingr_valid<=1'b0; ingr_last<=1'b0; if (ingr_fire) ingr_st<=2'd1; end
    2'd1: begin ingr_valid<=1'b1; ingr_data<=ingr_w0;  ingr_last<=1'b0;
                if (ingr_ready) ingr_st<=2'd2; end
    2'd2: begin ingr_valid<=1'b1; ingr_data<=ingr_pay; ingr_last<=1'b1;
                if (ingr_ready) begin ingr_st<=2'd0; ingr_valid<=1'b0; ingr_last<=1'b0; end end
    default: ingr_st<=2'd0;
  endcase

  // ======================================================================
  // AXI4-Lite write channel (drives the control/load/ingress registers)
  // ======================================================================
  reg aw_seen, w_seen; reg [11:0] awaddr_q; reg [31:0] wdata_q;
  always @(posedge clk) if (!rstn) begin
    s_axi_awready<=0; s_axi_wready<=0; s_axi_bvalid<=0; s_axi_bresp<=0;
    aw_seen<=0; w_seen<=0; arr_reset<=1; cpu_rst_req<=1;
    load_addr<=0; load_we<=0; ingr_w0<=0; ingr_pay<=0; ingr_fire<=0;
  end else begin
    load_we<=1'b0; ingr_fire<=1'b0;
    if (s_axi_awvalid && !aw_seen) begin s_axi_awready<=1; awaddr_q<=s_axi_awaddr; aw_seen<=1; end
    else s_axi_awready<=0;
    if (s_axi_wvalid && !w_seen)  begin s_axi_wready<=1;  wdata_q<=s_axi_wdata;  w_seen<=1;  end
    else s_axi_wready<=0;
    if (aw_seen && w_seen && !s_axi_bvalid) begin
      case (awaddr_q[7:2])
        6'h00: begin arr_reset<=wdata_q[0]; cpu_rst_req<=wdata_q[1]; end
        6'h01: load_addr<=wdata_q[9:0];
        6'h02: begin load_data<=wdata_q; load_we<=1'b1; load_addr<=load_addr+1'b1; end
        6'h03: ingr_w0<=wdata_q;
        6'h04: begin ingr_pay<=wdata_q; ingr_fire<=1'b1; end
        default: ;
      endcase
      s_axi_bvalid<=1; s_axi_bresp<=2'b00; aw_seen<=0; w_seen<=0;
    end else if (s_axi_bvalid && s_axi_bready) s_axi_bvalid<=0;
  end

  // ======================================================================
  // AXI4-Lite read channel (drives egr_pop)
  // ======================================================================
  reg [11:0] araddr_q; reg egr_pop_r;
  assign egr_pop = egr_pop_r;
  always @(posedge clk) if (!rstn) begin
    s_axi_arready<=0; s_axi_rvalid<=0; s_axi_rresp<=0; s_axi_rdata<=0; egr_pop_r<=0;
  end else begin
    egr_pop_r<=1'b0;
    if (s_axi_arvalid && !s_axi_arready && !s_axi_rvalid) begin
      s_axi_arready<=1; araddr_q<=s_axi_araddr;
    end else s_axi_arready<=0;
    if (s_axi_arready) begin
      s_axi_rvalid<=1; s_axi_rresp<=2'b00;
      case (araddr_q[7:2])
        6'h05: begin s_axi_rdata<=efifo[ehead]; egr_pop_r<=1'b1; end           // EGR
        6'h06: s_axi_rdata<={28'b0, efull, ingr_busy, quiescent, !eempty};     // STATUS
        6'h07: s_axi_rdata<=cyc_cnt;                                           // CYCCNT
        default: s_axi_rdata<=32'b0;
      endcase
    end else if (s_axi_rvalid && s_axi_rready) s_axi_rvalid<=0;
  end
endmodule
