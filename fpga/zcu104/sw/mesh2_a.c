// mesh2_a.c — Core A (logical (0,0)): sends one msg E, awaits echo, parks.

#define E_PUSH    (*(volatile unsigned int *)0xF0000110)
#define E_POP     (*(volatile unsigned int *)0xF0000118)
#define E_POPSTAT (*(volatile unsigned int *)0xF000011C)
#define RESULT    (*(volatile unsigned int *)0x80000FFC)

void main(void) {
    E_PUSH = 0xCAFEBABE;
    while (E_POPSTAT & 1u) { }   // wait until non-empty
    unsigned int v = E_POP;
    RESULT = v;
    for (;;) { }
}
