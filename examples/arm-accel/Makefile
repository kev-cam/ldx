CROSS    = aarch64-linux-gnu-
CC       = $(CROSS)gcc
OBJDUMP  = $(CROSS)objdump
CFLAGS   = -O2 -fno-builtin
REWRITER = ../../python/arm_rewrite.py

all: accel_demo accel_demo.hw

accel_demo: accel_demo.c
	$(CC) $(CFLAGS) -o $@ $< -lm

accel_demo.hw: accel_demo math_accel.json
	python3 $(REWRITER) -i $< -o $@ -m math_accel.json

scan: accel_demo
	python3 $(REWRITER) -i $< --scan

diff: accel_demo accel_demo.hw
	@echo "=== Original compute ===" && $(OBJDUMP) -d accel_demo | sed -n '/<compute>:/,/ret$$/p'
	@echo "" && echo "=== Patched compute ===" && $(OBJDUMP) -d accel_demo.hw | sed -n '/<compute>:/,/ret$$/p'

clean:
	rm -f accel_demo accel_demo.hw

.PHONY: all scan diff clean
