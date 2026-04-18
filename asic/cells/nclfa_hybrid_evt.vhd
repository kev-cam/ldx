-- nclfa_hybrid_evt.vhd — Structural NCL FA using IV-table-grade
-- hybrid_evt cells. Same wiring as nclfa_nn_hybrid; swaps in
-- zone-switched resistor cells for reliable multi-stage behaviour.

library ieee;
use ieee.math_real.all;
use work.logic3d_types_pkg.all;
use work.logic3ds_pkg.all;
use work.logic3da_pkg.all;

entity nclfa_hybrid_evt is
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
    vdd_drv_coh : out logic3da;
    vdd_drv_col : out logic3da;
    vdd_drv_sh  : out logic3da;
    vdd_drv_sl  : out logic3da
  );
end entity;

architecture struct of nclfa_hybrid_evt is
  constant ZERO_L3DA : logic3da := (voltage => 0.0, resistance => 0.0,
                                    flags => AFL_KNOWN);

  signal coH_net : resolved_logic3da := ZERO_L3DA;
  signal coL_net : resolved_logic3da := ZERO_L3DA;

  signal s_coH_drv : logic3da := ZERO_L3DA;
  signal s_coL_drv : logic3da := ZERO_L3DA;
  signal s_coH_cap : real := 0.0;
  signal s_coL_cap : real := 0.0;

begin
  u_coh : entity work.th23_hybrid_evt
    port map (A => aH, B => bH, C => ciH,
              VDD => VDD, VSS => VSS,
              Y_drv => s_coH_drv, Y_cap => s_coH_cap, VDD_drv => vdd_drv_coh);

  u_col : entity work.th23_hybrid_evt
    port map (A => aL, B => bL, C => ciL,
              VDD => VDD, VSS => VSS,
              Y_drv => s_coL_drv, Y_cap => s_coL_cap, VDD_drv => vdd_drv_col);

  coH_net <= s_coH_drv;
  coL_net <= s_coL_drv;
  coH_drv <= s_coH_drv;
  coH_cap <= s_coH_cap;
  coL_drv <= s_coL_drv;
  coL_cap <= s_coL_cap;

  u_sh : entity work.th34w2_hybrid_evt
    port map (A => coL_net, B => aH, C => bH, D => ciH,
              VDD => VDD, VSS => VSS,
              Y_drv => sH_drv, Y_cap => sH_cap, VDD_drv => vdd_drv_sh);

  u_sl : entity work.th34w2_hybrid_evt
    port map (A => coH_net, B => aL, C => bL, D => ciL,
              VDD => VDD, VSS => VSS,
              Y_drv => sL_drv, Y_cap => sL_cap, VDD_drv => vdd_drv_sl);
end architecture;
