#!/usr/bin/env python3
"""Generate tb_nclfa.sp — 8 test cases of a 1-bit NCL full adder with
4-phase NULL/DATA handshake."""

VDD = 1.2
DATA_NS = 10   # DATA phase duration
NULL_NS = 10   # NULL phase duration
EDGE_PS = 50   # edge slew

def case_window(k):
    # Case k: DATA from (2k+1)*NULL_NS to (2k+2)*NULL_NS (i.e. after leading NULL)
    t_null_start = k * (NULL_NS + DATA_NS)
    t_data_start = t_null_start + NULL_NS
    t_data_end   = t_data_start + DATA_NS
    return t_data_start, t_data_end

def rail_pwl(name, active_cases):
    """PWL: rail at VDD during DATA phase of given case numbers, else 0."""
    pts = [(0, 0)]
    for k in range(8):
        s, e = case_window(k)
        if k in active_cases:
            pts.append((s * 1000 - EDGE_PS, 0))
            pts.append((s * 1000 + EDGE_PS, VDD))
            pts.append((e * 1000 - EDGE_PS, VDD))
            pts.append((e * 1000 + EDGE_PS, 0))
    pts.append((200_000, 0))  # 200 ns end
    lines = [f"V{name} {name} 0 PWL"]
    for t_ps, v in pts:
        lines.append(f"+ {t_ps/1000:.3f}n {v}")
    return "\n".join(lines)

# For case k: bits a=(k>>2)&1, b=(k>>1)&1, c=k&1
aH = {k for k in range(8) if (k >> 2) & 1}
aL = {k for k in range(8) if not (k >> 2) & 1}
bH = {k for k in range(8) if (k >> 1) & 1}
bL = {k for k in range(8) if not (k >> 1) & 1}
ciH = {k for k in range(8) if k & 1}
ciL = {k for k in range(8) if not k & 1}

sim_end_ns = 8 * (NULL_NS + DATA_NS) + NULL_NS

# Expected outputs per case (for the comment header)
expected = []
for k in range(8):
    a, b, c = (k >> 2) & 1, (k >> 1) & 1, k & 1
    s = a ^ b ^ c
    co = (a & b) | (a & c) | (b & c)
    expected.append((k, a, b, c, s, co))

header = "* tb_nclfa.sp — 1-bit NCL full adder, 8-case 4-phase test\n"
header += "*\n"
header += "* Case: a b cin -> sum cout   (DATA window ns)\n"
for k, a, b, c, s, co in expected:
    ds, de = case_window(k)
    header += f"*   {k}: {a} {b} {c}  ->  {s}  {co}          {ds}-{de} ns\n"
header += "*\n"

netlist = header + f"""
.include "/tmp/sg13g2_models.lib"
.include "/usr/local/src/ldx/asic/cells/th22.sp"
.include "/usr/local/src/ldx/asic/cells/th_gates.sp"
.include "/usr/local/src/ldx/asic/cells/nclfa.sp"

VVDD VDD 0 {VDD}
VVSS VSS 0 0

{rail_pwl('aH',  aH)}
{rail_pwl('aL',  aL)}
{rail_pwl('bH',  bH)}
{rail_pwl('bL',  bL)}
{rail_pwl('ciH', ciH)}
{rail_pwl('ciL', ciL)}

Xdut aH aL bH bL ciH ciL sH sL coH coL VDD VSS nclfa

CLsH  sH  0 3f
CLsL  sL  0 3f
CLcoH coH 0 3f
CLcoL coL 0 3f

.tran 20p {sim_end_ns}n
.print tran format=csv V(aH) V(aL) V(bH) V(bL) V(ciH) V(ciL) V(sH) V(sL) V(coH) V(coL)

.options timeint method=gear
.end
"""

with open("tb_nclfa.sp", "w") as f:
    f.write(netlist)

print(f"Wrote tb_nclfa.sp ({sim_end_ns} ns total)")
