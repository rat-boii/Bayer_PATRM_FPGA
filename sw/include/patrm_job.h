/* Job descriptor and result record exchanged between the PC (over JTAG) and the ARM test application (step 4.2).
 * Layout: spec/memory_map.md section 5. The PC side is model/job.py; model/test_job_layout.py compiles every offset,
 * size and constant below against the Python tables with the ARM compiler.
 * All fields are 32-bit little-endian. Both structures are whole cache lines (32 bytes).
 */
#ifndef PATRM_JOB_H
#define PATRM_JOB_H

#include <stddef.h>
#include <stdint.h>
#include "patrm_defs.h"

#define PATRM_JOB_ADDR        0x1F000000U
#define PATRM_RESULT_ADDR     0x1F001000U
#define PATRM_JOB_MAGIC       0x424F4A50U   /* "PJOB" in memory */
#define PATRM_RESULT_MAGIC    0x53455250U   /* "PRES" in memory */
#define PATRM_LAYOUT_VERSION  1U
#define PATRM_JOB_MAX_REPEAT  10000U
#define PATRM_JOB_MAX_TIMEOUT_MS 60000U

#define PATRM_JOB_FLAG_IRQ_EN   0x1U        /* wait for the interrupt; otherwise poll STATUS */
#define PATRM_JOB_FLAG_SRC_CPU  0x2U        /* the ARM wrote the source: flush it before START */

typedef struct {
    uint32_t magic;                         /* written last by the PC */
    uint32_t seq;                           /* non-zero, changes for every job */
    uint32_t layout;
    uint32_t mode;
    uint32_t flags;
    uint32_t width;
    uint32_t height;
    uint32_t block_len;
    uint32_t src_addr;
    uint32_t dst_addr;
    uint32_t repeat;                        /* N: frames to run */
    uint32_t timeout_ms;                    /* per frame */
    int32_t  b[6];                          /* b11 b12 b13 b21 b22 b23, Q15.16 */
    uint32_t reserved[6];
} patrm_job_desc_t;

typedef struct {
    uint32_t magic;
    uint32_t seq;                           /* seq of the job; 0 = application ready, no job yet. Written last */
    uint32_t layout;
    uint32_t rc;                            /* patrm_rc_t */
    uint32_t status;                        /* STATUS at the end of the last frame, before it was cleared */
    uint32_t runs;                          /* frames completed without error */
    uint32_t flags;                         /* flags of the job */
    uint32_t cycles;                        /* counters of the last frame */
    uint32_t bytes_rd;
    uint32_t bytes_wr;
    uint32_t rd_stall;
    uint32_t wr_stall;
    uint32_t cycles_min;                    /* CYCLES over the completed frames */
    uint32_t cycles_avg;
    uint32_t cycles_max;
    uint32_t engine_ns_min;                 /* START to DONE, global timer, nanoseconds */
    uint32_t engine_ns_avg;
    uint32_t engine_ns_max;
    uint32_t total_ns_min;                  /* end to end: before the cache work to output ready for the ARM */
    uint32_t total_ns_avg;
    uint32_t total_ns_max;
    uint32_t timer_hz;                      /* global timer frequency */
    uint32_t build_id;
    uint32_t irq_count;                     /* interrupts handled since the application started */
    uint32_t irq_spurious;                  /* of those, with DONE not set */
    uint32_t reserved[7];
} patrm_job_result_t;

#define PATRM_JOB_SIZE     96U
#define PATRM_RESULT_SIZE  128U

_Static_assert(sizeof(patrm_job_desc_t) == PATRM_JOB_SIZE, "job descriptor size");
_Static_assert(sizeof(patrm_job_result_t) == PATRM_RESULT_SIZE, "result record size");
_Static_assert(PATRM_JOB_SIZE % 32U == 0U, "job descriptor must be whole cache lines");
_Static_assert(PATRM_RESULT_SIZE % 32U == 0U, "result record must be whole cache lines");
_Static_assert(offsetof(patrm_job_desc_t, magic) == 0U, "job magic");
_Static_assert(offsetof(patrm_job_desc_t, seq) == 4U, "job seq");
_Static_assert(offsetof(patrm_job_desc_t, repeat) == 40U, "job repeat");
_Static_assert(offsetof(patrm_job_desc_t, b) == 48U, "job b");
_Static_assert(offsetof(patrm_job_result_t, magic) == 0U, "result magic");
_Static_assert(offsetof(patrm_job_result_t, seq) == 4U, "result seq");
_Static_assert(offsetof(patrm_job_result_t, rc) == 12U, "result rc");
_Static_assert(offsetof(patrm_job_result_t, cycles) == 28U, "result cycles");
_Static_assert(offsetof(patrm_job_result_t, engine_ns_min) == 60U, "result engine time");
_Static_assert(offsetof(patrm_job_result_t, timer_hz) == 84U, "result timer_hz");

#endif /* PATRM_JOB_H */
