CC      = gcc
CXX     = g++
CFLAGS  = -Wall -Wextra -O2 -fPIC -fno-builtin
CXXFLAGS = -Wall -Wextra -O2 -fPIC -fno-builtin -std=c++17
LDFLAGS = -ldl -lm -lpthread -lstdc++
LDX_SRC = src/ldx.c src/ldx_pbv.c
LDX_HDR = src/ldx.h src/ldx_pbv.h
LDX_CXX_SRC = src/ldx_pipe.cpp
LDX_CXX_HDR = src/ldx_pipe.h

# Object files for mixed C/C++ linking
LDX_C_OBJ = src/ldx.o src/ldx_pbv.o
LDX_CXX_OBJ = src/ldx_pipe.o

LDX_SOCK_SRC = src/ldx_socket_pipe.cpp
LDX_SOCK_HDR = src/ldx_socket_pipe.h

all: libldx.so ldx-container test/test_basic test/test_hooks test/test_pbv test/test_pipe test/test_preload test/preload_hook.so

src/ldx.o: src/ldx.c $(LDX_HDR)
	$(CC) $(CFLAGS) -c -o $@ $<

src/ldx_pbv.o: src/ldx_pbv.c $(LDX_HDR) src/ldx_pbv.h
	$(CC) $(CFLAGS) -c -o $@ $<

src/ldx_pipe.o: src/ldx_pipe.cpp src/ldx_pipe.h
	$(CXX) $(CXXFLAGS) -c -o $@ $<

src/ldx_socket_pipe.o: src/ldx_socket_pipe.cpp $(LDX_SOCK_HDR) src/ldx_pipe.h
	$(CXX) $(CXXFLAGS) -c -o $@ $<

src/ldx_container.o: src/ldx_container.c
	$(CC) $(CFLAGS) -c -o $@ $<

libldx.so: $(LDX_C_OBJ) $(LDX_CXX_OBJ) src/ldx_socket_pipe.o
	$(CXX) $(CXXFLAGS) -shared -o $@ $^ $(LDFLAGS)

gen/ldx_syscall_pbv.o: gen/ldx_syscall_pbv.cpp gen/ldx_syscall_pbv.h $(LDX_CXX_HDR) $(LDX_SOCK_HDR)
	$(CXX) $(CXXFLAGS) -I src -c -o $@ $<

ldx-container: src/ldx_container_main.cpp src/ldx_container.o gen/ldx_syscall_pbv.o $(LDX_C_OBJ) $(LDX_CXX_OBJ) src/ldx_socket_pipe.o
	$(CXX) $(CXXFLAGS) -I gen -o $@ $^ $(LDFLAGS) -lpthread

test/test_basic: test/test_basic.c $(LDX_SRC) $(LDX_HDR)
	$(CC) $(CFLAGS) -fno-builtin-strlen -fno-builtin-sin -o $@ test/test_basic.c $(LDX_SRC) $(LDFLAGS)

test/test_hooks: test/test_hooks.c $(LDX_SRC) $(LDX_HDR)
	$(CC) $(CFLAGS) -fno-builtin-strlen -fno-builtin-sin -fno-builtin-cos -o $@ test/test_hooks.c $(LDX_SRC) $(LDFLAGS)

test/test_pbv: test/test_pbv.c $(LDX_SRC) $(LDX_HDR)
	$(CC) $(CFLAGS) -fno-builtin-strlen -o $@ test/test_pbv.c $(LDX_SRC) $(LDFLAGS)

test/test_pipe: test/test_pipe.cpp $(LDX_C_OBJ) $(LDX_CXX_OBJ) $(LDX_CXX_HDR)
	$(CXX) $(CXXFLAGS) -fno-builtin-strlen -o $@ test/test_pipe.cpp $(LDX_C_OBJ) $(LDX_CXX_OBJ) $(LDFLAGS)

test/test_preload: test/test_preload.c
	$(CC) $(CFLAGS) -fno-builtin-strlen -o $@ test/test_preload.c

test/preload_hook.so: test/preload_hook.c $(LDX_SRC) $(LDX_HDR)
	$(CC) $(CFLAGS) -shared -o $@ test/preload_hook.c $(LDX_SRC) $(LDFLAGS)

test: test/test_basic test/test_hooks test/test_pbv test/test_pipe test/test_syscall_pbv test/test_preload test/preload_hook.so
	@echo "=== Direct-link tests ==="
	./test/test_basic
	@echo ""
	@echo "=== Hook/profiler tests ==="
	./test/test_hooks
	@echo ""
	@echo "=== PbV tests ==="
	./test/test_pbv
	@echo ""
	@echo "=== Pipe tests ==="
	./test/test_pipe
	@echo ""
	@echo "=== Syscall PbV tests ==="
	./test/test_syscall_pbv
	@echo ""
	@echo "=== LD_PRELOAD test ==="
	LD_PRELOAD=./test/preload_hook.so ./test/test_preload

# --- Generated syscall PbV wrappers ---
gen: gen/libldx_syscall.so

gen/ldx_syscall_pbv.h gen/ldx_syscall_pbv.cpp: tools/gen_syscall_pbv.py
	python3 tools/gen_syscall_pbv.py

gen/libldx_syscall.so: gen/ldx_syscall_pbv.cpp gen/ldx_syscall_pbv.h $(LDX_C_OBJ) $(LDX_CXX_OBJ)
	$(CXX) $(CXXFLAGS) -shared -I src -o $@ gen/ldx_syscall_pbv.cpp $(LDX_C_OBJ) $(LDX_CXX_OBJ) $(LDFLAGS)

test/test_syscall_pbv: test/test_syscall_pbv.cpp gen/ldx_syscall_pbv.o $(LDX_C_OBJ) $(LDX_CXX_OBJ) src/ldx_socket_pipe.o
	$(CXX) $(CXXFLAGS) -I src -I gen -o $@ test/test_syscall_pbv.cpp gen/ldx_syscall_pbv.o $(LDX_C_OBJ) $(LDX_CXX_OBJ) src/ldx_socket_pipe.o $(LDFLAGS)

clean:
	rm -f libldx.so ldx-container src/*.o gen/*.so test/test_basic test/test_hooks test/test_pbv test/test_pipe test/test_preload test/preload_hook.so test/test_syscall_pbv

.PHONY: all test gen clean
