# Build mb_run for the ZCU104 ARM (aarch64).
#   on the board (native):   make
#   cross from x86:          make CROSS=aarch64-linux-gnu-
CROSS  ?=
CC     := $(CROSS)gcc
CFLAGS := -O2 -Wall

mb_run: mb_run.c mb_host.h
	$(CC) $(CFLAGS) -o $@ mb_run.c

clean:
	rm -f mb_run
