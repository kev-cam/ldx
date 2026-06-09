// mb_fifo.sv — synchronous first-word-fall-through FIFO for the mesh links.
// Carries one mailbox word + its `last` marker per entry. ram_style="block" puts
// the storage in the dual-port BRAM that the URAM memory move freed up — this is
// the per-input-port buffer on each N/S/E/W inter-core connection. FWFT so the
// router sees the head word combinationally (m_valid/m_data) and pops with m_ready.
module mb_fifo #(
  parameter int W     = 33,        // payload width (data[31:0] + last)
  parameter int DEPTH = 512        // RAMB18 = 512 deep; smaller folds to LUTRAM
) (
  input  wire          clk,
  input  wire          rst,
  input  wire          s_valid,
  input  wire [W-1:0]  s_data,
  output wire          s_ready,
  output wire          m_valid,
  output wire [W-1:0]  m_data,
  input  wire          m_ready
);
  localparam int AW = $clog2(DEPTH);
  (* ram_style = "block" *) reg [W-1:0] mem [0:DEPTH-1];
  reg [AW:0] wptr, rptr;            // one extra bit to distinguish full vs empty
  wire full   = (wptr[AW] != rptr[AW]) && (wptr[AW-1:0] == rptr[AW-1:0]);
  wire stored = (wptr != rptr);     // at least one committed word still in BRAM
  wire wr     = s_valid && !full;
  assign s_ready = !full;

  always @(posedge clk) begin
    if (rst) wptr <= '0;
    else if (wr) begin mem[wptr[AW-1:0]] <= s_data; wptr <= wptr + 1'b1; end
  end

  // FWFT output stage: prefetch the head into dout (1-cycle BRAM read latency,
  // hidden because dout holds the head until the consumer pops it).
  reg [W-1:0] dout;
  reg         dout_valid;
  wire        pop = stored && (!dout_valid || m_ready);   // refill when head is empty/consumed
  always @(posedge clk) begin
    if (rst) begin rptr <= '0; dout_valid <= 1'b0; end
    else begin
      if (dout_valid && m_ready) dout_valid <= 1'b0;       // head consumed this cycle
      if (pop) begin
        dout       <= mem[rptr[AW-1:0]];
        rptr       <= rptr + 1'b1;
        dout_valid <= 1'b1;                                // (overrides the clear above)
      end
    end
  end
  assign m_valid = dout_valid;
  assign m_data  = dout;
endmodule
