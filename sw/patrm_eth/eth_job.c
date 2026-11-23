/*
 * PATRM jobs over Ethernet (step 10.2): TCP port 5003, protocol in patrm_eth.h. lwIP raw API, bare metal.
 *
 * Owns the template's hooks (print_app_header, start_application, transfer_data); the test services of echo.c
 * (ports 7, 5001, 5002) are started from here.
 *
 * Per connection, a state machine:
 *   HDR   collect request header + job descriptor (128 bytes), check them
 *   SRC   copy src_bytes straight into DDR at the descriptor's src_addr
 *   RUN   wait for the main loop (transfer_data): the job never runs inside an lwIP callback
 *   SEND  response header + result record (copied), then the output area by reference (no copy): lwIP keeps pointers
 *         into DDR until the PC acknowledges, so the next job starts only when everything sent has been acknowledged.
 * Received bytes wait in a queue and are acknowledged (tcp_recved) only when consumed, so a PC that sends the next
 * request early is slowed by the TCP window instead of losing data.
 *
 * The engine is polled (descriptor flag IRQ_EN must be 0): lwIP's platform code owns the GIC and the IRQ vector, and
 * patrm_irq_init would replace that handler. CYCLES does not depend on how the ARM waits.
 * Cache: the ARM writes the source through the cache; the job flag SRC_CPU makes the driver flush it before START.
 * The output area is filled (flag FILL) and flushed before, and invalidated after the job, then sent from DDR.
 */
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "lwip/err.h"
#include "lwip/pbuf.h"
#include "lwip/tcp.h"
#include "patrm_drv.h"
#include "patrm_eth.h"
#include "patrm_job.h"
#include "patrm_jobrun.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xpseudo_asm.h"

int eth_test_start(void);                    /* echo.c */

#define REQ_BYTES  ((u32_t)(sizeof(patrm_eth_req_t) + sizeof(patrm_job_desc_t)))
#define RSP_BYTES  ((u32_t)(sizeof(patrm_eth_rsp_t) + sizeof(patrm_job_result_t)))

enum state { ST_HDR, ST_SRC, ST_RUN, ST_SEND };

struct jobconn {
	struct tcp_pcb *pcb;
	enum state st;
	struct pbuf *rxq;                        /* received, not yet consumed */
	unsigned char req[sizeof(patrm_eth_req_t) + sizeof(patrm_job_desc_t)];
	u32_t req_len;
	patrm_eth_req_t hdr;
	patrm_job_desc_t desc;
	u32_t src_got;
	u64_t t_first;                            /* first byte of this request */
	u32_t rx_us;
	unsigned char rsp[sizeof(patrm_eth_rsp_t) + sizeof(patrm_job_result_t)];
	u32_t rsp_queued;
	u32_t out_bytes;
	u32_t out_queued;
	unsigned int jobs;
};

static patrm_dev_t dev;
static patrm_rc_t init_rc = PATRM_RC_OK;
static struct jobconn jc;                     /* one job connection at a time */
static int jc_used;

static u32_t ticks_to_us(u64_t ticks)
{
	return patrm_ticks_to_ns(ticks) / 1000U;
}

void print_app_header(void)
{
	xil_printf("\n\r\n\r-----PATRM_ETH: jobs over Ethernet (step 10.2) + test services ------\n\r");
}

static void jc_close(const char *why)
{
	struct tcp_pcb *pcb = jc.pcb;
	xil_printf("JOB conn closed (%s) after %u jobs\n\r", why, jc.jobs);
	if (jc.rxq) {
		pbuf_free(jc.rxq);
	}
	memset(&jc, 0, sizeof(jc));
	jc_used = 0;
	if (pcb) {
		tcp_arg(pcb, NULL);
		tcp_recv(pcb, NULL);
		tcp_sent(pcb, NULL);
		tcp_err(pcb, NULL);
		if (tcp_close(pcb) != ERR_OK) {
			tcp_abort(pcb);
		}
	}
}

