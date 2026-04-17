* ncl_logic.sp — Composite dual-rail NCL cells (XOR, Ch, Maj, AND, OR)
*
* Requires th22, th12 (th_gates.sp) to be included first.
* Convention: dual-rail signal X is carried by X_H (value-1 rail) and X_L
* (value-0 rail). In NCL protocol exactly one rail is asserted during DATA
* phase; both are 0 during NULL phase.

*==============================================================================
* ncl_and2 — 2-input AND (dual-rail)
*   out.H = a.H · b.H
*   out.L = a.L | b.L   (i.e. AND-low = OR of lows)
*==============================================================================
.subckt ncl_and2 aH aL bH bL yH yL VDD VSS
Xand_h aH bH yH VDD VSS th22
Xand_l aL bL yL VDD VSS th12
.ends ncl_and2

*==============================================================================
* ncl_or2 — 2-input OR (dual-rail)
*   out.H = a.H | b.H
*   out.L = a.L · b.L
*==============================================================================
.subckt ncl_or2 aH aL bH bL yH yL VDD VSS
Xor_h  aH bH yH VDD VSS th12
Xor_l  aL bL yL VDD VSS th22
.ends ncl_or2

*==============================================================================
* ncl_xor2 — 2-input XOR (dual-rail)
*   out.H = (a.H · b.L) | (a.L · b.H)   -- exactly one high
*   out.L = (a.H · b.H) | (a.L · b.L)   -- both same
* 4× TH22 + 2× TH12 = 6 primitives ≈ 60 transistors
*==============================================================================
.subckt ncl_xor2 aH aL bH bL yH yL VDD VSS
* Y.H = (a.H · b.L) | (a.L · b.H)
Xp1  aH bL P1 VDD VSS th22
Xp2  aL bH P2 VDD VSS th22
Xh   P1 P2 yH VDD VSS th12
* Y.L = (a.H · b.H) | (a.L · b.L)
Xp3  aH bH P3 VDD VSS th22
Xp4  aL bL P4 VDD VSS th22
Xl   P3 P4 yL VDD VSS th12
.ends ncl_xor2

*==============================================================================
* ncl_maj3 — 3-input majority (dual-rail)
*   Maj(a,b,c) = (a·b) | (a·c) | (b·c)
* Each rail is TH23 of the matching rails of the inputs.
*==============================================================================
.subckt ncl_maj3 aH aL bH bL cH cL yH yL VDD VSS
Xmh  aH bH cH yH VDD VSS th23
Xml  aL bL cL yL VDD VSS th23
.ends ncl_maj3

*==============================================================================
* ncl_ch — SHA-256 Choose: Ch(e,f,g) = (e·f) | (!e·g)
*   out.H = (e.H · f.H) | (e.L · g.H)
*   out.L = (e.H · f.L) | (e.L · g.L)
* !e in dual-rail = swap e.H and e.L, free.
*==============================================================================
.subckt ncl_ch eH eL fH fL gH gL yH yL VDD VSS
* H rail
Xch1  eH fH C1 VDD VSS th22
Xch2  eL gH C2 VDD VSS th22
Xchh  C1 C2 yH VDD VSS th12
* L rail
Xch3  eH fL C3 VDD VSS th22
Xch4  eL gL C4 VDD VSS th22
Xchl  C3 C4 yL VDD VSS th12
.ends ncl_ch
