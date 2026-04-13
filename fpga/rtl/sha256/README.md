# NCL SHA-256 Bitcoin Miner

A pipelined Bitcoin SHA-256d miner implemented in VHDL using the NCL
(NULL Convention Logic) framework. Runs on a Cyclone IV GX FPGA
(DE2i-150 board) using the `ncl_sync` single-rail synthesis library.
The same source compiles for true async NCL simulation with the `ncl`
dual-rail library.

## Architecture

```
nonce_ctr ──► byte_swap ──► block2_splice
                                  │
              midstate ──────► sha256d ──► hash_out
                                  │
                             meets_target?
                                  │
                              found / nonce_out
```

### Pipeline stages

| Module | File | Function |
|---|---|---|
| `e_sha256_round` | `sha256_round.vhdl` | One SHA-256 compression round (combinational) |
| `e_sha256_w_expand` | `sha256_w_expand.vhdl` | Message schedule expansion (combinational) |
| `e_sha256_pipeline` | `sha256_pipeline.vhdl` | 64-stage pipeline: one nonce per cycle throughput |
| `e_sha256d` | `sha256d.vhdl` | Double SHA-256 using midstate optimisation |
| `e_bitcoin_miner` | `bitcoin_miner.vhdl` | Nonce iterator + difficulty check |
| `bitcoin_miner_top` | `bitcoin_miner_top.vhd` | FPGA top for DE2i-150 |

### Latency

```
pipe1 (64 cycles) + pad_reg (1 cycle) + pipe2 (64 cycles) = 129 cycles sha256d
+ 1 cycle for miner's input register = 130 cycles nonce-to-hash
```

Throughput: one nonce tested per clock cycle once the pipeline is full.

### Midstate optimisation

Bitcoin's 80-byte block header is split into two 512-bit SHA-256 blocks.
The first block (version + prev_hash + most of merkle_root) is constant
for all nonces. Its SHA-256 compression result — the *midstate* — is
precomputed once. The pipeline only processes the second block, which
contains the nonce.

### NCL encoding

In simulation (`lib/ncl/`), each bit is a dual-rail pair (DATA0, DATA1,
NULL). Rotations (`rotr`) are zero-gate wire permutations. In synthesis
(`lib/ncl_sync/`), `ncl_logic` collapses to a single `std_logic` rail
and the design behaves as an ordinary synchronous pipeline clocked by
`phase`.

## Simulation

