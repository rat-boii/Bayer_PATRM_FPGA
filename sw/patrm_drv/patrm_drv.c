/* Bare-metal driver for the PATRM engine (step 4.2). See patrm_drv.h and spec/memory_map.md section 4. */
#include "patrm_drv.h"

#include "patrm_regs.h"
#include "xil_cache.h"
#include "xil_exception.h"
#include "xil_io.h"
#include "xiltimer.h"
#include "xparameters.h"
#include "xpseudo_asm.h"
#include "xscugic.h"
#include "xstatus.h"

#define PATRM_IRQ_ID        61U     /* IRQ_F2P[0] = GIC shared peripheral interrupt 61 */
#define PATRM_IRQ_PRIORITY  0xA0U   /* the GIC uses the upper 5 bits */

/* XScuGic_SetPriorityTriggerType value: 0b01 = active-high level, 0b11 = rising edge. The engine holds its interrupt
 * high until DONE is cleared, so it must be level: an edge would be lost if it arrived while interrupts were masked,
 * and a level is simply taken as soon as they are unmasked. */
#define PATRM_IRQ_TRIGGER_LEVEL_HIGH  0x1U

#define GTIMER_CONTROL      0xF8F00208U  /* Cortex-A9 global timer control register */
#define GTIMER_ENABLE       0x1U
#define TIMER_HZ            ((uint64_t)(COUNTS_PER_SECOND))   /* the BSP macro has no parentheses */
#define TIMER_START_SPINS   1000U

#define STATUS_DONE_ERROR   (PATRM_STATUS_DONE_MASK | PATRM_STATUS_ERROR_MASK)
#define Q16_ONE             65536

static XScuGic gic;

static uint32_t reg_read(const patrm_dev_t *dev, uint32_t offset)
{
    return Xil_In32(dev->base + offset);
}

static void reg_write(const patrm_dev_t *dev, uint32_t offset, uint32_t value)
{
    Xil_Out32(dev->base + offset, value);
}

static uint32_t field(uint32_t value, uint32_t mask, uint32_t shift)
{
    return (value & mask) >> shift;
}

uint64_t patrm_now(void)
{
    XTime t;
    XTime_GetTime(&t);
    return (uint64_t)t;
}

uint32_t patrm_timer_hz(void)
{
    return (uint32_t)TIMER_HZ;
}

uint32_t patrm_ticks_to_ns(uint64_t ticks)
{
    /* whole seconds first, so the product cannot overflow 64 bits */
    uint64_t ns = ((ticks / TIMER_HZ) * 1000000000ULL) + (((ticks % TIMER_HZ) * 1000000000ULL) / TIMER_HZ);
    return (ns > 0xFFFFFFFFULL) ? 0xFFFFFFFFU : (uint32_t)ns;
}

uint32_t patrm_status(const patrm_dev_t *dev)
{
    return reg_read(dev, PATRM_STATUS_OFFSET);
}

uint32_t patrm_ctrl(const patrm_dev_t *dev)
{
    return reg_read(dev, PATRM_CTRL_OFFSET);
}

/* The BSP does not start the global timer on its own: XTime_GetTime only reads it. */
static bool timer_start(void)
{
    uint64_t t0;
    uint32_t i;

    if ((Xil_In32(GTIMER_CONTROL) & GTIMER_ENABLE) == 0U) {
        Xil_Out32(GTIMER_CONTROL, Xil_In32(GTIMER_CONTROL) | GTIMER_ENABLE);
    }
    t0 = patrm_now();
    for (i = 0U; i < TIMER_START_SPINS; i++) {
        if (patrm_now() != t0) {
            return true;
        }
    }
    return false;
}

patrm_rc_t patrm_init(patrm_dev_t *dev, uint32_t base)
{
    dev->base = base;
    dev->irq_ready = false;
    dev->irq_done = false;
    dev->irq_status = 0U;
    dev->irq_time = 0U;
    dev->irq_count = 0U;
    dev->irq_spurious = 0U;
    if (!timer_start()) {
        return PATRM_RC_NO_TIMER;
    }
    dev->build_id = reg_read(dev, PATRM_BUILD_ID_OFFSET);
    dev->modes = field(dev->build_id, PATRM_BUILD_ID_MODES_MASK, PATRM_BUILD_ID_MODES_SHIFT);
    dev->block_len_max = field(dev->build_id, PATRM_BUILD_ID_BLOCK_LEN_MAX_MASK, PATRM_BUILD_ID_BLOCK_LEN_MAX_SHIFT);
    if (field(dev->build_id, PATRM_BUILD_ID_VERSION_MASK, PATRM_BUILD_ID_VERSION_SHIFT) != PATRM_VERSION) {
        return PATRM_RC_BAD_BUILD_ID;
    }
    return PATRM_RC_OK;
}

