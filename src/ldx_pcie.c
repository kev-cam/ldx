/* ldx_pcie.c — Userspace PCIe BAR access for FPGA accelerator. */

#include "ldx_pcie.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/mman.h>
#include <sys/stat.h>

/* Read a hex value from a sysfs file. */
static uint32_t read_sysfs_hex(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    uint32_t val = 0;
    fscanf(f, "%x", &val);
    fclose(f);
    return val;
}

/* Scan /sys/bus/pci/devices/ for Altera 1172:E001. */
static int find_device(char *out, size_t len) {
    const char *base = "/sys/bus/pci/devices";
    DIR *d = opendir(base);
    if (!d) return -1;

    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (ent->d_name[0] == '.') continue;

        char path[512];
        snprintf(path, sizeof(path), "%s/%s/vendor", base, ent->d_name);
        uint32_t vendor = read_sysfs_hex(path);

        snprintf(path, sizeof(path), "%s/%s/device", base, ent->d_name);
        uint32_t device = read_sysfs_hex(path);

        if (vendor == 0x1172 && device == 0xE001) {
            snprintf(out, len, "%s/%s", base, ent->d_name);
            closedir(d);
            return 0;
        }
    }
    closedir(d);
    return -1;
}

ldx_pcie *ldx_pcie_open(const char *sysfs_path) {
    ldx_pcie *dev = calloc(1, sizeof(ldx_pcie));
    if (!dev) return NULL;

    /* Find device */
    if (sysfs_path) {
        snprintf(dev->sysfs_path, sizeof(dev->sysfs_path), "%s", sysfs_path);
    } else {
        if (find_device(dev->sysfs_path, sizeof(dev->sysfs_path)) < 0) {
            fprintf(stderr, "ldx_pcie: no Altera 1172:E001 device found\n");
            free(dev);
            return NULL;
        }
    }

    /* Enable device if not already */
    char path[512];
    snprintf(path, sizeof(path), "%s/enable", dev->sysfs_path);
    FILE *f = fopen(path, "w");
    if (f) { fprintf(f, "1"); fclose(f); }

    /* Open BAR0 resource file */
    snprintf(path, sizeof(path), "%s/resource0", dev->sysfs_path);
    dev->fd = open(path, O_RDWR | O_SYNC);
    if (dev->fd < 0) {
        perror("ldx_pcie: open resource0");
        free(dev);
        return NULL;
    }

    /* Get BAR0 size from resource file */
    snprintf(path, sizeof(path), "%s/resource", dev->sysfs_path);
    f = fopen(path, "r");
    if (f) {
        unsigned long long start, end, flags;
        if (fscanf(f, "%llx %llx %llx", &start, &end, &flags) == 3) {
            dev->bar0_size = (size_t)(end - start + 1);
        }
        fclose(f);
    }
    if (dev->bar0_size == 0)
        dev->bar0_size = 8192;  /* default 8KB */

    /* mmap BAR0 */
    dev->bar0 = mmap(NULL, dev->bar0_size, PROT_READ | PROT_WRITE,
                     MAP_SHARED, dev->fd, 0);
    if (dev->bar0 == MAP_FAILED) {
        perror("ldx_pcie: mmap BAR0");
        close(dev->fd);
        free(dev);
        return NULL;
    }

    /* Verify magic */
    uint32_t magic = ldx_pcie_magic(dev);
    if (magic != LDX_PCIE_MAGIC) {
        fprintf(stderr, "ldx_pcie: bad magic 0x%08X (expected 0x%08X)\n",
                magic, LDX_PCIE_MAGIC);
        fprintf(stderr, "ldx_pcie: FPGA may not have ldx bitstream loaded\n");
        /* Continue anyway — useful for debugging */
    }

    dev->n_slots = ldx_pcie_n_slots(dev);
    return dev;
}

void ldx_pcie_close(ldx_pcie *dev) {
    if (!dev) return;
    if (dev->bar0 && dev->bar0 != MAP_FAILED)
        munmap((void *)dev->bar0, dev->bar0_size);
    if (dev->fd >= 0)
        close(dev->fd);
    free(dev);
}

/* Read a 32-bit register at byte offset within BAR0. */
static inline uint32_t bar_read(ldx_pcie *dev, unsigned offset) {
    return dev->bar0[offset / 4];
}

/* Write a 32-bit register at byte offset within BAR0. */
static inline void bar_write(ldx_pcie *dev, unsigned offset, uint32_t val) {
    dev->bar0[offset / 4] = val;
}

uint32_t ldx_pcie_call32(ldx_pcie *dev, int slot,
                         const uint32_t *args, int n_args) {
    unsigned base = slot * LDX_PCIE_SLOT_SIZE;

    /* Write arguments */
    for (int i = 0; i < n_args; i++)
        bar_write(dev, base + LDX_PCIE_ARG_BASE + i * 4, args[i]);

    /* Read result — combinational, available immediately */
    return bar_read(dev, base + LDX_PCIE_RESULT_LO);
}

uint64_t ldx_pcie_call64(ldx_pcie *dev, int slot,
                         const uint32_t *args, int n_args) {
    unsigned base = slot * LDX_PCIE_SLOT_SIZE;

    for (int i = 0; i < n_args; i++)
        bar_write(dev, base + LDX_PCIE_ARG_BASE + i * 4, args[i]);

    uint32_t lo = bar_read(dev, base + LDX_PCIE_RESULT_LO);
    uint32_t hi = bar_read(dev, base + LDX_PCIE_RESULT_HI);
    return ((uint64_t)hi << 32) | lo;
}

uint32_t ldx_pcie_magic(ldx_pcie *dev) {
    return bar_read(dev, LDX_PCIE_GLOBAL_BASE + 0x00);
}

uint32_t ldx_pcie_version(ldx_pcie *dev) {
    return bar_read(dev, LDX_PCIE_GLOBAL_BASE + 0x04);
}

uint32_t ldx_pcie_n_slots(ldx_pcie *dev) {
    return bar_read(dev, LDX_PCIE_GLOBAL_BASE + 0x08);
}
