* ncl_xor3.sp — 3-input dual-rail XOR (chained xor2)
*   y = a XOR b XOR c
.subckt ncl_xor3 aH aL bH bL cH cL yH yL VDD VSS
Xx1 aH aL bH bL T1H T1L VDD VSS ncl_xor2
Xx2 T1H T1L cH cL yH yL VDD VSS ncl_xor2
.ends ncl_xor3
