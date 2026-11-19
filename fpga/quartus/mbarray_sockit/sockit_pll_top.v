// sockit_pll_top.v — SoCKit wrapper: 50 MHz crystal -> PLL -> 100 MHz array.
// Fmax measured 122.17 MHz (wide core, 2x2); 100 MHz leaves ~18% margin.
// de2i_arr_top's internal POR (1024 cycles) comfortably outlasts PLL lock.
`default_nettype none
module sockit_pll_top #(
  parameter integer ARRAY_Y = 2,
  parameter integer ARRAY_X = 2,
  parameter integer MEM_WORDS = 4096,
  parameter integer NW = 962
)(
  input wire clk_50
);
  wire clk_100;
  wire locked;

  altera_pll #(
    .fractional_vco_multiplier("false"),
    .reference_clock_frequency("50.0 MHz"),
    .operation_mode("direct"),
    .number_of_clocks(1),
    .output_clock_frequency0("100.000000 MHz"),
    .phase_shift0("0 ps"),
    .duty_cycle0(50),
    .pll_type("General"),
    .pll_subtype("General")
  ) u_pll (
    .refclk(clk_50),
    .rst(1'b0),
    .outclk(clk_100),
    .fboutclk(),
    .fbclk(1'b0),
    .locked(locked)
  );

  de2i_arr_top #(
    .ARRAY_Y(ARRAY_Y), .ARRAY_X(ARRAY_X),
    .MEM_WORDS(MEM_WORDS), .NW(NW)
  ) u_harness (
    .clk_50(clk_100)
  );
endmodule
`default_nettype wire
