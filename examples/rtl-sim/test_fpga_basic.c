/* test_fpga_basic.c — Basic FPGA connectivity test */

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>

#define LDX_BASE   0xA0000000UL
#define LDX_SIZE   0x20000U
#define MAGIC_OFF  0x19F00
#define MAGIC_VAL  0x4C445834u

int main(void) {
    printf("ZCU104 FPGA Basic Test\n");
    printf("======================\n");

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("/dev/mem");
        return 1;
    }

    void *p = mmap(NULL, LDX_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, LDX_BASE);
    if (p == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }
    close(fd);

    volatile uint32_t *regs = (volatile uint32_t *)p;
    uint32_t magic = regs[MAGIC_OFF >> 2];

    printf("FPGA Base:     0x%08lX\n", LDX_BASE);
    printf("Magic Offset:  0x%04X\n", MAGIC_OFF);
    printf("Expected:      0x%08X\n", MAGIC_VAL);
    printf("Actual:        0x%08X\n", magic);

    if (magic == MAGIC_VAL) {
        printf("✓ FPGA bitstream loaded correctly\n");
        printf("✓ Memory mapping working\n");
        printf("✓ Hardware ready for RTL simulation\n");
        munmap(p, LDX_SIZE);
        return 0;
    } else {
        printf("✗ FPGA magic mismatch - bitstream issue\n");
        munmap(p, LDX_SIZE);
        return 1;
    }
}