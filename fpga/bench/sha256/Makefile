CC = riscv64-unknown-elf-gcc
CFLAGS = -march=rv32i -mabi=ilp32 -O2 -fno-builtin -nostdlib
LDFLAGS = -T arv.ld -nostdlib

# Number of SHA-256 iterations (1 = correctness check, higher = timing)
N_ITERS ?= 10

all: sha256_sw.bin sha256_cfu.bin

sha256_sw.elf: sha256.c arv.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -DN_ITERS=$(N_ITERS) -o $@ sha256.c

sha256_cfu.elf: sha256.c arv.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -DN_ITERS=$(N_ITERS) -DUSE_CFU -o $@ sha256.c

%.bin: %.elf
	riscv64-unknown-elf-objcopy -O binary $< $@

size: sha256_sw.elf sha256_cfu.elf
	riscv64-unknown-elf-size $^

disasm: sha256_sw.elf sha256_cfu.elf
	riscv64-unknown-elf-objdump -d sha256_sw.elf > sha256_sw.dis
	riscv64-unknown-elf-objdump -d sha256_cfu.elf > sha256_cfu.dis

clean:
	rm -f *.elf *.bin *.dis

.PHONY: all clean size disasm
