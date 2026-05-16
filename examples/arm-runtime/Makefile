CC      = aarch64-linux-gnu-gcc
CFLAGS  = -O1 -Wall -Wextra -fno-pie -no-pie
LDFLAGS = -fno-pie -no-pie

all: patch_demo

patch_demo: patch_demo.c ldx_rt.c ldx_rt.h
	$(CC) $(CFLAGS) $(LDFLAGS) -static -o $@ patch_demo.c ldx_rt.c

# Disassembly is handy when debugging the offset arithmetic.
disasm: patch_demo
	aarch64-linux-gnu-objdump -d patch_demo > patch_demo.dis

clean:
	rm -f patch_demo patch_demo.dis

.PHONY: all clean disasm
