// vexriscv_stub.v — drop-in replacement for VexRiscv during AXI bench testing.
// Exposes dbus_cmd_* as external testbench-driven probes so the bench can
// fake a CPU posting a hypercall, without instantiating the real CPU.
//
// All inputs accepted (sinked); outputs idle by default. Override via
// hierarchical force from the testbench when you need to inject traffic.

`timescale 1ns/1ps

module VexRiscv (
    input  wire        clk,
    input  wire        reset,
    input  wire        timerInterrupt,
    input  wire        externalInterrupt,
    input  wire        softwareInterrupt,

    output reg         iBus_cmd_valid,
    input  wire        iBus_cmd_ready,
    output reg  [31:0] iBus_cmd_payload_pc,
    input  wire        iBus_rsp_valid,
    input  wire        iBus_rsp_payload_error,
    input  wire [31:0] iBus_rsp_payload_inst,

    output reg         CfuPlugin_bus_cmd_valid,
    input  wire        CfuPlugin_bus_cmd_ready,
    output reg  [2:0]  CfuPlugin_bus_cmd_payload_function_id,
    output reg  [31:0] CfuPlugin_bus_cmd_payload_inputs_0,
    output reg  [31:0] CfuPlugin_bus_cmd_payload_inputs_1,
    input  wire        CfuPlugin_bus_rsp_valid,
    output reg         CfuPlugin_bus_rsp_ready,
    input  wire [31:0] CfuPlugin_bus_rsp_payload_outputs_0,

    output reg         dBus_cmd_valid,
    input  wire        dBus_cmd_ready,
    output reg         dBus_cmd_payload_wr,
    output reg  [3:0]  dBus_cmd_payload_mask,
    output reg  [31:0] dBus_cmd_payload_address,
    output reg  [31:0] dBus_cmd_payload_data,
    output reg  [1:0]  dBus_cmd_payload_size,
    input  wire        dBus_rsp_ready,
    input  wire        dBus_rsp_error,
    input  wire [31:0] dBus_rsp_data
);
    initial begin
        iBus_cmd_valid = 0;
        iBus_cmd_payload_pc = 32'h80000000;
        dBus_cmd_valid = 0;
        dBus_cmd_payload_wr = 0;
        dBus_cmd_payload_mask = 0;
        dBus_cmd_payload_address = 0;
        dBus_cmd_payload_data = 0;
        dBus_cmd_payload_size = 0;
        CfuPlugin_bus_cmd_valid = 0;
        CfuPlugin_bus_cmd_payload_function_id = 0;
        CfuPlugin_bus_cmd_payload_inputs_0 = 0;
        CfuPlugin_bus_cmd_payload_inputs_1 = 0;
        CfuPlugin_bus_rsp_ready = 0;
    end
endmodule

// CFU stub
module ldx_cfu (
    input  wire        clk, reset,
    input  wire        cmd_valid,
    output wire        cmd_ready,
    input  wire [2:0]  cmd_function_id,
    input  wire [31:0] cmd_inputs_0, cmd_inputs_1,
    output reg         rsp_valid,
    input  wire        rsp_ready,
    output reg  [31:0] rsp_outputs_0
);
    assign cmd_ready = 1'b1;
    always @(posedge clk) begin
        if (reset) begin
            rsp_valid <= 0;
            rsp_outputs_0 <= 0;
        end else begin
            rsp_valid <= cmd_valid;
            rsp_outputs_0 <= cmd_inputs_0 + cmd_inputs_1;
        end
    end
endmodule
