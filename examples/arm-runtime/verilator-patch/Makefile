# Build natively on an aarch64 Linux box with verilator + g++ in PATH.
# (On the ZCU104: install verilator first; see /opt/src/verilator.)

VERILATOR ?= verilator
RT_DIR    := ..

all: obj_dir/VCounter

obj_dir/VCounter: Counter.v vsim_main.cpp mesh_host.c mesh_host.h $(RT_DIR)/ldx_rt.c $(RT_DIR)/ldx_rt.h
	$(VERILATOR) --cc Counter.v \
	    --exe vsim_main.cpp mesh_host.c $(RT_DIR)/ldx_rt.c \
	    -CFLAGS "-I$(RT_DIR) -I." \
	    --build

run: obj_dir/VCounter
	./obj_dir/VCounter

clean:
	rm -rf obj_dir

.PHONY: all run clean
