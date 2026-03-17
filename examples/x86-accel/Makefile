CC       = gcc
CFLAGS   = -O2 -fPIC -fno-builtin
REWRITER = ../../python/x86_rewrite.py

all: accel_demo accel_demo.hw trap_handler.so

accel_demo: accel_demo.c
	$(CC) $(CFLAGS) -o $@ $< -lm

accel_demo.hw: accel_demo math_accel.json
	python3 $(REWRITER) -i $< -o $@ -m math_accel.json

trap_handler.so: ../../test/x86_trap_handler.c
	$(CC) $(CFLAGS) -shared -o $@ $< -lm

# Run original vs patched
run: accel_demo accel_demo.hw trap_handler.so
	@echo "=== Original ==="
	./accel_demo
	@echo ""
	@echo "=== Patched (UD2 trap → software sin/cos/sqrt) ==="
	LD_PRELOAD=./trap_handler.so ./accel_demo.hw

scan: accel_demo
	python3 $(REWRITER) -i $< --scan

diff: accel_demo accel_demo.hw
	@echo "=== Original compute ===" && objdump -d accel_demo | sed -n '/<compute>:/,/ret$$/p'
	@echo "" && echo "=== Patched compute ===" && objdump -d accel_demo.hw | sed -n '/<compute>:/,/ret$$/p'

clean:
	rm -f accel_demo accel_demo.hw trap_handler.so

.PHONY: all run scan diff clean
