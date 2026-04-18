-- nclfa_nn_hybrid.vhd — Structural NCL 1-bit full adder built from
-- NN-hybrid TH23 + TH34W2 cells. Wiring mirrors cells/nclfa.sp.
--
-- Dual-rail I/O. Each of the four output rails is computed by one cell:
--   coH = TH23(aH, bH, ciH)
--   coL = TH23(aL, bL, ciL)
--   sH  = TH34W2(coL, aH, bH, ciH)
--   sL  = TH34W2(coH, aL, bL, ciL)

library ieee;
use ieee.math_real.all;
use work.logic3d_types_pkg.all;
use work.logic3ds_pkg.all;
use work.logic3da_pkg.all;

entity nclfa_nn_hybrid is
  port (
    aH  : in  logic3da;
    aL  : in  logic3da;
    bH  : in  logic3da;
    bL  : in  logic3da;
    ciH : in  logic3da;
    ciL : in  logic3da;
    VDD : in  logic3da;
    VSS : in  logic3da;
    sH_drv  : out logic3da;
    sH_cap  : out real;
    sL_drv  : out logic3da;
    sL_cap  : out real;
    coH_drv : out logic3da;
    coH_cap : out real;
    coL_drv : out logic3da;
    coL_cap : out real;
    -- Per-cell supply-R drivers. Aggregator should sum these in parallel
    -- with any other cells on the same VDD net; we expose them all so the
    -- caller can resolve onto a shared VDD net if desired.
    vdd_drv_coh : out logic3da;
    vdd_drv_col : out logic3da;
    vdd_drv_sh  : out logic3da;
    vdd_drv_sl  : out logic3da
  );
end entity;

architecture struct of nclfa_nn_hybrid is
  constant ZERO_L3DA : logic3da := (voltage => 0.0, resistance => 0.0,
                                    flags => AFL_KNOWN);

  -- Internal resolved nets for the carry rails that feed both TH34W2
  -- instances as well as the output ports. The TH23 driver output gets
  -- assigned to these resolved nets; the nets are what the sum cells
  -- consume as inputs.
  signal coH_net : resolved_logic3da := ZERO_L3DA;
  signal coL_net : resolved_logic3da := ZERO_L3DA;

  signal s_coH_drv : logic3da := ZERO_L3DA;
  signal s_coL_drv : logic3da := ZERO_L3DA;
  signal s_coH_cap : real := 0.0;
  signal s_coL_cap : real := 0.0;

begin

  -- Two TH23s: carry-out high/low rails.
  u_coh : entity work.th23_nn_hybrid
    port map (A => aH, B => bH, C => ciH,
              VDD => VDD, VSS => VSS,
              Y_drv => s_coH_drv, Y_cap => s_coH_cap, VDD_drv => vdd_drv_coh);

  u_col : entity work.th23_nn_hybrid
    port map (A => aL, B => bL, C => ciL,
              VDD => VDD, VSS => VSS,
              Y_drv => s_coL_drv, Y_cap => s_coL_cap, VDD_drv => vdd_drv_col);

  coH_net <= s_coH_drv;
  coL_net <= s_coL_drv;

  coH_drv <= s_coH_drv;
  coH_cap <= s_coH_cap;
  coL_drv <= s_coL_drv;
  coL_cap <= s_coL_cap;

  -- Two TH34W2s: sum high/low rails. Weight-2 input is the cross-rail
  -- carry-out (coL feeds sH, coH feeds sL) per Fant's canonical form.
  u_sh : entity work.th34w2_nn_hybrid
    port map (A => coL_net, B => aH, C => bH, D => ciH,
              VDD => VDD, VSS => VSS,
              Y_drv => sH_drv, Y_cap => sH_cap, VDD_drv => vdd_drv_sh);

  u_sl : entity work.th34w2_nn_hybrid
    port map (A => coH_net, B => aL, C => bL, D => ciL,
              VDD => VDD, VSS => VSS,
              Y_drv => sL_drv, Y_cap => sL_cap, VDD_drv => vdd_drv_sl);

end architecture;
