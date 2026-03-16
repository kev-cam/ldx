CC      = gcc
CFLAGS  = -Wall -Wextra -O2 -fPIC -fno-builtin
LDFLAGS = -ldl -lm -lpthread

all: libldx.so test/test_basic test/test_hooks test/test_preload test/preload_hook.so

libldx.so: src/ldx.c src/ldx.h
	$(CC) $(CFLAGS) -shared -o $@ src/ldx.c $(LDFLAGS)

test/test_basic: test/test_basic.c src/ldx.c src/ldx.h
	$(CC) $(CFLAGS) -fno-builtin-strlen -fno-builtin-sin -o $@ test/test_basic.c src/ldx.c $(LDFLAGS)

test/test_hooks: test/test_hooks.c src/ldx.c src/ldx.h
	$(CC) $(CFLAGS) -fno-builtin-strlen -fno-builtin-sin -fno-builtin-cos -o $@ test/test_hooks.c src/ldx.c $(LDFLAGS)

test/test_preload: test/test_preload.c
	$(CC) $(CFLAGS) -fno-builtin-strlen -o $@ test/test_preload.c

test/preload_hook.so: test/preload_hook.c src/ldx.c src/ldx.h
	$(CC) $(CFLAGS) -shared -o $@ test/preload_hook.c src/ldx.c $(LDFLAGS)

test: test/test_basic test/test_hooks test/test_preload test/preload_hook.so
	@echo "=== Direct-link tests ==="
	./test/test_basic
	@echo ""
	@echo "=== Hook/profiler tests ==="
	./test/test_hooks
	@echo ""
	@echo "=== LD_PRELOAD test ==="
	LD_PRELOAD=./test/preload_hook.so ./test/test_preload

clean:
	rm -f libldx.so test/test_basic test/test_hooks test/test_preload test/preload_hook.so

.PHONY: all test clean