/* Header + descriptor complete: check them. Returns PATRM_ETH_OK or the error status. */
static u32_t check_request(void)
{
	memcpy(&jc.hdr, jc.req, sizeof(jc.hdr));
	memcpy(&jc.desc, jc.req + sizeof(jc.hdr), sizeof(jc.desc));
	const patrm_eth_req_t *h = &jc.hdr;
	const patrm_job_desc_t *d = &jc.desc;
	if (h->magic != PATRM_ETH_REQ_MAGIC || h->version != PATRM_ETH_VERSION ||
	    (h->flags & ~PATRM_ETH_FLAGS_KNOWN) != 0U) {
		return PATRM_ETH_BAD_HEADER;
	}
	if (h->src_bytes != 0U) {
		if (h->src_bytes != d->width * d->height || (d->flags & PATRM_JOB_FLAG_SRC_CPU) == 0U) {
			return PATRM_ETH_BAD_SIZES;
		}
	}
	/* both areas inside the buffer window, without wrapping */
	if (d->src_addr < PATRM_ETH_BUF_LO || d->src_addr >= PATRM_ETH_BUF_HI ||
	    h->src_bytes > PATRM_ETH_BUF_HI - d->src_addr ||
	    d->dst_addr < PATRM_ETH_BUF_LO || d->dst_addr >= PATRM_ETH_BUF_HI ||
	    h->out_bytes > PATRM_ETH_BUF_HI - d->dst_addr) {
		return PATRM_ETH_BAD_SIZES;
	}
	return PATRM_ETH_OK;
}

static void build_response(u32_t status, const patrm_job_result_t *r, u32_t job_us)
{
	patrm_eth_rsp_t rsp;
	memset(&rsp, 0, sizeof(rsp));
	rsp.magic = PATRM_ETH_RSP_MAGIC;
	rsp.version = PATRM_ETH_VERSION;
	rsp.status = status;
	rsp.out_bytes = (status == PATRM_ETH_OK) ? jc.hdr.out_bytes : 0U;
	rsp.rx_us = jc.rx_us;
	rsp.job_us = job_us;
	memcpy(jc.rsp, &rsp, sizeof(rsp));
	memcpy(jc.rsp + sizeof(rsp), r, sizeof(*r));
	jc.rsp_queued = 0U;
	jc.out_bytes = rsp.out_bytes;
	jc.out_queued = 0U;
	jc.st = ST_SEND;
}

/* Queue as much of the response as the send buffer takes. */
static void send_more(void)
{
	struct tcp_pcb *pcb = jc.pcb;
	int wrote = 0;
	while (jc.rsp_queued < RSP_BYTES) {
		u32_t n = RSP_BYTES - jc.rsp_queued;
		u32_t space = tcp_sndbuf(pcb);
		n = (n > space) ? space : n;
		if (n == 0U || tcp_write(pcb, jc.rsp + jc.rsp_queued, (u16_t)n, TCP_WRITE_FLAG_COPY) != ERR_OK) {
			break;
		}
		jc.rsp_queued += n;
		wrote = 1;
	}
	if (jc.rsp_queued == RSP_BYTES) {
		const unsigned char *out = (const unsigned char *)(uintptr_t)jc.desc.dst_addr;
		while (jc.out_queued < jc.out_bytes) {
			u32_t n = jc.out_bytes - jc.out_queued;
			u32_t space = tcp_sndbuf(pcb);
			n = (n > space) ? space : n;
			n = (n > 0xFFFFU) ? 0xFFFFU : n;
			if (n == 0U) {
				break;
			}
			u8_t flags = (jc.out_queued + n < jc.out_bytes) ? TCP_WRITE_FLAG_MORE : 0U;
			if (tcp_write(pcb, out + jc.out_queued, (u16_t)n, flags) != ERR_OK) {
				break;
			}
			jc.out_queued += n;
			wrote = 1;
		}
	}
	if (wrote) {
		tcp_output(pcb);
	}
}

