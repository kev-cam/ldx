#!/usr/bin/env python3
"""
simple_synth_test.py — Simple synthesis validation without complex queries
"""

import subprocess

def test_simple_synthesis():
    """Test basic synthesis without resource queries."""

    verilog = '''
module test_accel (
    input wire clk,
    input wire rst,
    input wire [31:0] data_in,
    input wire [7:0] addr,
    input wire write_en,
    output reg [31:0] data_out
);

reg [31:0] memory [0:255];

always @(posedge clk) begin
    if (rst) begin
        data_out <= 32'h0;
    end else begin
        if (write_en) begin
            memory[addr] <= data_in;
        end
        data_out <= memory[addr];
    end
end

endmodule'''

    with open('/tmp/test_accel.v', 'w') as f:
        f.write(verilog)

    # Minimal TCL script - just synthesis, no queries
    tcl_script = '''
create_project test_synth /tmp/test_synth_proj -part xczu7ev-ffvc1156-2-e -force
add_files -norecurse /tmp/test_accel.v
set_property top test_accel [current_fileset]
update_compile_order -fileset sources_1

synth_design -top test_accel -part xczu7ev-ffvc1156-2-e

puts "SYNTHESIS_COMPLETE"
exit 0
'''

    with open('/tmp/simple_synth.tcl', 'w') as f:
        f.write(tcl_script)

    try:
        result = subprocess.run([
            "/opt/AMD/2025.2/Vivado/bin/vivado", "-mode", "batch",
            "-source", "/tmp/simple_synth.tcl"
        ], capture_output=True, text=True, timeout=180)

        if result.returncode == 0 and "SYNTHESIS_COMPLETE" in result.stdout:
            print("✓ Basic synthesis WORKS!")
            return True
        else:
            print(f"✗ Basic synthesis failed")
            print(f"Error: {result.stderr[:200]}")
            return False

    except Exception as e:
        print(f"✗ Error: {e}")
        return False

if __name__ == "__main__":
    print("Testing basic Vivado synthesis...")
    success = test_simple_synthesis()

    if success:
        print("\n🎯 SUCCESS: Synthesis pipeline is working!")
        print("Issue is only with resource queries, not synthesis itself")
    else:
        print("\n✗ Need to debug Vivado setup")