/* Level interrupt: DONE must be cleared here, or the line stays high and the handler runs again at once. */
static void patrm_isr(void *ref)
{
    patrm_dev_t *dev = (patrm_dev_t *)ref;
    uint64_t now = patrm_now();
    uint32_t status = patrm_status(dev);

    dev->irq_count = dev->irq_count + 1U;
    if ((status & PATRM_STATUS_DONE_MASK) == 0U) {
        dev->irq_spurious = dev->irq_spurious + 1U;
        return;
    }
    reg_write(dev, PATRM_STATUS_OFFSET, status & STATUS_DONE_ERROR);
    (void)patrm_status(dev);     /* the read returns after the write took effect, so the line is low before EOI */
    dsb();
    dev->irq_status = status;
    dev->irq_time = now;
    dev->irq_done = true;
}

patrm_rc_t patrm_irq_init(patrm_dev_t *dev)
{
    XScuGic_Config *cfg = XScuGic_LookupConfig(XPAR_XSCUGIC_0_BASEADDR);

    if (cfg == NULL) {
        return PATRM_RC_IRQ_SETUP;
    }
    if (XScuGic_CfgInitialize(&gic, cfg, cfg->CpuBaseAddress) != XST_SUCCESS) {
        return PATRM_RC_IRQ_SETUP;
    }
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_IRQ_INT, (Xil_ExceptionHandler)XScuGic_InterruptHandler, &gic);
    XScuGic_SetPriorityTriggerType(&gic, PATRM_IRQ_ID, PATRM_IRQ_PRIORITY, PATRM_IRQ_TRIGGER_LEVEL_HIGH);
    if (XScuGic_Connect(&gic, PATRM_IRQ_ID, patrm_isr, dev) != XST_SUCCESS) {
        return PATRM_RC_IRQ_SETUP;
    }
    XScuGic_Enable(&gic, PATRM_IRQ_ID);
    Xil_ExceptionEnable();
    dev->irq_ready = true;
    return PATRM_RC_OK;
}

void patrm_irq_state(patrm_irq_state_t *state)
{
    uint32_t bit = 1UL << (PATRM_IRQ_ID % 32U);
    uint32_t cfg_shift = (PATRM_IRQ_ID % 16U) * 2U;
    uint32_t prio_shift = (PATRM_IRQ_ID % 4U) * 8U;

    state->enabled = (XScuGic_DistReadReg(&gic, XSCUGIC_EN_DIS_OFFSET_CALC(XSCUGIC_ENABLE_SET_OFFSET, PATRM_IRQ_ID)) & bit) != 0U;
    state->pending = (XScuGic_DistReadReg(&gic, XSCUGIC_EN_DIS_OFFSET_CALC(XSCUGIC_PENDING_SET_OFFSET, PATRM_IRQ_ID)) & bit) != 0U;
    state->trigger = (XScuGic_DistReadReg(&gic, XSCUGIC_INT_CFG_OFFSET_CALC(PATRM_IRQ_ID)) >> cfg_shift) & 0x3U;
    state->priority = (XScuGic_DistReadReg(&gic, XSCUGIC_PRIORITY_OFFSET_CALC(PATRM_IRQ_ID)) >> prio_shift) & 0xFFU;
}

static patrm_rc_t check_size(const patrm_job_t *job)
{
    uint32_t w = job->width;
    uint32_t h = job->height;

    if ((w == 0U) || (h == 0U) || (w > PATRM_MAX_SIZE) || (h > PATRM_MAX_SIZE)) {
        return PATRM_RC_BAD_SIZE;                                  /* D11 */
    }
    if (job->mode == PATRM_MODE_GRAY) {
        return ((w % PATRM_GRAY_W_MULT) == 0U) ? PATRM_RC_OK : PATRM_RC_BAD_SIZE;         /* D3 */
    }
    if (((w % PATRM_BAYER_W_MULT) != 0U) || ((h % PATRM_BAYER_H_MULT) != 0U)) {
        return PATRM_RC_BAD_SIZE;                                  /* D3 */
    }
    return PATRM_RC_OK;
}

static bool buffer_ok(uint32_t addr, uint32_t size)
{
    return ((addr % PATRM_ADDR_ALIGN) == 0U) && (addr >= PATRM_BUF_LO) && (addr < PATRM_BUF_HI) &&
           (size <= (PATRM_BUF_HI - addr));
}

