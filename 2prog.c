/* FIS to LMB */
//XGpio => XGpioPs or XGpio_Hw.h
#include "stdint.h"
#include "stdbool.h"
#include "xgpio.h"
#include "xparameters.h"

/* ============================================================
   1. Configure GPIO
   ============================================================ */
#define GPIO_BASE_ADDR      XPAR_GPIO_0_BASEADDR
#define GPIO_CHANNEL        1
#define TRIGGER_PIN         0

/* ============================================================
   2. Configure LMB Peripheral
   ============================================================ */
#define SATA_FIS_LMB_BASE   0x43C00000U  /* Address set in XDC/Block Design */
#define LMB_FIS_DATA_REG    (SATA_FIS_LMB_BASE + 0x00)
#define LMB_FIS_CTRL_REG    (SATA_FIS_LMB_BASE + 0x04)

/* Control register bit definitions */
#define CTRL_WR_BIT         (1U << 0)    /* Write data to IP */
#define CTRL_BUSY_MASK      (1U << 1)    /* IP is busy (FIFO full/processing) */
#define CTRL_DONE_MASK      (1U << 2)    /* FIS successfully received by PHY */

/* ============================================================
   3. DMA SETUP FIS STRUCTURE (20 bytes, SATA 3.3 Table 10-10)
   ============================================================ */
typedef struct __attribute__((packed)) {
    uint8_t  fis_type;      /* [0] 0x41 */
    uint8_t  reserved1;     /* [1] 0x00 */
    uint8_t  command;       /* [2] 0x44 (OPEN/CLOSE MEDIA) */
    uint8_t  features;      /* [3] 0x01 (OPEN TRAY) */
    uint8_t  sector_count;  /* [4] 0x00 */
    uint8_t  lba_low;       /* [5] 0x00 */
    uint8_t  lba_mid;       /* [6] 0x00 */
    uint8_t  lba_high;      /* [7] 0x00 */
    uint8_t  device;        /* [8] 0xE0 (ATAPI + LBA) */
    uint8_t  command2;      /* [9] 0x00 (Reserved) */
    uint8_t  reserved[10];  /* [10-19] 0x00 */
} DmaSetupFis_t;

/* ============================================================
   4. HELPER FUNCTIONS
   ============================================================ */

/// Computes CRC-16 for SATA FIS (polynomial 0x8005, init 0xFFFF)
static uint16_t sata_crc16(const uint8_t *data, int len)
{
    uint16_t crc = 0xFFFF;
    for (int i = 0; i < len; i++) {
        crc ^= (uint16_t)data[i];
        for (int b = 0; b < 8; b++) {
            crc = (crc & 0x8000) ? (crc << 1) ^ 0x8005 : (crc << 1);
        }
    }
    return crc;
}

/// Writes a 32-bit word to an LMB register
static void lmb_write32(uint32_t addr, uint32_t val)
{
    *(volatile uint32_t *)addr = val;
}

/// Reads a 32-bit word from an LMB register
static uint32_t lmb_read32(uint32_t addr)
{
    return *(volatile uint32_t *)addr;
}

/// Sends a complete FIS via LMB
static void send_fis_via_lmb(const DmaSetupFis_t *fis)
{
    uint8_t *bytes = (uint8_t *)fis;

    for (int i = 0; i < 5; i++) {
        /* Assembles a 32-bit word (Little Endian) */
        uint32_t word = (uint32_t)bytes[i*4] |
                        ((uint32_t)bytes[i*4+1] << 8) |
                        ((uint32_t)bytes[i*4+2] << 16) |
                        ((uint32_t)bytes[i*4+3] << 24);

        /* Waits until the HDL IP frees the buffer */
        while (lmb_read32(LMB_FIS_CTRL_REG) & CTRL_BUSY_MASK) {
            /* In a production environment, add a watchdog/timer */
        }

        /* Writes data to the IP */
        lmb_write32(LMB_FIS_DATA_REG, word);

        /* Generates a WR pulse */
        lmb_write32(LMB_FIS_CTRL_REG, lmb_read32(LMB_FIS_CTRL_REG) | CTRL_WR_BIT);
        lmb_write32(LMB_FIS_CTRL_REG, lmb_read32(LMB_FIS_CTRL_REG) & ~CTRL_WR_BIT);
    }
}

/* ============================================================
   5. MAIN
   ============================================================ */
int main(void)
{
    XGpio GpioInst;
    DmaSetupFis_t open_fis;
    int status;

    /* 1. Initialize GPIO */
    status = XGpio_Initialize(&GpioInst, XPAR_GPIO_0_DEVICE_ID);
    if (status != XST_SUCCESS) while(1);
    XGpio_SetDataDirection(&GpioInst, GPIO_CHANNEL, 0xFFFFFFFF);

    /* 2. Construct FIS (OPEN TRAY) */
    open_fis.fis_type     = 0x41;
    open_fis.command      = 0x44;
    open_fis.features     = 0x01;
    open_fis.device       = 0xE0;
    /* Remaining fields set to 0x00 */
    for (int i = 0; i < 10; i++) open_fis.reserved[i] = 0x00;

    /* 3. Main loop */
    while (1) {
        if (XGpio_DiscreteRead(&GpioInst, GPIO_CHANNEL) & (1U << TRIGGER_PIN)) {
            /* Software debouncing (replace with timer/IRQ in production) */
            for (volatile int d = 0; d < 50000; d++);

            send_fis_via_lmb(&open_fis);

            /* Optional: wait for D2H FIS from HDL */
            /* while (!(lmb_read32(LMB_FIS_CTRL_REG) & CTRL_DONE_MASK)); */
        }
    }

    return 0;
}
