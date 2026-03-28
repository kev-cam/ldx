/* ldx_pcie.h — Userspace PCIe BAR access for FPGA accelerator.
 *
 * Maps the PCIe BAR0 of the ldx FPGA accelerator and provides
 * functions to call c2v-generated hardware functions.
 *
 * Works on the Atom side of the DE2i-150 (or any machine with the
 * FPGA visible as a PCIe endpoint).
 *
 * Usage:
 *   ldx_pcie *dev = ldx_pcie_open(NULL);  // auto-detect
 *   uint32_t args[] = {42, 17};
 *   uint32_t result = ldx_pcie_call(dev, 0, args, 2);
 *   ldx_pcie_close(dev);
 */

#ifndef LDX_PCIE_H
#define LDX_PCIE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* BAR0 layout constants (must match pcie_bar_bridge.v) */
#define LDX_PCIE_SLOT_SIZE      0x100   /* 256 bytes per slot */
#define LDX_PCIE_GLOBAL_BASE    0x1F00
#define LDX_PCIE_MAGIC          0x4C445831  /* "LDX1" */
#define LDX_PCIE_ARG_BASE       0x00    /* offset within slot */
#define LDX_PCIE_RESULT_LO      0x40
#define LDX_PCIE_RESULT_HI      0x44
#define LDX_PCIE_STATUS         0x48

typedef struct ldx_pcie {
    int          fd;         /* /sys/...resource0 or /dev/uioN fd */
    volatile uint32_t *bar0; /* mmap'd BAR0 */
    size_t       bar0_size;
    uint32_t     n_slots;
    char         sysfs_path[256];
} ldx_pcie;

/* Open the FPGA device.  If sysfs_path is NULL, auto-detect by
 * scanning for Altera vendor 0x1172, device 0xE001. */
ldx_pcie *ldx_pcie_open(const char *sysfs_path);

/* Close and unmap. */
void ldx_pcie_close(ldx_pcie *dev);

/* Call a hardware function in slot `slot`.
 * Writes args to the slot's argument registers, reads back the result.
 * For combinational functions this is immediate (no polling needed). */
uint32_t ldx_pcie_call32(ldx_pcie *dev, int slot,
                         const uint32_t *args, int n_args);

uint64_t ldx_pcie_call64(ldx_pcie *dev, int slot,
                         const uint32_t *args, int n_args);

/* Read global registers. */
uint32_t ldx_pcie_magic(ldx_pcie *dev);
uint32_t ldx_pcie_version(ldx_pcie *dev);
uint32_t ldx_pcie_n_slots(ldx_pcie *dev);

#ifdef __cplusplus
}
#endif

#endif /* LDX_PCIE_H */