static int send_complete(void)
{
	return jc.st == ST_SEND && jc.rsp_queued == RSP_BYTES && jc.out_queued == jc.out_bytes &&
	       jc.pcb->unsent == NULL && jc.pcb->unacked == NULL;
}

/* Consume queued received bytes in states HDR and SRC. */
static void consume(void)
{
	while (jc.rxq && (jc.st == ST_HDR || jc.st == ST_SRC)) {
		struct pbuf *p = jc.rxq;
		u16_t len = p->len;
		u16_t used = 0;
		const unsigned char *data = (const unsigned char *)p->payload;
		if (len == 0U) {
			jc.rxq = p->next;
			p->next = NULL;
			pbuf_free(p);
			continue;
		}
		if (jc.st == ST_HDR) {
			if (jc.req_len == 0U) {
				jc.t_first = patrm_now();
			}
			u32_t n = REQ_BYTES - jc.req_len;
			n = (n > len) ? len : n;
			memcpy(jc.req + jc.req_len, data, n);
			jc.req_len += n;
			used = (u16_t)n;
			if (jc.req_len == REQ_BYTES) {
				u32_t status = check_request();
				if (status != PATRM_ETH_OK) {
					patrm_job_result_t r;
					patrm_jobrun_header(&dev, &r, jc.desc.seq, PATRM_RC_BAD_JOB);
					xil_printf("JOB request rejected, status %u\n\r", (unsigned int)status);
					jc.rx_us = 0U;
					build_response(status, &r, 0U);
					send_more();
					/* the rest of a rejected request cannot be framed: close after the response */
				} else {
					jc.src_got = 0U;
					jc.st = (jc.hdr.src_bytes > 0U) ? ST_SRC : ST_RUN;
					if (jc.st == ST_RUN) {
						jc.rx_us = ticks_to_us(patrm_now() - jc.t_first);
					}
				}
			}
		} else {                                 /* ST_SRC */
			u32_t n = jc.hdr.src_bytes - jc.src_got;
			n = (n > len) ? len : n;
			memcpy((unsigned char *)(uintptr_t)(jc.desc.src_addr + jc.src_got), data, n);
			jc.src_got += n;
			used = (u16_t)n;
			if (jc.src_got == jc.hdr.src_bytes) {
				jc.rx_us = ticks_to_us(patrm_now() - jc.t_first);
				jc.st = ST_RUN;
			}
		}
		tcp_recved(jc.pcb, used);
		jc.rxq = pbuf_free_header(jc.rxq, used);
	}
}

/* Main loop (template main.c calls it after every xemacif_input). */
int transfer_data(void)
{
	if (!jc_used) {
		return 0;
	}
	if (jc.st == ST_RUN) {
		patrm_job_result_t r;
		const u32_t out = jc.hdr.out_bytes;
		unsigned char *dst = (unsigned char *)(uintptr_t)jc.desc.dst_addr;
		u64_t t0 = patrm_now();
		if (init_rc != PATRM_RC_OK) {
			patrm_jobrun_header(&dev, &r, jc.desc.seq, init_rc);
		} else {
			/* The output goes back by DMA straight from DDR, so DDR must hold it; the ARM never reads it. The fill
			 * is written through the cache and flushed; the driver cleans and invalidates the image area itself
			 * before START (patrm_run) and the software baseline flushes its output (patrm_jobrun). */
			if (out > 0U && (jc.hdr.flags & PATRM_ETH_FLAG_FILL) != 0U) {
				memset(dst, PATRM_ETH_FILL_BYTE, out);
				Xil_DCacheFlushRange((INTPTR)dst, (INTPTR)out);
				dsb();
			}
			patrm_jobrun(&dev, &jc.desc, &r);
		}
		u32_t job_us = ticks_to_us(patrm_now() - t0);
		jc.jobs++;
		if ((jc.hdr.flags & PATRM_ETH_FLAG_QUIET) == 0U) {
			patrm_jobrun_print(&r);
		}
		build_response(PATRM_ETH_OK, &r, job_us);
		send_more();
	}
	if (send_complete()) {
		patrm_eth_rsp_t rsp;
		memcpy(&rsp, jc.rsp, sizeof(rsp));
		if (rsp.status != PATRM_ETH_OK) {
			jc_close("request rejected");
			return 0;
		}
		jc.st = ST_HDR;
		jc.req_len = 0U;
		consume();
	}
	return 0;
}

