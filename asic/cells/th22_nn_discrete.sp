* th22_nn_discrete.sp — discrete-primitive wrapper around the NN core.
* Compose with: .hdl "th22_nn_core.va"

.subckt th22_nn A B Y VDD VSS
* --- NN core: pure prediction, two output voltage taps ---
X_core A B VDD VSS vpred_tap gpred_tap th22_nn_core

* --- Discrete Thevenin output driver: VCVS + series R + grounded C ---
E_drive drive_int VSS vpred_tap VSS 1.0
R_out   drive_int Y 500
C_out   Y VSS 5f

* --- Programmable supply resistor: VCCS reading g_pred and V(VDD,VSS).
* Equivalent to R = 1/g_pred between VDD and VSS. G = g_pred · V(VDD,VSS).
B_pwr   VDD VSS I={V(gpred_tap, VSS) * V(VDD, VSS)}
.ends
