// hello.c — first VexRiscv hello-world for ldx_soc_axi.
//   Writes each char of "Hello\n" to MBOX_DATA, busy-waiting on
//   MBOX_STATUS[0] between chars. When all done, spins forever.

#define MBOX_DATA   (*(volatile unsigned int *)0xF0000000)
#define MBOX_STATUS (*(volatile unsigned int *)0xF0000004)

static void putc(int c) {
    MBOX_DATA = (unsigned int)c;
    while (MBOX_STATUS & 1u) { /* spin while pending */ }
}

void main(void) {
    const char *s = "Hello\n";
    while (*s) putc(*s++);
    for (;;) { }
}
