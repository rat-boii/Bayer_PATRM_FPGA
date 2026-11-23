/* Job execution shared by sw/patrm_app (JTAG mailbox) and sw/patrm_eth (Ethernet), see patrm_jobrun.h.
 * The code is the one of sw/patrm_app/main.c at step 4.4, moved here unchanged in step 10.2, except one point:
 * run_sw_frame flushes the source instead of invalidating it when the ARM wrote it (flag SRC_CPU, the Ethernet
 * application). Invalidating would throw away the ARM's cached writes. JTAG jobs never set SRC_CPU, so for them
 * nothing changes.
 */
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "patrm_jobrun.h"
#include "patrm_regs.h"
#include "patrm_sw.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xpseudo_asm.h"

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

void patrm_jobrun_header(const patrm_dev_t *dev, patrm_job_result_t *r, uint32_t seq, patrm_rc_t rc)
{
    memset(r, 0, sizeof(*r));
    r->magic = PATRM_RESULT_MAGIC;
    r->seq = seq;
    r->layout = PATRM_LAYOUT_VERSION;
    r->rc = (uint32_t)rc;
    r->timer_hz = patrm_timer_hz();
    r->build_id = dev->build_id;
    r->irq_count = dev->irq_count;
    r->irq_spurious = dev->irq_spurious;
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

void patrm_jobrun_print(const patrm_job_result_t *r)
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

static void print_irq_diagnosis(const patrm_dev_t *dev, uint32_t status)
{
    patrm_irq_state_t s = dev->irq_at_timeout;
    uint32_t ctrl = patrm_ctrl(dev);

    xil_printf("NO INTERRUPT: STATUS=0x%08x (DONE set), CTRL=0x%08x IRQ_EN=%u. GIC ID 61: enabled=%d pending=%d "
               "trigger=%u (1 = level) priority=0x%02x; handled so far=%u, spurious=%u\r\n",
               (unsigned int)status, (unsigned int)ctrl,
               (unsigned int)((ctrl & PATRM_CTRL_IRQ_EN_MASK) >> PATRM_CTRL_IRQ_EN_SHIFT),
               s.enabled ? 1 : 0, s.pending ? 1 : 0, (unsigned int)s.trigger, (unsigned int)s.priority,
               (unsigned int)dev->irq_count, (unsigned int)dev->irq_spurious);
}

/* Step 4.4: one frame with the ARM software baseline instead of the engine. Same job checks as the engine path.
 * Source: written by the PC over JTAG, past the caches -> invalidated first; written by the ARM (SRC_CPU, Ethernet)
 * -> flushed (clean + invalidate) so no cached write is lost. The output is flushed so the PC can read it.
 * engine_ticks = the warp alone, total_ticks = warp + cache work. The engine counters stay 0. */
static patrm_rc_t run_sw_frame(const patrm_dev_t *dev, const patrm_job_t *job, patrm_frame_t *frame)
{
    const uint32_t size = job->width * job->height;
    patrm_rc_t rc = patrm_validate(dev, job);
    uint64_t t_begin, t_start, t_done;

    memset(frame, 0, sizeof(*frame));
    if (rc != PATRM_RC_OK) {
        return rc;
    }
    if (job->mode != PATRM_MODE_GRAY) {
        return PATRM_RC_BAD_MODE;                  /* the software baseline is grayscale only */
    }
    t_begin = patrm_now();
    if (job->src_written_by_cpu) {
        Xil_DCacheFlushRange((INTPTR)job->src_addr, (INTPTR)size);
    } else {
        Xil_DCacheInvalidateRange((INTPTR)job->src_addr, (INTPTR)size);
    }
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

void patrm_jobrun(patrm_dev_t *dev, const patrm_job_desc_t *d, patrm_job_result_t *r)
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
            rc = sw ? run_sw_frame(dev, &job, &frame) : patrm_run(dev, &job, &frame);
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
        print_irq_diagnosis(dev, frame.status);
    }

    patrm_jobrun_header(dev, r, d->seq, rc);
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
