* nclfa4.sp — 4-bit NCL ripple-carry adder
*
* Composed of 4 nclfa instances, chained carry.
* Inputs : aH[3:0], aL[3:0], bH[3:0], bL[3:0]
* Outputs: sH[3:0], sL[3:0], coH (final), coL (final)
* Cin assumed DATA0 (ciH=0, ciL=VDD) driven externally for test flexibility.

.subckt nclfa4
+ a0H a0L a1H a1L a2H a2L a3H a3L
+ b0H b0L b1H b1L b2H b2L b3H b3L
+ ciH ciL
+ s0H s0L s1H s1L s2H s2L s3H s3L
+ coH coL
+ VDD VSS

Xfa0 a0H a0L b0H b0L ciH  ciL  s0H s0L c1H c1L VDD VSS nclfa
Xfa1 a1H a1L b1H b1L c1H  c1L  s1H s1L c2H c2L VDD VSS nclfa
Xfa2 a2H a2L b2H b2L c2H  c2L  s2H s2L c3H c3L VDD VSS nclfa
Xfa3 a3H a3L b3H b3L c3H  c3L  s3H s3L coH coL VDD VSS nclfa

.ends nclfa4
