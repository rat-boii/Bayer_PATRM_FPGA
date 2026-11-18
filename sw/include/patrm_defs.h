/* Constants shared by the PATRM driver and the test application (step 4.2). No hardware access here.
 * model/job.py holds the same values; model/test_job_layout.py compiles a check that they agree.
 */
#ifndef PATRM_DEFS_H
#define PATRM_DEFS_H

#define PATRM_REG_BASE        0x43C00000U   /* spec/memory_map.md section 2 */
#define PATRM_BUF_LO          0x0F000000U   /* image buffers: above the program area ... */
#define PATRM_BUF_HI          0x1F000000U   /* ... and below the job descriptor and result areas */
#define PATRM_COORD_LIMIT_PX  16384         /* D4: output corners must map inside +/- this many pixels */

/* Driver result codes. Stored in the result record, so the numbers must not change without changing model/job.py. */
typedef enum {
    PATRM_RC_OK = 0,
    PATRM_RC_BAD_LAYOUT = 1,       /* job descriptor of another layout version */
    PATRM_RC_BAD_JOB = 2,          /* repeat count or timeout out of range */
    PATRM_RC_BAD_SIZE = 3,         /* D3 or D11 */
    PATRM_RC_BAD_MODE = 4,         /* mode not in BUILD_ID.MODES */
    PATRM_RC_BAD_BLOCK_LEN = 5,    /* D13 */
    PATRM_RC_BAD_ADDR = 6,         /* buffer not aligned, outside the buffer area, or overlapping */
    PATRM_RC_BAD_TRANSFORM = 7,    /* D4 */
    PATRM_RC_BAD_BUILD_ID = 8,     /* register map version differs from this driver */
    PATRM_RC_BUSY = 9,             /* engine busy before the job */
    PATRM_RC_START_REJECTED = 10,  /* STATUS.ERROR right after START */
    PATRM_RC_TIMEOUT = 11,         /* DONE not set in time */
    PATRM_RC_NO_INTERRUPT = 12,    /* DONE is set, but the interrupt never arrived */
    PATRM_RC_BUS_ERROR = 13,       /* job ended with ERR_CODE = BUS_ERROR, output not trusted */
    PATRM_RC_ENGINE_ERROR = 14,    /* job ended with ERROR and another ERR_CODE */
    PATRM_RC_IRQ_SETUP = 15,       /* interrupt controller setup failed */
    PATRM_RC_NO_TIMER = 16         /* global timer does not count */
} patrm_rc_t;

#endif /* PATRM_DEFS_H */
