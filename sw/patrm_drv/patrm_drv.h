/* Bare-metal driver for the PATRM engine (step 4.2). Sequence: spec/memory_map.md section 4.
 * Registers come from patrm_regs.h only. The D-cache stays on; the driver does the cache work for the image buffers.
 */
#ifndef PATRM_DRV_H
#define PATRM_DRV_H

#include <stdbool.h>
#include <stdint.h>
#include "patrm_defs.h"

/* One frame. b[] are the quantised Q15.16 integers from the PC; the ARM does no floating-point transform maths. */
typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t mode;                 /* PATRM_MODE_* */
    uint32_t block_len;
    uint32_t src_addr;
    uint32_t dst_addr;
    int32_t  b[6];                 /* b11 b12 b13 b21 b22 b23 */
    uint32_t timeout_ms;
    bool     use_irq;              /* wait for the interrupt, otherwise poll STATUS */
    bool     src_written_by_cpu;   /* flush the source range before START */
} patrm_job_t;

typedef struct {
    uint32_t status;               /* STATUS when the frame ended, before it was cleared */
    uint32_t cycles;
    uint32_t bytes_rd;
    uint32_t bytes_wr;
    uint32_t rd_stall;
    uint32_t wr_stall;
    uint64_t engine_ticks;         /* START to DONE */
    uint64_t total_ticks;          /* start of patrm_run to output ready for the ARM */
} patrm_frame_t;

/* State of GIC ID 61, for diagnosing a missing interrupt. */
typedef struct {
    bool     enabled;
    bool     pending;
    uint32_t trigger;              /* 2-bit field of ICDICFR: 1 = active-high level */
    uint32_t priority;
} patrm_irq_state_t;

typedef struct {
    uint32_t base;
    uint32_t build_id;
    uint32_t modes;                /* BUILD_ID.MODES */
    uint32_t block_len_max;        /* BUILD_ID.BLOCK_LEN_MAX */
    bool     irq_ready;
    patrm_irq_state_t irq_at_timeout;  /* taken while DONE was still set, for PATRM_RC_NO_INTERRUPT */
    /* written by the interrupt handler */
    volatile bool     irq_done;
    volatile uint32_t irq_status;
    volatile uint64_t irq_time;
    volatile uint32_t irq_count;
    volatile uint32_t irq_spurious;
} patrm_dev_t;

/* Starts the global timer if needed, reads and checks BUILD_ID. */
patrm_rc_t patrm_init(patrm_dev_t *dev, uint32_t base);

/* Sets up the GIC for IRQ_F2P[0] (ID 61, active-high level) and enables ARM interrupts. */
patrm_rc_t patrm_irq_init(patrm_dev_t *dev);

/* The checks of model/job.py: size D3 + D11, mode, BLOCK_LEN D13, buffers, transform D4. */
patrm_rc_t patrm_validate(const patrm_dev_t *dev, const patrm_job_t *job);

/* Check, program, start, wait, cache work, read the counters and leave STATUS clear. */
patrm_rc_t patrm_run(patrm_dev_t *dev, const patrm_job_t *job, patrm_frame_t *frame);

uint32_t patrm_status(const patrm_dev_t *dev);
uint32_t patrm_ctrl(const patrm_dev_t *dev);
void patrm_irq_state(patrm_irq_state_t *state);

uint64_t patrm_now(void);                     /* global timer ticks */
uint32_t patrm_timer_hz(void);
uint32_t patrm_ticks_to_ns(uint64_t ticks);   /* saturates at 0xFFFFFFFF */

const char *patrm_rc_name(patrm_rc_t rc);
const char *patrm_err_name(uint32_t err_code);

#endif /* PATRM_DRV_H */
