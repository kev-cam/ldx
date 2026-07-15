# Board clock is the 50 MHz crystal (no PLL in the design) — sign-off at 20 ns.
# Fmax experiment 2026-07-14 (overconstrained fits, slow 85C): wide converged
# 122.17 MHz, narrow 112.99 MHz. To run faster on silicon, add a PLL.
create_clock -name clk_50 -period 20.000 [get_ports clk_50]
derive_clock_uncertainty
