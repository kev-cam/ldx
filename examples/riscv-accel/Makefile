CROSS   = riscv64-linux-gnu-
CC      = $(CROSS)gcc
OBJDUMP = $(CROSS)objdump
CFLAGS  = -O2 -fno-builtin
REWRITER = ../../python/riscv_rewrite.py

all: accel_demo accel_demo.hw sim4state_demo sim4state_demo.hw

# Step 1: Compile with standard GCC
accel_demo: accel_demo.c
	$(CC) $(CFLAGS) -o $@ $< -lm

# Step 2: Rewrite for hardware accelerator
accel_demo.hw: accel_demo math_accel.json
	python3 $(REWRITER) -i $< -o $@ -m math_accel.json

# 4-state logic simulator example
sim4state_demo: sim4state_demo.c
	$(CC) $(CFLAGS) -o $@ $<

sim4state_demo.hw: sim4state_demo sim4state_accel.json
	python3 $(REWRITER) -i $< -o $@ -m sim4state_accel.json

# Show what changed
diff: accel_demo accel_demo.hw
	@echo "=== Original ==="
	$(OBJDUMP) -d accel_demo | grep -A1 -E '(sin|cos|sqrt)@plt' || true
	@echo ""
	@echo "=== Patched ==="
	$(OBJDUMP) -d accel_demo.hw | grep -B1 -A1 'custom' || true
	@echo ""
	@echo "=== Call sites in compute_trajectory ==="
	@echo "--- Before ---"
	$(OBJDUMP) -d accel_demo | sed -n '/<compute_trajectory>:/,/^$$/p' | head -30
	@echo "--- After ---"
	$(OBJDUMP) -d accel_demo.hw | sed -n '/<compute_trajectory>:/,/^$$/p' | head -30

# Scan for all rewritable call sites
scan: accel_demo
	python3 $(REWRITER) -i $< --scan

clean:
	rm -f accel_demo accel_demo.hw sim4state_demo sim4state_demo.hw

.PHONY: all diff scan clean
