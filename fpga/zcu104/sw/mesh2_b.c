// mesh2_b.c — Core B (logical (1,0)): forwarder; echoes whatever arrives from W.

#define W_PUSH    (*(volatile unsigned int *)0xF0000130)
#define W_POP     (*(volatile unsigned int *)0xF0000138)
#define W_POPSTAT (*(volatile unsigned int *)0xF000013C)
#define RESULT    (*(volatile unsigned int *)0x80000FFC)

void main(void) {
    unsigned int v = 0;
    while (W_POPSTAT & 1u) { }   // wait until non-empty
    v = W_POP;
    W_PUSH = v;
    RESULT = v;
    for (;;) { }
}