/* D2/D12: use 64-bit intermediates, then floor division by two, including negative odd sums.
 * C division truncates toward zero; do not use it alone or a signed implementation-defined shift. */
static bool plane_shifts(const patrm_job_t *job, int32_t t[8])
{
    unsigned p;
    for (p = 0U; p < 4U; p++) {
        int64_t row = (int64_t)(p >> 1);
        int64_t col = (int64_t)(p & 1U);
        int64_t x = (int64_t)job->b[2] + ((int64_t)job->b[0] - Q16_ONE) * row + (int64_t)job->b[1] * col;
        int64_t y = (int64_t)job->b[5] + (int64_t)job->b[3] * row + ((int64_t)job->b[4] - Q16_ONE) * col;
        x = (x >= 0) ? x / 2 : -((-x + 1) / 2);
        y = (y >= 0) ? y / 2 : -((-y + 1) / 2);
        if ((x < INT32_MIN) || (x > INT32_MAX) || (y < INT32_MIN) || (y > INT32_MAX)) {
            return false;
        }
        t[2U * p] = (int32_t)x;
        t[2U * p + 1U] = (int32_t)y;
    }
    return true;
}

static bool corners_ok(const patrm_job_t *job, uint32_t w, uint32_t h, int32_t tx, int32_t ty)
{
    const int64_t limit = (int64_t)PATRM_COORD_LIMIT_PX * Q16_ONE;
    unsigned corner;
    for (corner = 0U; corner < 4U; corner++) {
        int64_t u = ((corner & 1U) != 0U) ? (int64_t)h - 1 : 0;
        int64_t v = ((corner & 2U) != 0U) ? (int64_t)w - 1 : 0;
        int64_t x = (job->b[0] * u) + (job->b[1] * v) + tx;
        int64_t y = (job->b[3] * u) + (job->b[4] * v) + ty;
        if ((x > limit) || (x < -limit) || (y > limit) || (y < -limit)) {
            return false;
        }
    }
    return true;
}

/* D4: full-resolution corners and, in Bayer mode, every independent plane (model/bayer.py). */
static bool transform_ok(const patrm_job_t *job)
{
    int32_t t[8];
    unsigned p;
    if (!corners_ok(job, job->width, job->height, job->b[2], job->b[5])) {
        return false;
    }
    if (job->mode == PATRM_MODE_GRAY) {
        return true;
    }
    if (!plane_shifts(job, t)) {
        return false;
    }
    for (p = 0U; p < 4U; p++) {
        if (!corners_ok(job, job->width / 2U, job->height / 2U, t[2U * p], t[2U * p + 1U])) {
            return false;
        }
    }
    return true;
}

patrm_rc_t patrm_validate(const patrm_dev_t *dev, const patrm_job_t *job)
{
    uint32_t size;
    patrm_rc_t rc;

    if ((job->mode > PATRM_MODE_BAYER_B) || (((dev->modes >> job->mode) & 1U) == 0U)) {
        return PATRM_RC_BAD_MODE;
    }
    rc = check_size(job);
    if (rc != PATRM_RC_OK) {
        return rc;
    }
    if (!transform_ok(job)) {
        return PATRM_RC_BAD_TRANSFORM;
    }
    if ((job->block_len == 0U) || (job->block_len > dev->block_len_max)) {
        return PATRM_RC_BAD_BLOCK_LEN;
    }
    size = job->width * job->height;
    if (!buffer_ok(job->src_addr, size) || !buffer_ok(job->dst_addr, size)) {
        return PATRM_RC_BAD_ADDR;
    }
    if ((job->src_addr < (job->dst_addr + size)) && (job->dst_addr < (job->src_addr + size))) {
        return PATRM_RC_BAD_ADDR;
    }
    return PATRM_RC_OK;
}

