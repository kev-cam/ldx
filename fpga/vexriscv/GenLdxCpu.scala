package vexriscv.demo

import spinal.core._
import vexriscv.plugin._
import vexriscv.{VexRiscv, VexRiscvConfig, plugin}

// Parameterized ldx core generator — the per-core half of the feature matrix.
// Pick the variant per (FPGA, design) target; generates VexRiscv.v (rename it to
// the variant name in the build flow — see gen_core_variants.sh).
//
//   cd /usr/local/src/vexriscv && sbt "runMain vexriscv.demo.GenLdxCpu shifter=barrel muldiv=on cfu=on"
//
//   shifter = barrel | light   barrel = single-cycle shifts (4.5x on shift/rotate
//                              -heavy designs: SHA, xorshift); light = 1 bit/cycle,
//                              smaller LUT — pick light only if the design barely shifts.
//   muldiv  = on | off         on = rv32im Mul+Div (~4 DSP + LUT/core); off = rv32i,
//                              no DSP — drop it when the design has no mul/div.
//   cfu     = on | off         on = Custom Function Unit port (ldx_cfu.v) for design
//                              -specific hot-op acceleration; off = smaller core.
object GenLdxCpu extends App {
  val o       = args.flatMap(a => a.split("=") match { case Array(k, v) => Some(k -> v); case _ => None }).toMap
  val shifter = o.getOrElse("shifter", "barrel")
  val muldiv  = o.getOrElse("muldiv", "on")
  val cfu     = o.getOrElse("cfu", "on")

  def cfuPlugin = new CfuPlugin(
    stageCount = 0, allowZeroLatency = true,
    encodings = List(CfuPluginEncoding(
      instruction = M"-------------------------0001011",   // CUSTOM_0
      functionId  = List(14 downto 12),
      input2Kind  = CfuPlugin.Input2Kind.RS)),
    busParameter = CfuBusParameter(
      CFU_VERSION = 0, CFU_INTERFACE_ID_W = 0, CFU_FUNCTION_ID_W = 3,
      CFU_REORDER_ID_W = 0, CFU_REQ_RESP_ID_W = 0, CFU_INPUTS = 2,
      CFU_INPUT_DATA_W = 32, CFU_OUTPUTS = 1, CFU_OUTPUT_DATA_W = 32,
      CFU_FLOW_REQ_READY_ALWAYS = true, CFU_FLOW_RESP_READY_ALWAYS = true,
      CFU_WITH_STATUS = false, CFU_RAW_INSN_W = 0, CFU_CFU_ID_W = 0, CFU_STATE_INDEX_NUM = 0))

  def cpu() = new VexRiscv(config = VexRiscvConfig(plugins =
    List[Plugin[VexRiscv]](
      new IBusSimplePlugin(resetVector = 0x80000000L, cmdForkOnSecondStage = false,
        cmdForkPersistence = false, prediction = NONE, catchAccessFault = false, compressedGen = false),
      new DBusSimplePlugin(catchAddressMisaligned = false, catchAccessFault = false),
      new CsrPlugin(CsrPluginConfig.smallest),
      new DecoderSimplePlugin(catchIllegalInstruction = false),
      new RegFilePlugin(regFileReadyKind = plugin.SYNC, zeroBoot = false),
      new IntAluPlugin,
      new SrcPlugin(separatedAddSub = false, executeInsertion = true),
      (if (shifter == "light") new LightShifterPlugin else new FullBarrelShifterPlugin),
      new HazardSimplePlugin(bypassExecute = true, bypassMemory = true, bypassWriteBack = true,
        bypassWriteBackBuffer = true, pessimisticUseSrc = false,
        pessimisticWriteRegFile = false, pessimisticAddressMatch = false),
      new BranchPlugin(earlyBranch = false, catchAddressMisaligned = false)
    )
    ++ (if (muldiv == "on") List[Plugin[VexRiscv]](new MulPlugin, new DivPlugin) else Nil)
    ++ (if (cfu    == "on") List[Plugin[VexRiscv]](cfuPlugin) else Nil)
    ++ List[Plugin[VexRiscv]](new YamlPlugin("cpu0.yaml"))
  ))

  println(s"## GenLdxCpu: shifter=$shifter muldiv=$muldiv cfu=$cfu")
  SpinalVerilog(cpu())
}
