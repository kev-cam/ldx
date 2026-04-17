* th22.sp — 2-input threshold gate (Muller C-element)
*
* Behavior:
*   A=B=1 -> Y=1
*   A=B=0 -> Y=0
*   A!=B  -> Y holds previous value
*
* Topology: Sutherland static C-element with weak-feedback keeper.
*
*   VDD - Pa(A) - Pb(B) - X
*                         |
*                         +--inv--> Y
*                         |
*   GND - Na(A) - Nb(B) - X
*
*   Keeper: weak inverter from Y back to X holds X when pull networks are off.
*
* Ports: A B Y VDD VSS
* Requires sg13g2_nmos / sg13g2_pmos (PSP103, level=103) included by caller.

.subckt th22 A B Y VDD VSS

* --- Pull-up stack: A and B in series to X ---
MPA  N1 A VDD VDD sg13g2_pmos W=0.7u  L=0.13u
MPB  X  B N1  VDD sg13g2_pmos W=0.7u  L=0.13u

* --- Pull-down stack: A and B in series to X ---
MNA  N2 A VSS VSS sg13g2_nmos W=0.35u L=0.13u
MNB  X  B N2  VSS sg13g2_nmos W=0.35u L=0.13u

* --- Output inverter X -> Y ---
MPY  Y  X VDD VDD sg13g2_pmos W=0.7u  L=0.13u
MNY  Y  X VSS VSS sg13g2_nmos W=0.35u L=0.13u

* --- Weak feedback keeper: Y -> inv -> X (holds X when stacks off) ---
* Long-L weak devices so the real pull networks can override.
MPK  X  Y VDD VDD sg13g2_pmos W=0.35u L=1.0u
MNK  X  Y VSS VSS sg13g2_nmos W=0.15u L=1.0u

.ends th22
