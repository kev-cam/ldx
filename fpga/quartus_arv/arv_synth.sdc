create_clock -name clk_50 -period 20.000 [get_ports clk_50]
# `phase` is bit 23 of a 24-bit counter clocked by clk_50, so it toggles
# every 2^23 = 8388608 clk_50 cycles. Treat it as a generated clock for
# the ARV CPU's register-to-register paths.
create_generated_clock -name phase -source [get_ports clk_50] \
    -divide_by 16777216 [get_registers phase]
derive_clock_uncertainty
