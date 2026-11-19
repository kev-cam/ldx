// de2i_av_top.v — DE2i-150 single-core validation top for arbitrary resident
// TBs (not just the counter): pre-init RAM from MEM_INIT, run the core, capture
// the first 16 mb_display values + the display count, expose over JTAG (ISSP).
// Read with quartus_stp (rd_av.tcl) and compare to `nvc -r`.
`default_nettype none
module de2i_av_top (
  input  wire clk_50
);
  reg [7:0] por = 8'd0;
  wire rstn = por[7];
  always @(posedge clk_50) if (!por[7]) por <= por + 8'd1;

  wire        soft_rst;
  wire        core_rstn = rstn & ~soft_rst;

  wire        disp_valid;
  wire [31:0] disp_data;
  wire [15:0] disp_count;
  wire [31:0] dbg_pc, dbg_iocnt;

  ldx_de2i_soc #(.MEM_WORDS(4096), .MEM_INIT("issue367.mif")) soc (
    .clk(clk_50), .rstn(core_rstn),
    .disp_valid(disp_valid), .disp_data(disp_data), .disp_count(disp_count),
    .dbg_pc(dbg_pc), .dbg_iocnt(dbg_iocnt)
  );

  // capture the first 16 display values
  reg [31:0] log [0:15];
  reg [4:0]  widx;
  always @(posedge clk_50) begin
    if (!core_rstn) widx <= 5'd0;
    else if (disp_valid && !widx[4]) begin
      log[widx[3:0]] <= disp_data;
      widx <= widx + 5'd1;
    end
  end

  reg [31:0] runcyc, donecyc; reg done;
  always @(posedge clk_50) begin
    if (!core_rstn) begin runcyc<=0; donecyc<=0; done<=0; end
    else begin
      if (!done) runcyc <= runcyc + 32'd1;
      if (!done && widx[4]) begin done<=1'b1; donecyc<=runcyc; end  // 16 captured
    end
  end

  // ISSP probe (496b, the 511b max): {disp_count, log14..log0}
  wire [495:0] probe_bus = { disp_count,
    log[14],log[13],log[12],log[11],log[10],log[9],log[8],
    log[7], log[6], log[5], log[4], log[3], log[2], log[1], log[0] };
  altsource_probe #(
    .sld_auto_instance_index("YES"), .sld_instance_index(0),
    .instance_id("DISP"), .probe_width(496), .source_width(1),
    .source_initial_value("0"), .enable_metastability("NO")
  ) issp (.probe(probe_bus), .source(soft_rst));
endmodule
`default_nettype wire
