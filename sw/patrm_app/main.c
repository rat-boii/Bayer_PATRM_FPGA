/* PATRM test application (step 4.2). Runs jobs that the PC writes over JTAG, without reloading the ELF.
 *
 * Start: writes a result record with seq = 0 ("ready"). Loop: wait for a job descriptor with a new sequence number at
 * 0x1F00_0000, run its frame N times, write the result record at 0x1F00_1000, print one "RESULT ..." line on the UART.
 * Layouts: patrm_job.h, spec/memory_map.md section 5. PC side: scripts/board/run_job.py.
 *
 * The PC reads and writes DDR directly over JTAG, past the ARM caches, so the descriptor is invalidated before each
 * read and the result record is flushed after each write. Fields are published in an order that makes a half-written
 * record invisible: the PC writes the descriptor magic last, and this program writes the result seq last.
 */
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "patrm_drv.h"
#include "patrm_job.h"
#include "patrm_regs.h"
#include "patrm_sw.h"
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

typedef struct {
    uint32_t min;
    uint32_t max;
    uint64_t sum;
} stat_t;

static void stat_reset(stat_t *s)
{
    s->min = 0xFFFFFFFFU;
    s->max = 0U;
    s->sum = 0U;
}

static void stat_add(stat_t *s, uint32_t value)
{
    s->min = (value < s->min) ? value : s->min;
    s->max = (value > s->max) ? value : s->max;
    s->sum += value;
}

static uint32_t stat_avg(const stat_t *s, uint32_t n)
{
    return (n == 0U) ? 0U : (uint32_t)(s->sum / n);
}

static uint32_t stat_min(const stat_t *s, uint32_t n)
{
    return (n == 0U) ? 0U : s->min;
}

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