static void program(const patrm_dev_t *dev, const patrm_job_t *job)
{
    static const uint32_t t_regs[] = {
        PATRM_T_R_X_OFFSET, PATRM_T_R_Y_OFFSET, PATRM_T_GR_X_OFFSET, PATRM_T_GR_Y_OFFSET,
        PATRM_T_GB_X_OFFSET, PATRM_T_GB_Y_OFFSET, PATRM_T_B_X_OFFSET, PATRM_T_B_Y_OFFSET
    };
    uint32_t i;
    int32_t t[8] = {0};
    if (job->mode != PATRM_MODE_GRAY) {   /* Option A and B (step 6.4): T_p per D2/D12; B lane offsets = T_p - T_R (D6) */
        (void)plane_shifts(job, t);       /* patrm_validate checked all eight values before any write */
    }

    reg_write(dev, PATRM_SRC_ADDR_OFFSET, job->src_addr);
    reg_write(dev, PATRM_DST_ADDR_OFFSET, job->dst_addr);
    reg_write(dev, PATRM_WIDTH_OFFSET, job->width);
    reg_write(dev, PATRM_HEIGHT_OFFSET, job->height);
    reg_write(dev, PATRM_B11_OFFSET, (uint32_t)job->b[0]);
    reg_write(dev, PATRM_B12_OFFSET, (uint32_t)job->b[1]);
    reg_write(dev, PATRM_B13_OFFSET, (uint32_t)job->b[2]);
    reg_write(dev, PATRM_B21_OFFSET, (uint32_t)job->b[3]);
    reg_write(dev, PATRM_B22_OFFSET, (uint32_t)job->b[4]);
    reg_write(dev, PATRM_B23_OFFSET, (uint32_t)job->b[5]);
    for (i = 0U; i < (sizeof(t_regs) / sizeof(t_regs[0])); i++) {
        reg_write(dev, t_regs[i], (uint32_t)t[i]);                  /* D2/D12; gray remains zero */
    }
    reg_write(dev, PATRM_BLOCK_LEN_OFFSET, job->block_len);
}

static void read_counters(const patrm_dev_t *dev, patrm_frame_t *frame)
{
    frame->cycles = reg_read(dev, PATRM_CYCLES_OFFSET);
    frame->bytes_rd = reg_read(dev, PATRM_BYTES_RD_OFFSET);
    frame->bytes_wr = reg_read(dev, PATRM_BYTES_WR_OFFSET);
    frame->rd_stall = reg_read(dev, PATRM_RD_STALL_OFFSET);
    frame->wr_stall = reg_read(dev, PATRM_WR_STALL_OFFSET);
}

/* Waits for the end of the frame. On success frame->status holds STATUS at DONE and DONE / ERROR are cleared. */
static patrm_rc_t wait_done(patrm_dev_t *dev, const patrm_job_t *job, patrm_frame_t *frame, uint64_t *t_done)
{
    uint64_t deadline = patrm_now() + (((uint64_t)job->timeout_ms * TIMER_HZ) / 1000U);

    for (;;) {
        if (job->use_irq) {
            if (dev->irq_done) {
                frame->status = dev->irq_status;
                *t_done = dev->irq_time;
                return PATRM_RC_OK;
            }
        } else {
            uint32_t status = patrm_status(dev);
            if ((status & PATRM_STATUS_DONE_MASK) != 0U) {
                *t_done = patrm_now();
                reg_write(dev, PATRM_STATUS_OFFSET, status & STATUS_DONE_ERROR);
                frame->status = status;
                return PATRM_RC_OK;
            }
        }
        if (patrm_now() > deadline) {
            uint32_t status = patrm_status(dev);
            if (job->use_irq && dev->irq_done) {
                continue;                  /* the handler ran just now and has already cleared DONE */
            }
            frame->status = status;
            if ((status & PATRM_STATUS_DONE_MASK) != 0U) {
                /* interrupt mode only: the frame ended but the handler never ran. Look at the GIC before the
                 * W1C below drops the line, so that "pending" still says whether the interrupt reached it. */
                patrm_irq_state(&dev->irq_at_timeout);
                reg_write(dev, PATRM_STATUS_OFFSET, status & STATUS_DONE_ERROR);
                return PATRM_RC_NO_INTERRUPT;
            }
            return PATRM_RC_TIMEOUT;
        }
    }
}

