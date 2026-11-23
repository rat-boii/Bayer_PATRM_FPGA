/* Runs one job descriptor (patrm_job.h) on the engine or the ARM software baseline and fills the result record.
 *
 * Shared by the JTAG mailbox application (sw/patrm_app, steps 4.2-4.4) and the Ethernet application (sw/patrm_eth,
 * step 10.2), so both run a job with exactly the same code. Moved out of sw/patrm_app/main.c in step 10.2.
 */
#ifndef PATRM_JOBRUN_H
#define PATRM_JOBRUN_H

#include "patrm_drv.h"
#include "patrm_job.h"

/* Result record with magic, seq, layout, rc and the device fields set, everything else 0. */
void patrm_jobrun_header(const patrm_dev_t *dev, patrm_job_result_t *r, uint32_t seq, patrm_rc_t rc);

/* Checks the descriptor, runs its frame d->repeat times, fills r (including the header). */
void patrm_jobrun(patrm_dev_t *dev, const patrm_job_desc_t *d, patrm_job_result_t *r);

/* One "RESULT ..." line on the UART. */
void patrm_jobrun_print(const patrm_job_result_t *r);

#endif /* PATRM_JOBRUN_H */