static void result_header(patrm_job_result_t *r, uint32_t seq, patrm_rc_t rc)
{
    memset(r, 0, sizeof(*r));
    r->magic = PATRM_RESULT_MAGIC;
    r->seq = seq;
    r->layout = PATRM_LAYOUT_VERSION;
    r->rc = (uint32_t)rc;
    r->timer_hz = patrm_timer_hz();
    r->build_id = dev.build_id;
    r->irq_count = dev.irq_count;
    r->irq_spurious = dev.irq_spurious;
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

static patrm_rc_t job_from_desc(const patrm_job_desc_t *d, patrm_job_t *job)
{
    uint32_t i;

    if (d->layout != PATRM_LAYOUT_VERSION) {
        return PATRM_RC_BAD_LAYOUT;
    }
    if ((d->repeat == 0U) || (d->repeat > PATRM_JOB_MAX_REPEAT) ||
        (d->timeout_ms == 0U) || (d->timeout_ms > PATRM_JOB_MAX_TIMEOUT_MS) ||
        ((d->flags & ~PATRM_JOB_FLAGS_KNOWN) != 0U)) {
        return PATRM_RC_BAD_JOB;
    }
    job->width = d->width;
    job->height = d->height;
    job->mode = d->mode;
    job->block_len = d->block_len;
    job->src_addr = d->src_addr;
    job->dst_addr = d->dst_addr;
    for (i = 0U; i < 6U; i++) {
        job->b[i] = d->b[i];
    }
    job->timeout_ms = d->timeout_ms;
    job->use_irq = (d->flags & PATRM_JOB_FLAG_IRQ_EN) != 0U;
    job->src_written_by_cpu = (d->flags & PATRM_JOB_FLAG_SRC_CPU) != 0U;
    return PATRM_RC_OK;
}

/* xil_printf in the 2026.1 standalone BSP is built with SUPPORT_64BIT_PRINT: on the Cortex-A9 a single 'l' (%lu, %lx)
 * reads a 64-bit argument. Every value printed here is 32 bits, so the formats are %u / %x / %d with unsigned int
 * arguments; a stray 'l' shifts all following arguments (it made %s read a garbage pointer: data abort in strlen). */
static void print_ns(const char *name, uint32_t min, uint32_t avg, uint32_t max)
{
    xil_printf(" %s=%u.%03u/%u.%03u/%u.%03u", name,
               (unsigned int)(min / 1000U), (unsigned int)(min % 1000U),
               (unsigned int)(avg / 1000U), (unsigned int)(avg % 1000U),
               (unsigned int)(max / 1000U), (unsigned int)(max % 1000U));
}

static void print_result(const patrm_job_result_t *r)
{
    uint32_t code = (r->status & PATRM_STATUS_ERR_CODE_MASK) >> PATRM_STATUS_ERR_CODE_SHIFT;

    xil_printf("RESULT seq=%u rc=%s status=0x%08x err=%s runs=%u cycles=%u bytes_rd=%u bytes_wr=%u "
               "rd_stall=%u wr_stall=%u",
               (unsigned int)r->seq, patrm_rc_name((patrm_rc_t)r->rc), (unsigned int)r->status,
               patrm_err_name(code), (unsigned int)r->runs, (unsigned int)r->cycles,
               (unsigned int)r->bytes_rd, (unsigned int)r->bytes_wr,
               (unsigned int)r->rd_stall, (unsigned int)r->wr_stall);
    print_ns("engine_us", r->engine_ns_min, r->engine_ns_avg, r->engine_ns_max);
    print_ns("total_us", r->total_ns_min, r->total_ns_avg, r->total_ns_max);
    xil_printf("\r\n");
}

static void print_irq_diagnosis(uint32_t status)
{
    patrm_irq_state_t s = dev.irq_at_timeout;
    uint32_t ctrl = patrm_ctrl(&dev);

    xil_printf("NO INTERRUPT: STATUS=0x%08x (DONE set), CTRL=0x%08x IRQ_EN=%u. GIC ID 61: enabled=%d pending=%d "
               "trigger=%u (1 = level) priority=0x%02x; handled so far=%u, spurious=%u\r\n",
               (unsigned int)status, (unsigned int)ctrl,
               (unsigned int)((ctrl & PATRM_CTRL_IRQ_EN_MASK) >> PATRM_CTRL_IRQ_EN_SHIFT),
               s.enabled ? 1 : 0, s.pending ? 1 : 0, (unsigned int)s.trigger, (unsigned int)s.priority,
               (unsigned int)dev.irq_count, (unsigned int)dev.irq_spurious);
}

/* Step 4.4: one frame with the ARM software baseline instead of the engine. Same job checks as the engine path.
 * The PC wrote the source over JTAG, past the caches, so the source range is invalidated first; the output is flushed
 * so the PC can read it. engine_ticks = the warp alone, total_ticks = warp + cache work. The engine counters stay 0. */
static patrm_rc_t run_sw_frame(const patrm_job_t *job, patrm_frame_t *frame)
{
    const uint32_t size = job->width * job->height;
    patrm_rc_t rc = patrm_validate(&dev, job);
    uint64_t t_begin, t_start, t_done;

    memset(frame, 0, sizeof(*frame));
    if (rc != PATRM_RC_OK) {
        return rc;
    }
    if (job->mode != PATRM_MODE_GRAY) {
        return PATRM_RC_BAD_MODE;                  /* the software baseline is grayscale only */
    }
    t_begin = patrm_now();
    Xil_DCacheInvalidateRange((INTPTR)job->src_addr, (INTPTR)size);
    t_start = patrm_now();
    if (patrm_sw_gray((const uint8_t *)(uintptr_t)job->src_addr, (uint8_t *)(uintptr_t)job->dst_addr,
                      job->width, job->height, job->b) != PATRM_SW_OK) {
        return PATRM_RC_BAD_SIZE;
    }
    t_done = patrm_now();
    Xil_DCacheFlushRange((INTPTR)job->dst_addr, (INTPTR)size);
    dsb();
    frame->engine_ticks = t_done - t_start;
    frame->total_ticks = patrm_now() - t_begin;
    return PATRM_RC_OK;
}

static void run_job(const patrm_job_desc_t *d, patrm_job_result_t *r)
{
    patrm_job_t job;
    patrm_frame_t frame;
    stat_t cycles, engine, total;
    patrm_rc_t rc = job_from_desc(d, &job);
    const bool sw = (d->flags & PATRM_JOB_FLAG_SW) != 0U;
    uint32_t i;
    uint32_t runs = 0U;

    memset(&frame, 0, sizeof(frame));
    stat_reset(&cycles);
    stat_reset(&engine);
    stat_reset(&total);
    if (rc == PATRM_RC_OK) {
        for (i = 0U; i < d->repeat; i++) {
            rc = sw ? run_sw_frame(&job, &frame) : patrm_run(&dev, &job, &frame);
            if (rc != PATRM_RC_OK) {
                break;
            }
            runs++;
            stat_add(&cycles, frame.cycles);
            stat_add(&engine, patrm_ticks_to_ns(frame.engine_ticks));
            stat_add(&total, patrm_ticks_to_ns(frame.total_ticks));
        }
    }
    if (rc == PATRM_RC_NO_INTERRUPT) {
        print_irq_diagnosis(frame.status);
    }

    result_header(r, d->seq, rc);
    r->status = frame.status;
    r->runs = runs;
    r->flags = d->flags;
    r->cycles = frame.cycles;
    r->bytes_rd = frame.bytes_rd;
    r->bytes_wr = frame.bytes_wr;
    r->rd_stall = frame.rd_stall;
    r->wr_stall = frame.wr_stall;
    r->cycles_min = stat_min(&cycles, runs);
    r->cycles_avg = stat_avg(&cycles, runs);
    r->cycles_max = cycles.max;
    r->engine_ns_min = stat_min(&engine, runs);
    r->engine_ns_avg = stat_avg(&engine, runs);
    r->engine_ns_max = engine.max;
    r->total_ns_min = stat_min(&total, runs);
    r->total_ns_avg = stat_avg(&total, runs);
    r->total_ns_max = total.max;
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

    result_header(&result, 0U, rc);
    publish(&result, 0U);
    if (rc != PATRM_RC_OK) {
        xil_printf("INIT FAILED: %s\r\n", patrm_rc_name(rc));
        for (;;) {
        }
    }
    xil_printf("READY\r\n");

    for (;;) {
        wait_for_job(&desc, last_seq);
        run_job(&desc, &result);
        publish(&result, last_seq);
        last_seq = desc.seq;
        print_result(&result);
    }
}
