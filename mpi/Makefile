# ldx/mpi — MPI interposition tools (opt-in: requires mpicc; not part of top-level `all`)
MPICC ?= mpicc
MPICXX ?= mpicxx
CFLAGS ?= -O2 -Wall -Wextra
# libshmcomm.so needs Epetra headers matching the libepetra.so the target links
TRILINOS_INC ?= $(HOME)/trilinos-mpi/include

all: libmpicount.so bench/c2c_pingpong bench/shm_allreduce bench/shm_allreduce2 bench/mpi_allreduce_bench

libmpicount.so: mpi_count.c
	$(MPICC) $(CFLAGS) -shared -fPIC -o $@ $< -ldl

# separate target: only builds where Trilinos headers exist
shmcomm: libshmcomm.so
libshmcomm.so: shmcomm.cpp
	$(MPICXX) -std=c++17 $(CFLAGS) -shared -fPIC -o $@ $< -I$(TRILINOS_INC) -lrt

bench/c2c_pingpong: bench/c2c_pingpong.c
	$(CC) $(CFLAGS) -o $@ $< -lpthread

bench/shm_allreduce: bench/shm_allreduce.c
	$(CC) $(CFLAGS) -o $@ $< -lpthread

bench/shm_allreduce2: bench/shm_allreduce2.c
	$(CC) $(CFLAGS) -o $@ $< -lpthread

bench/mpi_allreduce_bench: bench/mpi_allreduce_bench.c
	$(MPICC) $(CFLAGS) -o $@ $<

clean:
	rm -f libmpicount.so libshmcomm.so bench/c2c_pingpong bench/shm_allreduce bench/shm_allreduce2 bench/mpi_allreduce_bench

.PHONY: all shmcomm clean
