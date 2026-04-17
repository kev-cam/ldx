* th_gates.sp — NCL threshold gate library for SG13G2
*
* Convention: each gate has a pull-down network firing when the threshold
* condition is met, a pull-up network firing only when ALL inputs are low
* (strict NCL hysteresis), an output inverter, and a weak-feedback keeper.
*
* Models: sg13g2_nmos / sg13g2_pmos (PSP103, level=103) — included by caller.
*
* Sizing: NMOS W=0.35u, PMOS W=0.7u (2x for mobility), L=0.13u minimum.
* Series stacks widened proportionally. Keeper is long-L so pull networks win.

*==============================================================================
* TH12 — 1-of-2 threshold (OR2). Degenerate: no hysteresis possible.
* Plain CMOS NOR + inverter.
*==============================================================================
.subckt th12 A B Y VDD VSS
* NOR: X = !(A|B)
MPA  N1 A VDD VDD sg13g2_pmos W=0.7u L=0.13u
MPB  X  B N1  VDD sg13g2_pmos W=0.7u L=0.13u
MNA  X  A VSS VSS sg13g2_nmos W=0.35u L=0.13u
MNB  X  B VSS VSS sg13g2_nmos W=0.35u L=0.13u
* Output inverter
MPY  Y  X VDD VDD sg13g2_pmos W=0.7u L=0.13u
MNY  Y  X VSS VSS sg13g2_nmos W=0.35u L=0.13u
.ends th12

*==============================================================================
* TH22 — 2-of-2 threshold (Muller C-element) — see th22.sp
*==============================================================================
* (defined in th22.sp, included separately)

*==============================================================================
* TH23 — 2-of-3 threshold (majority with hysteresis)
*   Pull-down (X→0, Y→1) when ≥2 of 3 high:
*     (A·B) || (A·C) || (B·C) in nMOS network
*   Pull-up (X→1, Y→0) only when all 3 low (strict NCL):
*     P(A)·P(B)·P(C) in series
*   Keeper holds X in intermediate states.
*==============================================================================
.subckt th23 A B C Y VDD VSS
* Pull-up: all three PMOS in series
MPA  N1 A VDD VDD sg13g2_pmos W=1.0u L=0.13u
MPB  N2 B N1  VDD sg13g2_pmos W=1.0u L=0.13u
MPC  X  C N2  VDD sg13g2_pmos W=1.0u L=0.13u
* Pull-down: three 2-input AND branches in parallel, each is 2 nMOS in series
* Branch 1: A·B
MNAB1 M1 A VSS VSS sg13g2_nmos W=0.7u L=0.13u
MNAB2 X  B M1  VSS sg13g2_nmos W=0.7u L=0.13u
* Branch 2: A·C
MNAC1 M2 A VSS VSS sg13g2_nmos W=0.7u L=0.13u
MNAC2 X  C M2  VSS sg13g2_nmos W=0.7u L=0.13u
* Branch 3: B·C
MNBC1 M3 B VSS VSS sg13g2_nmos W=0.7u L=0.13u
MNBC2 X  C M3  VSS sg13g2_nmos W=0.7u L=0.13u
* Output inverter
MPY  Y  X VDD VDD sg13g2_pmos W=0.7u L=0.13u
MNY  Y  X VSS VSS sg13g2_nmos W=0.35u L=0.13u
* Keeper
MPK  X  Y VDD VDD sg13g2_pmos W=0.35u L=1.0u
MNK  X  Y VSS VSS sg13g2_nmos W=0.15u L=1.0u
.ends th23

*==============================================================================
* TH33 — 3-of-3 threshold (AND3 with hysteresis)
*   Pull-down: N(A)·N(B)·N(C) in series
*   Pull-up  : P(A)·P(B)·P(C) in series
*   Keeper required: neither stack active in intermediate states.
*==============================================================================
.subckt th33 A B C Y VDD VSS
* Pull-up stack
MPA  N1 A VDD VDD sg13g2_pmos W=1.0u L=0.13u
MPB  N2 B N1  VDD sg13g2_pmos W=1.0u L=0.13u
MPC  X  C N2  VDD sg13g2_pmos W=1.0u L=0.13u
* Pull-down stack
MNA  M1 A VSS VSS sg13g2_nmos W=0.5u L=0.13u
MNB  M2 B M1  VSS sg13g2_nmos W=0.5u L=0.13u
MNC  X  C M2  VSS sg13g2_nmos W=0.5u L=0.13u
* Output inverter
MPY  Y  X VDD VDD sg13g2_pmos W=0.7u L=0.13u
MNY  Y  X VSS VSS sg13g2_nmos W=0.35u L=0.13u
* Keeper
MPK  X  Y VDD VDD sg13g2_pmos W=0.35u L=1.0u
MNK  X  Y VSS VSS sg13g2_nmos W=0.15u L=1.0u
.ends th33

*==============================================================================
* TH34W2 — Weighted 3-of-4 threshold, input A weighted 2.
*   Fires when 2·A + B + C + D ≥ 3, i.e.:
*     (A·B) || (A·C) || (A·D) || (B·C·D)
*   Pull-down: those four branches in parallel.
*   Pull-up  : all four PMOS in series (strict NCL: fires only when all low).
*==============================================================================
.subckt th34w2 A B C D Y VDD VSS
* Pull-up: 4 PMOS in series
MPA  P1 A VDD VDD sg13g2_pmos W=1.2u L=0.13u
MPB  P2 B P1  VDD sg13g2_pmos W=1.2u L=0.13u
MPC  P3 C P2  VDD sg13g2_pmos W=1.2u L=0.13u
MPD  X  D P3  VDD sg13g2_pmos W=1.2u L=0.13u
* Pull-down branch 1: A·B
MNAB1 Q1 A VSS VSS sg13g2_nmos W=0.7u L=0.13u
MNAB2 X  B Q1  VSS sg13g2_nmos W=0.7u L=0.13u
* Pull-down branch 2: A·C
MNAC1 Q2 A VSS VSS sg13g2_nmos W=0.7u L=0.13u
MNAC2 X  C Q2  VSS sg13g2_nmos W=0.7u L=0.13u
* Pull-down branch 3: A·D
MNAD1 Q3 A VSS VSS sg13g2_nmos W=0.7u L=0.13u
MNAD2 X  D Q3  VSS sg13g2_nmos W=0.7u L=0.13u
* Pull-down branch 4: B·C·D
MNBCD1 Q4 B VSS VSS sg13g2_nmos W=0.7u L=0.13u
MNBCD2 Q5 C Q4  VSS sg13g2_nmos W=0.7u L=0.13u
MNBCD3 X  D Q5  VSS sg13g2_nmos W=0.7u L=0.13u
* Output inverter
MPY  Y  X VDD VDD sg13g2_pmos W=0.7u L=0.13u
MNY  Y  X VSS VSS sg13g2_nmos W=0.35u L=0.13u
* Keeper
MPK  X  Y VDD VDD sg13g2_pmos W=0.35u L=1.0u
MNK  X  Y VSS VSS sg13g2_nmos W=0.15u L=1.0u
.ends th34w2
