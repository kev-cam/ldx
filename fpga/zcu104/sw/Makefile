CC       = riscv64-unknown-elf-gcc
OBJCOPY  = riscv64-unknown-elf-objcopy
OBJDUMP  = riscv64-unknown-elf-objdump
CFLAGS   = -march=rv32i -mabi=ilp32 -Os -fno-builtin -nostdlib -ffreestanding \
           -ffunction-sections -fdata-sections
LDFLAGS  = -T ldx.ld -nostdlib -Wl,--gc-sections

# Host-side aarch64 cross-compile for the A53 daemons
A53_CC      = aarch64-linux-gnu-gcc
A53_CFLAGS  = -static -O2 -Wall

all: hello.bin hello.dis hello.hex cfu_test.bin cfu_test.dis cfu_test.hex \
     mesh2_a.bin mesh2_a.dis mesh2_a.hex mesh2_b.bin mesh2_b.dis mesh2_b.hex \
     wf_a.bin wf_a.dis wf_a.hex wf_b.bin wf_b.dis wf_b.hex \
     wc_a.bin wc_a.dis wc_a.hex wc_b.bin wc_b.dis wc_b.hex \
     universal.bin universal.dis universal.hex \
     worker.bin worker.dis worker.hex \
     sha_pipeline.bin sha_pipeline.dis sha_pipeline.hex \
     sha_stage.bin sha_stage.dis sha_stage.hex \
     sha_stage25.bin sha_stage25.dis sha_stage25.hex \
     ldx_daemon mesh_daemon sha_test_host sha_pipe_host

ldx_daemon: ldx_daemon.c
	$(A53_CC) $(A53_CFLAGS) -o $@ $<

mesh_daemon: mesh_daemon.c
	$(A53_CC) $(A53_CFLAGS) -o $@ $<

sha_test_host: sha_test_host.c
	$(A53_CC) $(A53_CFLAGS) -o $@ $<

sha_pipe_host: sha_pipe_host.c
	$(A53_CC) $(A53_CFLAGS) -o $@ $< -lpthread

hello.elf: hello.c ldx.ld start.S
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ start.S hello.c

cfu_test.elf: cfu_test.c ldx.ld start.S
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ start.S cfu_test.c

mesh2_a.elf: mesh2_a.c ldx.ld start.S
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ start.S mesh2_a.c

mesh2_b.elf: mesh2_b.c ldx.ld start.S
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ start.S mesh2_b.c

wf_a.elf: wf_a.c mesh.h ldx.ld start.S
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ start.S wf_a.c

wf_b.elf: wf_b.c mesh.h ldx.ld start.S
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ start.S wf_b.c

wc_a.elf: wc_a.c mesh.h ldx.ld start.S
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ start.S wc_a.c

wc_b.elf: wc_b.c mesh.h ldx.ld start.S
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ start.S wc_b.c

universal.elf: universal.c mesh.h ldx.ld start.S
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ start.S universal.c

worker.elf: worker.c mesh.h ldx.ld start.S
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ start.S worker.c

sha_pipeline.elf: sha_pipeline.c mesh.h ldx.ld start.S
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ start.S sha_pipeline.c

sha_stage.elf: sha_stage.c mesh.h ldx.ld start.S
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ start.S sha_stage.c

sha_stage25.elf: sha_stage25.c mesh.h ldx.ld start.S
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ start.S sha_stage25.c

%.bin: %.elf
	$(OBJCOPY) -O binary $< $@

%.dis: %.elf
	$(OBJDUMP) -d $< > $@

# Verilog $readmemh hex (word-per-line, little-endian bytes). Padded to 1024
# words (4 KB BRAM) with NOPs so it can be loaded into any sim node directly.
%.hex: %.bin
	python3 -c "import sys; b=open('$<','rb').read(); \
		pad=(-len(b))%4; b+=b'\\x00'*pad; \
		words=[int.from_bytes(b[i:i+4],'little') for i in range(0,len(b),4)]; \
		words += [0x00000013]*(1024-len(words)); \
		print('\\n'.join('{:08x}'.format(w) for w in words))" > $@

clean:
	rm -f *.elf *.bin *.dis *.hex ldx_daemon mesh_daemon

.PHONY: all clean