static err_t job_sent(void *arg, struct tcp_pcb *tpcb, u16_t len)
{
	(void)arg;
	(void)tpcb;
	(void)len;
	if (jc_used && jc.st == ST_SEND) {
		send_more();
	}
	return ERR_OK;
}

static err_t job_recv(void *arg, struct tcp_pcb *tpcb, struct pbuf *p, err_t err)
{
	(void)arg;
	(void)tpcb;
	if (!jc_used) {
		if (p) {
			pbuf_free(p);
		}
		return ERR_OK;
	}
	if (!p || err != ERR_OK) {
		if (p) {
			pbuf_free(p);
		}
		jc_close("PC closed");
		return ERR_OK;
	}
	if (jc.rxq) {
		pbuf_cat(jc.rxq, p);
	} else {
		jc.rxq = p;
	}
	consume();
	return ERR_OK;
}

static void job_err(void *arg, err_t err)
{
	(void)arg;
	xil_printf("JOB conn aborted, error %d, after %u jobs\n\r", (int)err, jc.jobs);
	if (jc.rxq) {
		pbuf_free(jc.rxq);
	}
	memset(&jc, 0, sizeof(jc));               /* lwIP has already freed the pcb */
	jc_used = 0;
}

static err_t job_accept(void *arg, struct tcp_pcb *newpcb, err_t err)
{
	(void)arg;
	if (err != ERR_OK || !newpcb) {
		return ERR_VAL;
	}
	if (jc_used) {
		xil_printf("JOB: a job connection is already open, refused\n\r");
		tcp_abort(newpcb);
		return ERR_ABRT;
	}
	memset(&jc, 0, sizeof(jc));
	jc_used = 1;
	jc.pcb = newpcb;
	jc.st = ST_HDR;
	tcp_arg(newpcb, NULL);
	tcp_recv(newpcb, job_recv);
	tcp_sent(newpcb, job_sent);
	tcp_err(newpcb, job_err);
	tcp_nagle_disable(newpcb);
	return ERR_OK;
}

int start_application(void)
{
	init_rc = patrm_init(&dev, PATRM_REG_BASE);
	xil_printf("BUILD_ID 0x%08x, init %s, global timer %u Hz (engine polled, no interrupt)\r\n",
		   (unsigned int)dev.build_id, patrm_rc_name(init_rc), (unsigned int)patrm_timer_hz());
	if (eth_test_start() != 0) {
		return -1;
	}
	struct tcp_pcb *pcb = tcp_new_ip_type(IPADDR_TYPE_ANY);
	if (!pcb || tcp_bind(pcb, IP_ANY_TYPE, (u16_t)PATRM_ETH_PORT) != ERR_OK) {
		xil_printf("JOB: cannot bind port %u\n\r", (unsigned int)PATRM_ETH_PORT);
		return -1;
	}
	pcb = tcp_listen(pcb);
	if (!pcb) {
		xil_printf("JOB: tcp_listen failed\n\r");
		return -1;
	}
	tcp_accept(pcb, job_accept);
	xil_printf("PATRM_ETH JOBS READY port %u\n\r", (unsigned int)PATRM_ETH_PORT);
	return 0;
}
