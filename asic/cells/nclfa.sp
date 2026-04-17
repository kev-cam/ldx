* nclfa.sp — 1-bit NCL full adder (Fant canonical form)
*
* Dual-rail inputs:  aH aL bH bL ciH ciL
* Dual-rail outputs: sH sL coH coL
*
*   coH = TH23(aH, bH, ciH)
*   coL = TH23(aL, bL, ciL)
*   sH  = TH34W2(coL, aH, bH, ciH)    -- weight-2 input is first
*   sL  = TH34W2(coH, aL, bL, ciL)

.subckt nclfa aH aL bH bL ciH ciL sH sL coH coL VDD VSS

Xco_h  aH bH ciH coH VDD VSS th23
Xco_l  aL bL ciL coL VDD VSS th23

Xs_h   coL aH bH ciH sH VDD VSS th34w2
Xs_l   coH aL bL ciL sL VDD VSS th34w2

.ends nclfa
