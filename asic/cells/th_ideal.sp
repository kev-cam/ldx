* th_ideal.sp — Ideal behavioral TH cells for DCOP seeding.
*
* Same pin interfaces as the transistor-level subckts in th22.sp / th_gates.sp
* so you can swap .include lines and the rest of a round netlist works
* unchanged. These cells are pure B-source threshold functions (no
* transistors, no hysteresis, no keeper), so DCOP converges trivially and
* the resulting node voltages can seed the analog sim via .IC / .NODESET.
*
* Threshold detector:  tanh((V(in) - VDD/2) * STEEP) → smooth {-1,+1}, remapped.
* Output level:        VDD if cell fires, 0 otherwise.
*
* Soft-threshold keeps transitions differentiable so the Xyce adaptive
* timestep doesn't stall at sharp edges. STEEP sets the slope; at 50 V^-1
* the 10%-90% transition width is ~44 mV.
*
* Hysteresis is deliberately omitted — we just need a consistent DC bias
* and logically-correct DATA propagation, not accurate transient edges.
*
* A logic-high input is flagged by `hi(v, vdd) = 0.5 + 0.5*tanh((v - vdd/2) * 50)`
* which is close to 1 when v>vdd/2+~30mV and 0 when v<vdd/2-~30mV.

* Smooth-threshold helpers written out inline per gate (Xyce B-source expressions
* don't support user-defined funcs portably). STEEP = 50/V. Output is VDD·sat
* where sat∈[0,1] is a smooth product/sum of per-input hi(v) values clamped.

*==============================================================================
* TH12 — OR2 (1-of-2) — output = VDD * (1 - (1-hi_A)*(1-hi_B))
*==============================================================================
.subckt th12 A B Y VDD VSS
B12 Y VSS V = { V(VDD,VSS) *
+  (1 - (1 - (0.5 + 0.5*tanh((V(A,VSS) - V(VDD,VSS)/2)*50)))
+       * (1 - (0.5 + 0.5*tanh((V(B,VSS) - V(VDD,VSS)/2)*50)))) }
.ends th12

*==============================================================================
* TH22 — AND2 — output = VDD * hi_A * hi_B
*==============================================================================
.subckt th22 A B Y VDD VSS
B22 Y VSS V = { V(VDD,VSS) *
+  (0.5 + 0.5*tanh((V(A,VSS) - V(VDD,VSS)/2)*50)) *
+  (0.5 + 0.5*tanh((V(B,VSS) - V(VDD,VSS)/2)*50)) }
.ends th22

*==============================================================================
* TH23 — 2-of-3 majority — output = VDD * (AB + AC + BC - 2ABC)
*   Soft-smooth: sum of pairwise products minus triple product
*==============================================================================
.subckt th23 A B C Y VDD VSS
B23 Y VSS V = { V(VDD,VSS) *
+   ( (0.5 + 0.5*tanh((V(A,VSS) - V(VDD,VSS)/2)*50)) *
+     (0.5 + 0.5*tanh((V(B,VSS) - V(VDD,VSS)/2)*50))
+   + (0.5 + 0.5*tanh((V(A,VSS) - V(VDD,VSS)/2)*50)) *
+     (0.5 + 0.5*tanh((V(C,VSS) - V(VDD,VSS)/2)*50))
+   + (0.5 + 0.5*tanh((V(B,VSS) - V(VDD,VSS)/2)*50)) *
+     (0.5 + 0.5*tanh((V(C,VSS) - V(VDD,VSS)/2)*50))
+   - 2 * (0.5 + 0.5*tanh((V(A,VSS) - V(VDD,VSS)/2)*50)) *
+         (0.5 + 0.5*tanh((V(B,VSS) - V(VDD,VSS)/2)*50)) *
+         (0.5 + 0.5*tanh((V(C,VSS) - V(VDD,VSS)/2)*50)) ) }
.ends th23

*==============================================================================
* TH33 — AND3 — output = VDD * hi_A * hi_B * hi_C
*==============================================================================
.subckt th33 A B C Y VDD VSS
B33 Y VSS V = { V(VDD,VSS) *
+  (0.5 + 0.5*tanh((V(A,VSS) - V(VDD,VSS)/2)*50)) *
+  (0.5 + 0.5*tanh((V(B,VSS) - V(VDD,VSS)/2)*50)) *
+  (0.5 + 0.5*tanh((V(C,VSS) - V(VDD,VSS)/2)*50)) }
.ends th33

*==============================================================================
* TH34W2 — 2A+B+C+D >= 3 — output = VDD * (A*(B+C+D-BC-BD-CD+BCD) + BCD*(1-A))
*   Soft approximation via inclusion-exclusion on hi values.
*==============================================================================
.subckt th34w2 A B C D Y VDD VSS
B34w2 Y VSS V = { V(VDD,VSS) *
+   ( (0.5 + 0.5*tanh((V(A,VSS) - V(VDD,VSS)/2)*50)) *
+     (1 - (1 - (0.5 + 0.5*tanh((V(B,VSS) - V(VDD,VSS)/2)*50)))
+         * (1 - (0.5 + 0.5*tanh((V(C,VSS) - V(VDD,VSS)/2)*50)))
+         * (1 - (0.5 + 0.5*tanh((V(D,VSS) - V(VDD,VSS)/2)*50))))
+   + (1 - (0.5 + 0.5*tanh((V(A,VSS) - V(VDD,VSS)/2)*50))) *
+     (0.5 + 0.5*tanh((V(B,VSS) - V(VDD,VSS)/2)*50)) *
+     (0.5 + 0.5*tanh((V(C,VSS) - V(VDD,VSS)/2)*50)) *
+     (0.5 + 0.5*tanh((V(D,VSS) - V(VDD,VSS)/2)*50)) ) }
.ends th34w2
