#include "stdint.h"
#include "stdbool.h"
#include "xgpio.h"
#include "xparameters.h"

/* ============================================================
   1. Config REGs
   ============================================================ */
#define GPIO_BASE_ADDR      0x41200000U
#define GPIO_CHANNEL        1U
#define GPIO_TRIGGER_PIN    0U  /* Пин, к которому подключен триггер */

#define AXIS_FIFO_BASE      0x40000000U
#define AXIS_TDATA_REG      (AXIS_FIFO_BASE + 0x00)
#define AXIS_TVALID_REG     (AXIS_FIFO_BASE + 0x04)
#define AXIS_TLAST_REG      (AXIS_FIFO_BASE + 0x08)
#define AXIS_STATUS_REG     (AXIS_FIFO_BASE + 0x0C)
#define AXIS_TXFULL_MASK    0x00000001U
#define AXIS_TXEMPTY_MASK   0x00000002U

/* ============================================================
   2. SATA FIS struct (DMA Setup FIS, 20 bytes)
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
    uint8_t  device;        /* [8] 0xE0 (ATAPI, LBA mode) */
    uint8_t  command2;      /* [9] 0x00 (Reserved per SATA 3.3 Table 10-10) */
    uint8_t  reserved[10];  /* [10-19] 0x00 */
} DmaSetupFis_t;

/* ============================================================
   3. Funcs
   ============================================================ */

///
 //  Send 32-bit word to AXI Stream

static void axis_stream_write_word(uint32_t data, bool is_last)
{
    /* wait FIFO rdy */
    while (Xil_In32(AXIS_STATUS_REG) & AXIS_TXFULL_MASK) {

    }

    /* Wr data */
    Xil_Out32(AXIS_TDATA_REG, data);

    /* set TVALID */
    Xil_Out32(AXIS_TVALID_REG, 0x01);

    /* set TLAST on lasd word (20 Bytes = 5 wrds) */
    if (is_last) {
        Xil_Out32(AXIS_TLAST_REG, 0x01);
    } else {
        Xil_Out32(AXIS_TLAST_REG, 0x00);
    }

    /* reset TVALID  */
    Xil_Out32(AXIS_TVALID_REG, 0x00);
}

///
 //Send full FIS (20B) to AXI Stream

static void send_sata_fis(const DmaSetupFis_t *fis)
{
    uint8_t *bytes = (uint8_t *)fis;
    
    for (int i = 0; i &lt; 5; i++) {
        uint32_t word = (uint32_t)bytes[i*4] |
                        ((uint32_t)bytes[i*4+1] &lt;&lt; 8) |
                        ((uint32_t)bytes[i*4+2] &lt;&lt; 16) |
                        ((uint32_t)bytes[i*4+3] &lt;&lt; 24);
        
        bool last = (i == 4);
        axis_stream_write_word(word, last);
    }
}

/* ============================================================
   4. Main Func
   ============================================================ */
int main(void)
{
    XGpio GpioInst;
    DmaSetupFis_t open_fis;
    int status;

    /* 1. init GPIO */
    status = XGpio_Initialize(&GpioInst, XPAR_GPIO_0_DEVICE_ID);
    if (status != XST_SUCCESS) {
        /* init err processing */
        while(1); 
    }

    /* Chnl 1 as input */
    XGpio_SetDataDirection(&GpioInst, GPIO_CHANNEL, 0xFFFFFFFF);

    /* 2. DMA Setup FIS for OPEN TRAY */
    open_fis.fis_type     = 0x41;
    open_fis.reserved1    = 0x00;
    open_fis.command      = 0x44; /* OPEN/CLOSE MEDIA */
    open_fis.features     = 0x01; /* 0x01 = Open, 0x02 = Close */
    open_fis.sector_count = 0x00;
    open_fis.lba_low      = 0x00;
    open_fis.lba_mid      = 0x00;
    open_fis.lba_high     = 0x00;
    open_fis.device       = 0xE0; /* ATAPI + LBA mode */
    open_fis.command2     = 0x00;
    for (int i = 0; i &lt; 10; i++) open_fis.reserved[i] = 0x00;

    /* 3. Main cycle */
    while (1) {
        /* Wait rise front on GPIO */
        uint32_t gpio_val = XGpio_DiscreteRead(&GpioInst, GPIO_CHANNEL);
        
        if (gpio_val & (1U &lt;&lt; GPIO_TRIGGER_PIN)) {
            /* simple debounce (beter use timer/IRQ) */
            for (volatile int d = 0; d &lt; 50000; d++);

            /* Send FIS */
            send_sata_fis(&open_fis);

            /* Optionally: wait D2H FIS from HDL*/
            /* read_d2h_fis_from_fifo(); */
        }
    }

    return 0;
}