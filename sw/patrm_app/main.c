/* PATRM test application (step 4.2). Runs jobs that the PC writes over JTAG, without reloading the ELF.
 *
 * Start: writes a result record with seq = 0 ("ready"). Loop: wait for a job descriptor with a new sequence number at
 * 0x1F00_0000, run its frame N times, write the result record at 0x1F00_1000, print one "RESULT ..." line on the UART.
 * Layouts: patrm_job.h, spec/memory_map.md section 5. PC side: scripts/board/run_job.py.
 * The job itself runs in sw/patrm_job/patrm_jobrun.c (shared with the Ethernet application since step 10.2).
 *
 * The PC reads and writes DDR directly over JTAG, past the ARM caches, so the descriptor is invalidated before each
 * read and the result record is flushed after each write. Fields are published in an order that makes a half-written
 * record invisible: the PC writes the descriptor magic last, and this program writes the result seq last.
 */
#include <stdint.h>
#include <string.h>

#include "patrm_drv.h"
#include "patrm_job.h"
#include "patrm_jobrun.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xpseudo_asm.h"

#define POLL_DELAY_TICKS(hz)   ((uint64_t)(hz) / 1000U)     /* look for a new job every 1 ms */
#define CACHE_LINE             32U

/* Optimisation level of this build, set by sw/patrm_app/build_vitis.py (PATRM_APP_OPT); printed at start so the UART
 * log shows which software baseline (step 4.4) ran. */
#ifndef PATRM_APP_OPT_LEVEL
#define PATRM_APP_OPT_LEVEL 2
#endif

_Static_assert(PATRM_JOB_SIZE % CACHE_LINE == 0U, "descriptor must be whole cache lines");
_Static_assert(PATRM_RESULT_SIZE % CACHE_LINE == 0U, "result must be whole cache lines");

static patrm_dev_t dev;

static void wait_ticks(uint64_t ticks)
{
    uint64_t end = patrm_now() + ticks;
    while (patrm_now() < end) {
    }
}

static volatile patrm_job_desc_t *job_area(void)
{
    return (volatile patrm_job_desc_t *)(uintptr_t)PATRM_JOB_ADDR;
}

static volatile patrm_job_result_t *result_area(void)
{
    return (volatile patrm_job_result_t *)(uintptr_t)PATRM_RESULT_ADDR;
}

static void invalidate_job(void)
{
    Xil_DCacheInvalidateRange((INTPTR)PATRM_JOB_ADDR, (INTPTR)PATRM_JOB_SIZE);
    dsb();
}

/* Everything except seq first, then seq alone, each flushed to DDR, so the PC never sees a matching seq too early. */
static void publish(const patrm_job_result_t *r, uint32_t old_seq)
{
    volatile patrm_job_result_t *out = result_area();
    patrm_job_result_t body = *r;

    body.seq = old_seq;
    memcpy((void *)(uintptr_t)PATRM_RESULT_ADDR, &body, sizeof(body));
    Xil_DCacheFlushRange((INTPTR)PATRM_RESULT_ADDR, (INTPTR)PATRM_RESULT_SIZE);
    dsb();
    out->seq = r->seq;
    Xil_DCacheFlushRange((INTPTR)PATRM_RESULT_ADDR, (INTPTR)CACHE_LINE);
    dsb();
}

/* Blocks until a descriptor with a new sequence number is in DDR, then copies it. */
static void wait_for_job(patrm_job_desc_t *desc, uint32_t last_seq)
{
    volatile patrm_job_desc_t *area = job_area();
    uint64_t delay = POLL_DELAY_TICKS(patrm_timer_hz());

    for (;;) {
        invalidate_job();
        if ((area->magic == PATRM_JOB_MAGIC) && (area->seq != 0U) && (area->seq != last_seq)) {
            break;
        }
        wait_ticks(delay);
    }
    /* The other cache lines may have been fetched before the PC wrote them. */
    invalidate_job();
    memcpy(desc, (const void *)(uintptr_t)PATRM_JOB_ADDR, sizeof(*desc));
}

int main(void)
{
    patrm_job_desc_t desc;
    patrm_job_result_t result;
    volatile patrm_job_desc_t *area = job_area();
    uint32_t last_seq = 0U;
    patrm_rc_t rc;

    Xil_ICacheEnable();
    Xil_DCacheEnable();
    xil_printf("\r\nPATRM test application (step 4.2)\r\n");

    rc = patrm_init(&dev, PATRM_REG_BASE);
    if (rc == PATRM_RC_OK) {
        rc = patrm_irq_init(&dev);
    }
    xil_printf("BUILD_ID 0x%08x, init %s, global timer %u Hz\r\n",
               (unsigned int)dev.build_id, patrm_rc_name(rc), (unsigned int)patrm_timer_hz());
    xil_printf("software baseline built with -O%d\r\n", (int)PATRM_APP_OPT_LEVEL);

    /* A descriptor left in DDR by an earlier session must not run. */
    area->magic = 0U;
    Xil_DCacheFlushRange((INTPTR)PATRM_JOB_ADDR, (INTPTR)PATRM_JOB_SIZE);
    dsb();

    patrm_jobrun_header(&dev, &result, 0U, rc);
    publish(&result, 0U);
    if (rc != PATRM_RC_OK) {
        xil_printf("INIT FAILED: %s\r\n", patrm_rc_name(rc));
        for (;;) {
        }
    }
    xil_printf("READY\r\n");

    for (;;) {
        wait_for_job(&desc, last_seq);
        patrm_jobrun(&dev, &desc, &result);
        publish(&result, last_seq);
        last_seq = desc.seq;
        patrm_jobrun_print(&result);
    }
}
