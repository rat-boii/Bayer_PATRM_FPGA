/* Bring-up test (step 4.1): proves the UART, the PS and the GP0 path to the engine registers.
 *
 * Loaded over JTAG after the bitstream and ps7_init (scripts/board/load_run.tcl). Prints to UART1, 115200 8N1:
 *   hello, the PS silicon information it can read, then BUILD_ID and STATUS of the engine, and one final line
 *   BRINGUP PASS or BRINGUP FAIL.
 * Expected for the grayscale build: BUILD_ID = 0x00401001 (VERSION 1, BUILD_TYPE 0, MODES 001, BLOCK_LEN_MAX 64),
 * STATUS = 0x00000000 after reset.
 * A read over GP0 hangs if the bitstream is not loaded or the PL reset is still active.
 */
#include "xil_io.h"
#include "xil_printf.h"
#include "xpseudo_asm.h"
#include "xreg_cortexa9.h"
#include "patrm_regs.h"

#define PATRM_BASE            0x43C00000U   /* spec/memory_map.md section 2, assigned in vivado/build.tcl */
#define SLCR_PSS_IDCODE       0xF8000530U   /* device code of the PS */
#define DEVCFG_MCTRL          0xF8007080U   /* bits 31:28 = PS_VERSION */
#define PS_VERSION_SHIFT      28U

#define EXPECTED_MODES        1U            /* grayscale only */
#define EXPECTED_BLOCK_LEN    64U           /* D15 */
#define EXPECTED_BUILD_ID     ((PATRM_VERSION << PATRM_BUILD_ID_VERSION_SHIFT) | \
                               (EXPECTED_MODES << PATRM_BUILD_ID_MODES_SHIFT) | \
                               (EXPECTED_BLOCK_LEN << PATRM_BUILD_ID_BLOCK_LEN_MAX_SHIFT))

static u32 field(u32 value, u32 mask, u32 shift)
{
    return (value & mask) >> shift;
}

int main(void)
{
    u32 idcode, mctrl, midr, build_id, status;

    xil_printf("\r\nhello from the ZedBoard (PATRM bring-up, step 4.1)\r\n");

    idcode = Xil_In32(SLCR_PSS_IDCODE);
    mctrl  = Xil_In32(DEVCFG_MCTRL);
    midr   = mfcp(XREG_CP15_MAIN_ID);
    xil_printf("PS IDCODE   0x%08x\r\n", idcode);
    xil_printf("PS_VERSION  %d (MCTRL 0x%08x; 0 = silicon 1.0, 1 = 2.0, 2 = 3.0, 3 = 3.1)\r\n",
               (int)(mctrl >> PS_VERSION_SHIFT), mctrl);
    xil_printf("A9 MIDR     0x%08x\r\n", midr);

    build_id = Xil_In32(PATRM_BASE + PATRM_BUILD_ID_OFFSET);
    status   = Xil_In32(PATRM_BASE + PATRM_STATUS_OFFSET);

    xil_printf("BUILD_ID    0x%08x (expected 0x%08x)\r\n", build_id, (u32)EXPECTED_BUILD_ID);
    xil_printf("  VERSION %d, BUILD_TYPE %d, MODES %d, BLOCK_LEN_MAX %d\r\n",
               (int)field(build_id, PATRM_BUILD_ID_VERSION_MASK, PATRM_BUILD_ID_VERSION_SHIFT),
               (int)field(build_id, PATRM_BUILD_ID_BUILD_TYPE_MASK, PATRM_BUILD_ID_BUILD_TYPE_SHIFT),
               (int)field(build_id, PATRM_BUILD_ID_MODES_MASK, PATRM_BUILD_ID_MODES_SHIFT),
               (int)field(build_id, PATRM_BUILD_ID_BLOCK_LEN_MAX_MASK, PATRM_BUILD_ID_BLOCK_LEN_MAX_SHIFT));
    xil_printf("STATUS      0x%08x (expected 0x00000000)\r\n", status);

    if (build_id == EXPECTED_BUILD_ID && status == 0U) {
        xil_printf("BRINGUP PASS\r\n");
    } else {
        xil_printf("BRINGUP FAIL\r\n");
    }
    return 0;
}