Requires [NVC](https://www.nickg.me.uk/nvc/) ≥ 1.10 and the dual-rail
`ncl` library.

```bash
cd fpga/test

# Analyse sources (order matters)
nvc --std=2008 \
    -a ../lib/ncl/ncl.vhdl \
    -a ../rtl/sha256/sha256_round.vhdl \
    -a ../rtl/sha256/sha256_w_expand.vhdl \
    -a ../rtl/sha256/sha256_pipeline.vhdl \
    -a ../rtl/sha256/sha256d.vhdl \
    -a ../rtl/sha256/bitcoin_miner.vhdl \
    -a tb_bitcoin_miner.vhdl

# Elaborate and run (two pipeline instances need extra heap)
nvc --std=2008 -H 2g -e tb_bitcoin_miner
nvc --std=2008 -H 2g -r tb_bitcoin_miner
```

Expected output (block #125552):

```
Phase 1: Computing midstate from block 1...
Midstate: 0x9524C59305C5671316E669BA2D2810A007E86E372F56A9DACD5BCE697A78DA2D
Phase 2: Starting Bitcoin miner from nonce 0x9546A13D...
Found nonce after 136 cycles!
Winning nonce: 0x9546A142
Hash (LE): 00000000000000001e8d6829a8a21adc5d38d0a473b144b6765798e61f98bd1d
PASS: Correct nonce found!
```

The testbench starts 5 below the correct nonce so the pipeline fills
before the hit arrives. The 136-cycle count is 130 (pipeline depth) +
5 (nonces ahead of the winner) + 1 (start-pulse delay).

## FPGA synthesis

Requires Quartus Prime 25.1 (Lite or Standard) targeting the
EP4CGX150DF31C7 (DE2i-150 board).

```bash
cd fpga/quartus_arv

QUARTUS=/home/dkc/altera_lite/25.1std/quartus/bin

$QUARTUS/quartus_map --read_settings_files=on --write_settings_files=off \
    bitcoin_miner_synth -c bitcoin_miner_synth

$QUARTUS/quartus_fit --read_settings_files=on --write_settings_files=off \
    bitcoin_miner_synth -c bitcoin_miner_synth

$QUARTUS/quartus_asm --read_settings_files=on --write_settings_files=off \
    bitcoin_miner_synth -c bitcoin_miner_synth
```

Fit results (EP4CGX150DF31C7, 149,760 LEs):

```
Total logic elements : 70,578  (47%)
  Combinational      : 55,233  (37%)
  Registers          : 41,932  (28%)
Total memory bits    : 26,682  (< 1%)
```

No SDC constraints were applied; the design runs comfortably at 50 MHz
on Cyclone IV.

## Programming the DE2i-150

```bash
QUARTUS=/home/dkc/altera_lite/25.1std/quartus/bin
SOF=quartus_arv/output_files_miner/bitcoin_miner_synth.sof

$QUARTUS/quartus_pgm -c "USB-Blaster [2-1.5]" -m JTAG -o "p;$SOF"
```

Or use the project's `arv_reload.sh` passing the SOF path:

```bash
fpga/tools/arv_reload.sh fpga/quartus_arv/output_files_miner/bitcoin_miner_synth.sof
```

## LED behaviour (DE2i-150)

The top is hardcoded to mine Bitcoin block #125552 starting at nonce
`0x9546A13D` (5 below the correct answer). At 50 MHz the nonce is found
in under 3 µs — the LEDs transition almost immediately after
configuration.

| LED | Meaning |
|-----|---------|
| `led[0]` | Blinks while mining (stops when found) |
| `led[1]` | Solid ON — valid nonce found |
| `led[2]` | Solid ON — pipeline running |
| `led[3]` | Heartbeat (toggles every ~0.17 s) |

After power-on you should see all four LEDs active briefly, then `led[0]`
stop blinking and `led[1]` latch on as the winning nonce `0x9546A142` is
confirmed.

## Test vector (Bitcoin block #125552)

| Field | Value |
|-------|-------|
| Midstate | `9524C593 05C56713 16E669BA 2D2810A0 07E86E37 2F56A9DA CD5BCE69 7A78DA2D` |
| Merkle tail / timestamp / bits | `f1fc122b c7f5d74d f2b9441a` |
| Winning nonce (native u32 LE) | `0x9546A142` |
| Hash (Bitcoin LE display) | `00000000000000001e8d6829a8a21adc5d38d0a473b144b6765798e61f98bd1d` |
| Difficulty zeros checked | 64 bits |

## Adapting for a different block

To mine a different block, replace the constants in `bitcoin_miner_top.vhd`:

1. **`MIDSTATE`** — compress `SHA256(H_INIT, block1)` and add `H_INIT`
   word-by-word. The testbench `tb_bitcoin_miner.vhdl` shows how; the
   `sha256_pipeline` entity is the compression primitive.

2. **`BLOCK2_TEMPLATE`** — bytes 64–79 of the 80-byte header (merkle
   tail, timestamp, bits), followed by SHA-256 padding for a 640-bit
   message (`0x80000000`, six zero words, `0x00000280`). Leave word 3
   (bits 415:384) as `0x00000000` — the miner overwrites it with the
   nonce.

3. **`START_NONCE`** — set to `0x00000000` to sweep from the beginning,
   or to a checkpoint value to resume.

4. **`DIFFICULTY_ZEROS`** — number of low-order bits that must be zero in
   the big-endian hash word packing (= leading zero bits in Bitcoin LE
   display). Block #125552 requires 64.
