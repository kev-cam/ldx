// sockit_jtag_top.v — SoCKit harness with a JTAG (ISSP) host bridge: the host
// drives DUT ingress and drains egress over quartus_stp, no HPS Linux needed.
// Self-loads prog_sha.mif (broadcast), then free-runs; TB-on-host over JTAG.
//
// ISSP map (instance "SHA"):
//   sources[33:0]: [33]=in_toggle (flip=inject word), [32]=pop_toggle
//                  (flip=pop egress FIFO), [31:0]=in_word (payload)
//   probes[49:0]:  [49:48]=st, [47]=quiescent, [46:39]=in_ack (packets
//                  accepted, mod 256), [38:32]=egr_cnt, [31:0]=egr head word
//
// Ingress = 2-beat packet to tile (0,0): word0=0x1 (dst 0,0 size=1), word1=
// payload. Beats are held COMBINATIONALLY until valid&&ready (the registered-
// output ingress FSM bug from the ZCU104 bring-up, not repeated here).
// Runs at the raw 50 MHz crystal — one new variable at a time.
`default_nettype none
module sockit_jtag_top #(
  parameter integer ARRAY_Y = 2,
  parameter integer ARRAY_X = 2,
  parameter integer MEM_WORDS = 4096,
  parameter integer NW = 1817,
  parameter HEXFILE = "mb_sha.hex"
)(
  input wire clk_50
);
  wire clk = clk_50;

  // power-on reset
  reg [9:0] por = 10'd0;
  wire por_done = por[9];
  always @(posedge clk) if (!por[9]) por <= por + 10'd1;

  // program ROM, init from HEXFILE (plain hex words, one per line)
  reg [31:0] rom [0:2047];
  initial $readmemh(HEXFILE, rom);

  // loader FSM: hold -> broadcast-load -> settle -> run
  reg [1:0]  st;
  reg [11:0] la, laddr_o;
  reg        lwe, arr_rst, cpu_hold;
  reg [31:0] ld;

  wire quiescent, cycle_advance, cycle_parity;
  wire egr_valid, egr_last;
  wire [31:0] egr_data;
  wire ingr_ready;

  always @(posedge clk) begin
    if (!por_done) begin
      st<=2'd0; la<=12'd0; laddr_o<=12'd0; lwe<=1'b0; ld<=32'd0;
      arr_rst<=1'b1; cpu_hold<=1'b1;
    end else case (st)
      2'd0: begin arr_rst<=1'b0; cpu_hold<=1'b1; la<=12'd0; lwe<=1'b0; st<=2'd1; end
      2'd1: begin
        lwe<=1'b1; laddr_o<=la; ld<=rom[la[10:0]];   // registered -> aligned next cycle
        if (la == NW-1) st<=2'd2;
        la <= la + 12'd1;
      end
      2'd2: begin lwe<=1'b0; st<=2'd3; end
      2'd3: cpu_hold<=1'b0;                          // release; workers free-run
    endcase
  end

  // ISSP host bridge
  wire [33:0] src;
  reg [2:0] in_tgl_s, pop_tgl_s;
  always @(posedge clk) begin
    in_tgl_s  <= {in_tgl_s[1:0],  src[33]};
    pop_tgl_s <= {pop_tgl_s[1:0], src[32]};
  end
  wire in_kick  = in_tgl_s[2]  ^ in_tgl_s[1];
  wire pop_kick = pop_tgl_s[2] ^ pop_tgl_s[1];

  // ingress FSM: 0=idle, 1=header beat, 2=payload beat (combinational outputs)
  localparam [31:0] HDR00 = 32'h0000_0001;           // dst (0,0), size=1
  reg [1:0]  ist;
  reg [31:0] iword;
  reg [7:0]  in_ack;
  wire        ingr_valid = (ist != 2'd0);
  wire [31:0] ingr_data  = (ist == 2'd1) ? HDR00 : iword;
  wire        ingr_last  = (ist == 2'd2);
  always @(posedge clk) begin
    if (!por_done) begin ist<=2'd0; iword<=32'd0; in_ack<=8'd0; end
    else case (ist)
      2'd0: if (in_kick && st==2'd3) begin iword<=src[31:0]; ist<=2'd1; end
      2'd1: if (ingr_ready) ist<=2'd2;
      2'd2: if (ingr_ready) begin ist<=2'd0; in_ack<=in_ack+8'd1; end
      default: ist<=2'd0;
    endcase
  end

  // egress FIFO (64 deep), payload words only (drop the routing header word)
  reg        egr_hdr;
  reg [31:0] fifo [0:63];
  reg [5:0]  wp, rp;
  reg [6:0]  cnt;
  reg [31:0] head_q;
  wire push = egr_valid && !egr_hdr && (cnt != 7'd64);
  wire pop  = pop_kick && (cnt != 7'd0);
  always @(posedge clk) begin
    if (!por_done) begin egr_hdr<=1'b1; wp<=6'd0; rp<=6'd0; cnt<=7'd0; head_q<=32'd0; end
    else begin
      if (push) begin fifo[wp]<=egr_data; wp<=wp+6'd1; end
      if (egr_valid) egr_hdr <= egr_last;
      if (pop) rp<=rp+6'd1;
      cnt <= cnt + (push ? 7'd1 : 7'd0) - (pop ? 7'd1 : 7'd0);
      head_q <= fifo[pop ? rp+6'd1 : rp];
    end
  end

  mb_array_soc #(.ARRAY_Y(ARRAY_Y), .ARRAY_X(ARRAY_X), .HOST_INGRESS(1),
                 .USE_HWROUTER(1), .MEM_WORDS(MEM_WORDS), .RAM_STYLE("block")) u_arr (
    .clk(clk), .reset(arr_rst),
    .load_we(lwe), .load_addr(laddr_o), .load_data(ld), .cpu_rst_req(cpu_hold),
    .egr_valid(egr_valid), .egr_ready(1'b1), .egr_data(egr_data), .egr_last(egr_last),
    .ingr_valid(ingr_valid), .ingr_ready(ingr_ready), .ingr_data(ingr_data), .ingr_last(ingr_last),
    .cycle_parity(cycle_parity), .cycle_advance(cycle_advance), .quiescent(quiescent)
  );

  // cycle timestamps of first/last egress payload word (exact, host-free timing)
  reg [31:0] cyccnt, t_first, t_last;
  reg seen_first;
  always @(posedge clk) begin
    if (!por_done) begin cyccnt<=32'd0; t_first<=32'd0; t_last<=32'd0; seen_first<=1'b0; end
    else begin
      cyccnt <= cyccnt + 32'd1;
      if (push && !seen_first) begin t_first<=cyccnt; seen_first<=1'b1; end
      if (push) t_last<=cyccnt;
    end
  end

  wire [113:0] probe = {t_last, t_first, st, quiescent, in_ack, cnt, head_q};
  altsource_probe #(
    .sld_auto_instance_index("YES"), .sld_instance_index(0),
    .instance_id("SHA"), .probe_width(114), .source_width(34),
    .source_initial_value("0"), .enable_metastability("NO")
  ) issp (.probe(probe), .source(src));
endmodule
`default_nettype wire