patrm_rc_t patrm_run(patrm_dev_t *dev, const patrm_job_t *job, patrm_frame_t *frame)
{
    uint32_t size = job->width * job->height;
    uint32_t ctrl;
    uint32_t status;
    uint64_t t_begin = patrm_now();
    uint64_t t_start;
    uint64_t t_done = 0U;
    patrm_rc_t rc;

    frame->status = 0U;
    frame->cycles = 0U;
    frame->bytes_rd = 0U;
    frame->bytes_wr = 0U;
    frame->rd_stall = 0U;
    frame->wr_stall = 0U;
    frame->engine_ticks = 0U;
    frame->total_ticks = 0U;

    rc = patrm_validate(dev, job);
    if (rc != PATRM_RC_OK) {
        return rc;
    }
    if (job->use_irq && !dev->irq_ready) {
        return PATRM_RC_IRQ_SETUP;
    }
    status = patrm_status(dev);
    if ((status & PATRM_STATUS_BUSY_MASK) != 0U) {
        frame->status = status;
        return PATRM_RC_BUSY;
    }

    /* The HP ports do not snoop the ARM caches. */
    if (job->src_written_by_cpu) {
        Xil_DCacheFlushRange((INTPTR)job->src_addr, (INTPTR)size);
    }
    /* Clean and invalidate, so that no dirty line can later be evicted on top of the engine's output. */
    Xil_DCacheFlushRange((INTPTR)job->dst_addr, (INTPTR)size);

    reg_write(dev, PATRM_STATUS_OFFSET, STATUS_DONE_ERROR);
    program(dev, job);

    ctrl = PATRM_CTRL_START_MASK | (job->mode << PATRM_CTRL_MODE_SHIFT);
    if (job->use_irq) {
        ctrl |= PATRM_CTRL_IRQ_EN_MASK;
    }
    dev->irq_done = false;
    dsb();
    t_start = patrm_now();
    reg_write(dev, PATRM_CTRL_OFFSET, ctrl);       /* last configuration write */

    status = patrm_status(dev);                    /* the outcome of the start checks is already visible */
    if (((status & PATRM_STATUS_ERROR_MASK) != 0U) && ((status & PATRM_STATUS_DONE_MASK) == 0U)) {
        frame->status = status;
        reg_write(dev, PATRM_STATUS_OFFSET, PATRM_STATUS_ERROR_MASK);
        return PATRM_RC_START_REJECTED;
    }

    rc = wait_done(dev, job, frame, &t_done);
    read_counters(dev, frame);
    if (rc != PATRM_RC_OK) {
        return rc;
    }

    /* Drop any stale copy of the output before the ARM can read it. */
    Xil_DCacheInvalidateRange((INTPTR)job->dst_addr, (INTPTR)size);
    frame->engine_ticks = t_done - t_start;
    frame->total_ticks = patrm_now() - t_begin;

    if ((frame->status & PATRM_STATUS_ERROR_MASK) != 0U) {
        uint32_t code = field(frame->status, PATRM_STATUS_ERR_CODE_MASK, PATRM_STATUS_ERR_CODE_SHIFT);
        return (code == PATRM_ERR_BUS_ERROR) ? PATRM_RC_BUS_ERROR : PATRM_RC_ENGINE_ERROR;
    }
    return PATRM_RC_OK;
}

const char *patrm_rc_name(patrm_rc_t rc)
{
    switch (rc) {
    case PATRM_RC_OK:             return "OK";
    case PATRM_RC_BAD_LAYOUT:     return "BAD_LAYOUT";
    case PATRM_RC_BAD_JOB:        return "BAD_JOB";
    case PATRM_RC_BAD_SIZE:       return "BAD_SIZE";
    case PATRM_RC_BAD_MODE:       return "BAD_MODE";
    case PATRM_RC_BAD_BLOCK_LEN:  return "BAD_BLOCK_LEN";
    case PATRM_RC_BAD_ADDR:       return "BAD_ADDR";
    case PATRM_RC_BAD_TRANSFORM:  return "BAD_TRANSFORM";
    case PATRM_RC_BAD_BUILD_ID:   return "BAD_BUILD_ID";
    case PATRM_RC_BUSY:           return "BUSY";
    case PATRM_RC_START_REJECTED: return "START_REJECTED";
    case PATRM_RC_TIMEOUT:        return "TIMEOUT";
    case PATRM_RC_NO_INTERRUPT:   return "NO_INTERRUPT";
    case PATRM_RC_BUS_ERROR:      return "BUS_ERROR";
    case PATRM_RC_ENGINE_ERROR:   return "ENGINE_ERROR";
    case PATRM_RC_IRQ_SETUP:      return "IRQ_SETUP";
    case PATRM_RC_NO_TIMER:       return "NO_TIMER";
    default:                      return "UNKNOWN";
    }
}

const char *patrm_err_name(uint32_t err_code)
{
    switch (err_code) {
    case PATRM_ERR_NONE:          return "NONE";
    case PATRM_ERR_BAD_SIZE:      return "BAD_SIZE";
    case PATRM_ERR_BAD_MODE:      return "BAD_MODE";
    case PATRM_ERR_BAD_ADDR:      return "BAD_ADDR";
    case PATRM_ERR_BAD_BLOCK_LEN: return "BAD_BLOCK_LEN";
    case PATRM_ERR_START_BUSY:    return "START_BUSY";
    case PATRM_ERR_BUS_ERROR:     return "BUS_ERROR";
    default:                      return "UNKNOWN";
    }
}
