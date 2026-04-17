* SHA-style NCL round, width=4, Σ0 rot=(1, 2, 3), Σ1 rot=(3, 2, 1)

* Σ sigma0: rotations (1, 2, 3)
.subckt sigma0 x0H x0L x1H x1L x2H x2L x3H x3L y0H y0L y1H y1L y2H y2L y3H y3L VDD VSS
Xx0 x1H x1L x2H x2L x3H x3L y0H y0L VDD VSS ncl_xor3
Xx1 x2H x2L x3H x3L x0H x0L y1H y1L VDD VSS ncl_xor3
Xx2 x3H x3L x0H x0L x1H x1L y2H y2L VDD VSS ncl_xor3
Xx3 x0H x0L x1H x1L x2H x2L y3H y3L VDD VSS ncl_xor3
.ends

* Σ sigma1: rotations (3, 2, 1)
.subckt sigma1 x0H x0L x1H x1L x2H x2L x3H x3L y0H y0L y1H y1L y2H y2L y3H y3L VDD VSS
Xx0 x3H x3L x2H x2L x1H x1L y0H y0L VDD VSS ncl_xor3
Xx1 x0H x0L x3H x3L x2H x2L y1H y1L VDD VSS ncl_xor3
Xx2 x1H x1L x0H x0L x3H x3L y2H y2L VDD VSS ncl_xor3
Xx3 x2H x2L x1H x1L x0H x0L y3H y3L VDD VSS ncl_xor3
.ends

.subckt ch_4 e0H e0L e1H e1L e2H e2L e3H e3L f0H f0L f1H f1L f2H f2L f3H f3L g0H g0L g1H g1L g2H g2L g3H g3L y0H y0L y1H y1L y2H y2L y3H y3L VDD VSS
Xc0 e0H e0L f0H f0L g0H g0L y0H y0L VDD VSS ncl_ch
Xc1 e1H e1L f1H f1L g1H g1L y1H y1L VDD VSS ncl_ch
Xc2 e2H e2L f2H f2L g2H g2L y2H y2L VDD VSS ncl_ch
Xc3 e3H e3L f3H f3L g3H g3L y3H y3L VDD VSS ncl_ch
.ends

.subckt maj_4 a0H a0L a1H a1L a2H a2L a3H a3L b0H b0L b1H b1L b2H b2L b3H b3L c0H c0L c1H c1L c2H c2L c3H c3L y0H y0L y1H y1L y2H y2L y3H y3L VDD VSS
Xm0 a0H a0L b0H b0L c0H c0L y0H y0L VDD VSS ncl_maj3
Xm1 a1H a1L b1H b1L c1H c1L y1H y1L VDD VSS ncl_maj3
Xm2 a2H a2L b2H b2L c2H c2L y2H y2L VDD VSS ncl_maj3
Xm3 a3H a3L b3H b3L c3H c3L y3H y3L VDD VSS ncl_maj3
.ends

.subckt add_4 a0H a0L a1H a1L a2H a2L a3H a3L b0H b0L b1H b1L b2H b2L b3H b3L ciH ciL s0H s0L s1H s1L s2H s2L s3H s3L coH coL VDD VSS
Xfa0 a0H a0L b0H b0L ciH ciL s0H s0L c1H c1L VDD VSS nclfa
Xfa1 a1H a1L b1H b1L c1H c1L s1H s1L c2H c2L VDD VSS nclfa
Xfa2 a2H a2L b2H b2L c2H c2L s2H s2L c3H c3L VDD VSS nclfa
Xfa3 a3H a3L b3H b3L c3H c3L s3H s3L coH coL VDD VSS nclfa
.ends

.subckt sha_round_4 a0H a0L a1H a1L a2H a2L a3H a3L b0H b0L b1H b1L b2H b2L b3H b3L c0H c0L c1H c1L c2H c2L c3H c3L d0H d0L d1H d1L d2H d2L d3H d3L e0H e0L e1H e1L e2H e2L e3H e3L f0H f0L f1H f1L f2H f2L f3H f3L g0H g0L g1H g1L g2H g2L g3H g3L h0H h0L h1H h1L h2H h2L h3H h3L cinH cinL an0H an0L an1H an1L an2H an2L an3H an3L en0H en0L en1H en1L en2H en2L en3H en3L VDD VSS
* Σ0(a)
Xs0 a0H a0L a1H a1L a2H a2L a3H a3L S0_0H S0_0L S0_1H S0_1L S0_2H S0_2L S0_3H S0_3L VDD VSS sigma0
* Σ1(e)
Xs1 e0H e0L e1H e1L e2H e2L e3H e3L S1_0H S1_0L S1_1H S1_1L S1_2H S1_2L S1_3H S1_3L VDD VSS sigma1
* Ch(e,f,g)
Xch e0H e0L e1H e1L e2H e2L e3H e3L f0H f0L f1H f1L f2H f2L f3H f3L g0H g0L g1H g1L g2H g2L g3H g3L ch_0H ch_0L ch_1H ch_1L ch_2H ch_2L ch_3H ch_3L VDD VSS ch_4
* Maj(a,b,c)
Xmj a0H a0L a1H a1L a2H a2L a3H a3L b0H b0L b1H b1L b2H b2L b3H b3L c0H c0L c1H c1L c2H c2L c3H c3L mj_0H mj_0L mj_1H mj_1L mj_2H mj_2L mj_3H mj_3L VDD VSS maj_4
* T1a = h + Σ1
Xadd1 h0H h0L h1H h1L h2H h2L h3H h3L S1_0H S1_0L S1_1H S1_1L S1_2H S1_2L S1_3H S1_3L cinH cinL T1a_0H T1a_0L T1a_1H T1a_1L T1a_2H T1a_2L T1a_3H T1a_3L co1H co1L VDD VSS add_4
* T1 = T1a + Ch
Xadd2 T1a_0H T1a_0L T1a_1H T1a_1L T1a_2H T1a_2L T1a_3H T1a_3L ch_0H ch_0L ch_1H ch_1L ch_2H ch_2L ch_3H ch_3L cinH cinL T1_0H T1_0L T1_1H T1_1L T1_2H T1_2L T1_3H T1_3L co2H co2L VDD VSS add_4
* T2 = Σ0 + Maj
Xadd3 S0_0H S0_0L S0_1H S0_1L S0_2H S0_2L S0_3H S0_3L mj_0H mj_0L mj_1H mj_1L mj_2H mj_2L mj_3H mj_3L cinH cinL T2_0H T2_0L T2_1H T2_1L T2_2H T2_2L T2_3H T2_3L co3H co3L VDD VSS add_4
* a_new = T1 + T2
Xadd4 T1_0H T1_0L T1_1H T1_1L T1_2H T1_2L T1_3H T1_3L T2_0H T2_0L T2_1H T2_1L T2_2H T2_2L T2_3H T2_3L cinH cinL an0H an0L an1H an1L an2H an2L an3H an3L co4H co4L VDD VSS add_4
* e_new = d + T1
Xadd5 d0H d0L d1H d1L d2H d2L d3H d3L T1_0H T1_0L T1_1H T1_1L T1_2H T1_2L T1_3H T1_3L cinH cinL en0H en0L en1H en1L en2H en2L en3H en3L co5H co5L VDD VSS add_4
.ends