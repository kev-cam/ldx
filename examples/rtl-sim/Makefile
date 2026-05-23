# Makefile for parallel RTL simulation engine

# Cross-compilation for RISC-V (softcore firmware)
RV32_CC     = riscv64-unknown-elf-gcc
RV32_OBJCOPY = riscv64-unknown-elf-objcopy
RV32_CFLAGS = -march=rv32im -mabi=ilp32 -O2 -nostdlib -nostartfiles -ffreestanding \
              -Wl,-Ttext=0x80000000 -I.

# Cross-compilation for aarch64 (host controller)
A64_CC      = aarch64-linux-gnu-gcc
A64_CFLAGS  = -static -O2 -Wall -Wextra -g -I. -I../../fpga/zcu104/sw

# Host native compilation (for development/testing)
CC          = gcc
CFLAGS      = -O2 -Wall -Wextra -g -I.

all: rtl_sim_firmware.bin test_rtl_sim test_cpu_pipeline

# RISC-V firmware for softcores
rtl_sim_firmware.elf: rtl_sim_firmware.c rtl_sim_engine.c rtl_sim_engine.h rv32_crt0.S
	$(RV32_CC) $(RV32_CFLAGS) -o $@ rv32_crt0.S rtl_sim_firmware.c rtl_sim_engine.c

rtl_sim_firmware.bin: rtl_sim_firmware.elf
	$(RV32_OBJCOPY) -O binary $< $@

# Compact firmware that fits in 2KB
rtl_sim_firmware_compact.elf: rtl_sim_firmware_compact.c rv32_crt0.S
	$(RV32_CC) $(RV32_CFLAGS) -Os -o $@ rv32_crt0.S rtl_sim_firmware_compact.c

rtl_sim_firmware_compact.bin: rtl_sim_firmware_compact.elf
	$(RV32_OBJCOPY) -O binary $< $@

# Runtime startup for RV32I firmware
rv32_crt0.S:
	echo '/* Minimal startup for VexRiscv */' > $@
	echo '.section .text' >> $@
	echo '.globl _start' >> $@
	echo '_start:' >> $@
	echo '    la sp, 0x80000800  /* Stack at end of first 2KB */' >> $@
	echo '    call main' >> $@
	echo '1:  j 1b           /* Infinite loop if main returns */' >> $@

# aarch64 host controller and test
test_rtl_sim: test_rtl_sim.c rtl_sim_host.c rtl_partition.c rtl_sim_host.h rtl_partition.h rtl_sim_engine.h
	$(A64_CC) $(A64_CFLAGS) -o $@ test_rtl_sim.c rtl_sim_host.c rtl_partition.c

test_cpu_pipeline: test_cpu_pipeline.c rtl_sim_host.c rtl_partition.c rtl_sim_host.h rtl_partition.h rtl_sim_engine.h
	$(A64_CC) $(A64_CFLAGS) -o $@ test_cpu_pipeline.c rtl_sim_host.c rtl_partition.c

test_firmware_simple: test_firmware_simple.c
	$(A64_CC) $(A64_CFLAGS) -o $@ test_firmware_simple.c

test_fpga_basic: test_fpga_basic.c
	$(A64_CC) $(A64_CFLAGS) -o $@ test_fpga_basic.c

# Host native version (for development without ZCU104)
test_rtl_sim_native: test_rtl_sim.c rtl_sim_host.c rtl_partition.c rtl_sim_host.h rtl_partition.h rtl_sim_engine.h
	$(CC) $(CFLAGS) -DNATIVE_TEST -o $@ test_rtl_sim.c rtl_sim_host.c rtl_partition.c

# Simple netlist generator for testing
gen_netlist: gen_netlist.c rtl_sim_engine.h
	$(CC) $(CFLAGS) -o $@ gen_netlist.c

demo_partitioning: demo_partitioning.c rtl_partition.c rtl_partition.h rtl_sim_engine.h
	$(CC) $(CFLAGS) -o $@ demo_partitioning.c rtl_partition.c

run_host: test_rtl_sim rtl_sim_firmware.bin
	./test_rtl_sim rtl_sim_firmware.bin

clean:
	rm -f *.elf *.bin *.o test_rtl_sim test_rtl_sim_native test_cpu_pipeline gen_netlist rv32_crt0.S *.dot

.PHONY: all run_host clean

# Debug helpers
debug: rtl_sim_firmware.elf
	riscv64-unknown-elf-objdump -d $<

size: rtl_sim_firmware.bin
	ls -la $<
	hexdump -C $< | head -20