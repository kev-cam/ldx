package vexriscv.demo

import spinal.core._
import vexriscv.plugin._
import vexriscv.{VexRiscv, VexRiscvConfig, plugin}

// Generate a minimal VexRiscv with CFU for ldx FPGA acceleration.
// The CFU bus is exported as top-level I/O for connection to ldx_cfu.v.
//
// Run: cd /usr/local/src/vexriscv && sbt "runMain vexriscv.demo.GenLdxCpu"
// Output: VexRiscv.v in the current directory

object GenLdxCpu extends App {
  def cpu() = new VexRiscv(
    config = VexRiscvConfig(
      plugins = List(
        new IBusSimplePlugin(
          resetVector = 0x80000000L,
          cmdForkOnSecondStage = false,
          cmdForkPersistence = false,
          prediction = NONE,
          catchAccessFault = false,
          compressedGen = false
        ),
        new DBusSimplePlugin(
          catchAddressMisaligned = false,
          catchAccessFault = false
        ),
        new CsrPlugin(CsrPluginConfig.smallest),
        new DecoderSimplePlugin(
          catchIllegalInstruction = false
        ),
        new RegFilePlugin(
          regFileReadyKind = plugin.SYNC,
          zeroBoot = false
        ),
        new IntAluPlugin,
        new SrcPlugin(
          separatedAddSub = false,
          executeInsertion = true
        ),
        new LightShifterPlugin,
        new HazardSimplePlugin(
          bypassExecute = true,
          bypassMemory = true,
          bypassWriteBack = true,
          bypassWriteBackBuffer = true,
          pessimisticUseSrc = false,
          pessimisticWriteRegFile = false,
          pessimisticAddressMatch = false
        ),
        new BranchPlugin(
          earlyBranch = false,
          catchAddressMisaligned = false
        ),
        // MUL/DIV for rv32im
        new MulPlugin,
        new DivPlugin,
        // Custom Function Unit — connects to ldx_cfu.v
        new CfuPlugin(
          stageCount = 0,           // zero-latency (combinational)
          allowZeroLatency = true,
          encodings = List(
            CfuPluginEncoding(
              instruction = M"-------------------------0001011",  // CUSTOM_0 opcode
              functionId = List(14 downto 12),  // funct3 = function select
              input2Kind = CfuPlugin.Input2Kind.RS
            )
          ),
          busParameter = CfuBusParameter(
            CFU_VERSION = 0,
            CFU_INTERFACE_ID_W = 0,
            CFU_FUNCTION_ID_W = 3,   // funct3 = 3 bits = 8 functions
            CFU_REORDER_ID_W = 0,
            CFU_REQ_RESP_ID_W = 0,
            CFU_INPUTS = 2,          // rs1, rs2
            CFU_INPUT_DATA_W = 32,
            CFU_OUTPUTS = 1,         // rd
            CFU_OUTPUT_DATA_W = 32,
            CFU_FLOW_REQ_READY_ALWAYS = true,
            CFU_FLOW_RESP_READY_ALWAYS = true,
            CFU_WITH_STATUS = false,
            CFU_RAW_INSN_W = 0,
            CFU_CFU_ID_W = 0,
            CFU_STATE_INDEX_NUM = 0
          )
        ),
        new YamlPlugin("cpu0.yaml")
      )
    )
  )

  val report = SpinalVerilog(cpu())
}
