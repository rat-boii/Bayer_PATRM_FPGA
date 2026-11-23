/*
 * Ethernet test services (steps 10.1 / 10.1b), lwIP raw API, bare metal on the ZedBoard ARM.
 *
 * Replaces echo.c of AMD's lwip_echo_server template (sw/patrm_eth/build_vitis.py copies it over the template file;
 * the template's main.c and platform code stay). Started by eth_job.c (eth_test_start). Three TCP services:
 *
 *   port 7     echo   Everything received is sent back unchanged, with flow control: received pbufs wait in a queue,
 *                     are copied into the send buffer only as far as tcp_sndbuf() allows, and tcp_recved() is called
 *                     only for bytes already queued for sending. (The template echo acknowledges at once and drops
 *                     data when the send buffer is full.)
 *   port 5001  sink   PC -> board. Everything received is acknowledged and discarded. When the PC closes its side,
 *                     the board sends the byte count (8 bytes, little endian) and closes: the PC times the upload.
 *   port 5002  source board -> PC. The PC sends N (4 bytes, little endian); the board sends N bytes,
 *                     byte i = pattern_byte(i) (scripts/eth/echo_test.py checks every byte), then closes.
 *
 * On close each connection prints its byte count on the UART.
 * xil_printf: 32-bit values with %u and an (unsigned int) cast (step 4.2 lesson, %l is 64-bit in this BSP).
 */
#include <string.h>

#include "lwip/err.h"
#include "lwip/pbuf.h"
#include "lwip/tcp.h"
#include "xil_printf.h"

#define ECHO_PORT    7
#define SINK_PORT    5001
#define SOURCE_PORT  5002
#define MAX_CONN     4
#define PATTERN_LEN  65536u

enum mode { MODE_ECHO, MODE_SINK, MODE_SOURCE };

struct conn {
	int used;
	enum mode mode;
	unsigned int id;
	struct pbuf *queue;          /* echo: received, not yet copied into the send buffer */
	unsigned long long bytes;    /* echo: bytes queued back; sink: bytes received; source: bytes queued */
	int closing;                 /* the PC closed its side */
	unsigned char hdr[4];        /* source: request header */
	unsigned int hdr_len;
	unsigned int to_send;        /* source: bytes still to queue */
};

static struct conn conns[MAX_CONN];
static unsigned int next_id = 1;
static unsigned char pattern[PATTERN_LEN];

/* The source pattern: data byte i is pattern[i % PATTERN_LEN]. Same formula in scripts/eth/echo_test.py. */
static void pattern_init(void)
{
	for (unsigned int k = 0; k < PATTERN_LEN; k++) {
		pattern[k] = (unsigned char)((k * 31u + (k >> 8)) & 0xFFu);
	}
}

static const char *mode_name(enum mode m)
{
	return m == MODE_ECHO ? "echo" : (m == MODE_SINK ? "sink" : "source");
}

static void conn_report(const struct conn *c, const char *how)
{
	unsigned long long n = c->bytes;
	xil_printf("%s conn %u %s: %u MB + %u bytes\n\r", mode_name(c->mode), c->id, how,
		   (unsigned int)(n >> 20), (unsigned int)(n & 0xFFFFFu));
}

static void conn_free(struct conn *c)
{
	if (c->queue) {
		pbuf_free(c->queue);
	}
	memset(c, 0, sizeof(*c));
}

static void conn_close(struct tcp_pcb *tpcb, struct conn *c)
{
	tcp_arg(tpcb, NULL);
	tcp_recv(tpcb, NULL);
	tcp_sent(tpcb, NULL);
	tcp_err(tpcb, NULL);
	conn_report(c, "closed");
	conn_free(c);
	if (tcp_close(tpcb) != ERR_OK) {
		tcp_abort(tpcb);
	}
}

/* echo: copy as much of the queue as the send buffer takes; acknowledge exactly that much to the PC. */
static void echo_send_queued(struct tcp_pcb *tpcb, struct conn *c)
{
	int wrote = 0;
	while (c->queue) {
		u16_t space = tcp_sndbuf(tpcb);
		u16_t n = c->queue->len;
		if (n > space) {
			n = space;
		}
		if (n == 0) {
			if (c->queue->len == 0) {          /* empty pbuf in the chain: unlink and free it */
				struct pbuf *f = c->queue;     /* (as pbuf_free_header does for a used-up pbuf) */
				c->queue = f->next;
				f->next = NULL;
				pbuf_free(f);
				continue;
			}
			break;                              /* send buffer full: wait for the sent callback */
		}
		err_t err = tcp_write(tpcb, c->queue->payload, n, TCP_WRITE_FLAG_COPY);
		if (err == ERR_MEM) {
			break;                              /* segment queue full: wait for the sent callback */
		}
		if (err != ERR_OK) {
			xil_printf("echo conn %u: tcp_write error %d\n\r", c->id, (int)err);
			break;
		}
		wrote = 1;
		c->bytes += n;
		tcp_recved(tpcb, n);
		c->queue = pbuf_free_header(c->queue, n);
	}
	if (wrote) {
		tcp_output(tpcb);
	}
	if (c->closing && !c->queue) {
		conn_close(tpcb, c);
	}
}

/* source: queue pattern bytes as far as the send buffer takes them (the pattern buffer is static: no copy). */
static void source_send(struct tcp_pcb *tpcb, struct conn *c)
{
	int wrote = 0;
	while (c->to_send > 0) {
		unsigned int off = (unsigned int)(c->bytes % PATTERN_LEN);
		unsigned int n = PATTERN_LEN - off;
		unsigned int space = tcp_sndbuf(tpcb);
		if (n > c->to_send) {
			n = c->to_send;
		}
		if (n > space) {
			n = space;
		}
		if (n > 0xFFFFu) {
			n = 0xFFFFu;
		}
		if (n == 0) {
			break;
		}
		u8_t flags = (c->to_send > n) ? TCP_WRITE_FLAG_MORE : 0;
		err_t err = tcp_write(tpcb, &pattern[off], (u16_t)n, flags);
		if (err == ERR_MEM) {
			break;
		}
		if (err != ERR_OK) {
			xil_printf("source conn %u: tcp_write error %d\n\r", c->id, (int)err);
			break;
		}
		wrote = 1;
		c->bytes += n;
		c->to_send -= n;
	}
	if (wrote) {
		tcp_output(tpcb);
	}
}

static err_t sent_callback(void *arg, struct tcp_pcb *tpcb, u16_t len)
{
	(void)len;
	struct conn *c = (struct conn *)arg;
	if (!c) {
		return ERR_OK;
	}
	if (c->mode == MODE_ECHO) {
		echo_send_queued(tpcb, c);
	} else if (c->mode == MODE_SOURCE) {
		source_send(tpcb, c);
		/* everything queued and acknowledged by the PC: close */
		if (c->to_send == 0 && c->hdr_len == 4 && tpcb->unacked == NULL && tpcb->unsent == NULL) {
			conn_close(tpcb, c);
		}
	} else if (c->mode == MODE_SINK && c->closing && tpcb->unacked == NULL && tpcb->unsent == NULL) {
		conn_close(tpcb, c);                    /* the count has been delivered */
	}
	return ERR_OK;
}

static err_t recv_callback(void *arg, struct tcp_pcb *tpcb, struct pbuf *p, err_t err)
{
	struct conn *c = (struct conn *)arg;
	if (!c) {
		if (p) {
			tcp_recved(tpcb, p->tot_len);
			pbuf_free(p);
		}
		return ERR_OK;
	}
	if (!p || err != ERR_OK) {              /* the PC closed its side */
		if (p) {
			pbuf_free(p);
		}
		c->closing = 1;
		if (c->mode == MODE_ECHO) {
			echo_send_queued(tpcb, c);
		} else if (c->mode == MODE_SINK) {
			unsigned char cnt[8];
			for (int i = 0; i < 8; i++) {
				cnt[i] = (unsigned char)(c->bytes >> (8 * i));
			}
			tcp_write(tpcb, cnt, 8, TCP_WRITE_FLAG_COPY);
			tcp_output(tpcb);
		} else if (c->to_send == 0) {
			conn_close(tpcb, c);
		}
		return ERR_OK;
	}

	if (c->mode == MODE_ECHO) {
		if (c->queue) {
			pbuf_cat(c->queue, p);
		} else {
			c->queue = p;
		}
		echo_send_queued(tpcb, c);
		return ERR_OK;
	}

	u16_t total = p->tot_len;
	if (c->mode == MODE_SINK) {
		c->bytes += total;
	} else {                                /* source: collect the 4-byte request, ignore anything after it */
		for (struct pbuf *q = p; q && c->hdr_len < 4; q = q->next) {
			const unsigned char *b = (const unsigned char *)q->payload;
			for (u16_t i = 0; i < q->len && c->hdr_len < 4; i++) {
				c->hdr[c->hdr_len++] = b[i];
			}
		}
		if (c->hdr_len == 4 && c->to_send == 0 && c->bytes == 0) {
			c->to_send = (unsigned int)c->hdr[0] | ((unsigned int)c->hdr[1] << 8) |
				     ((unsigned int)c->hdr[2] << 16) | ((unsigned int)c->hdr[3] << 24);
			source_send(tpcb, c);
		}
	}
	tcp_recved(tpcb, total);
	pbuf_free(p);
	return ERR_OK;
}

static void err_callback(void *arg, err_t err)
{
	struct conn *c = (struct conn *)arg;
	if (c) {
		xil_printf("%s conn %u: aborted, error %d\n\r", mode_name(c->mode), c->id, (int)err);
		conn_report(c, "aborted");
		conn_free(c);                           /* lwIP has already freed the pcb */
	}
}

static err_t accept_common(struct tcp_pcb *newpcb, err_t err, enum mode m)
{
	if (err != ERR_OK || !newpcb) {
		return ERR_VAL;
	}
	struct conn *c = NULL;
	for (int i = 0; i < MAX_CONN; i++) {
		if (!conns[i].used) {
			c = &conns[i];
			break;
		}
	}
	if (!c) {
		xil_printf("more than %u connections, refused\n\r", (unsigned int)MAX_CONN);
		tcp_abort(newpcb);
		return ERR_ABRT;
	}
	memset(c, 0, sizeof(*c));
	c->used = 1;
	c->mode = m;
	c->id = next_id++;
	tcp_arg(newpcb, c);
	tcp_recv(newpcb, recv_callback);
	tcp_sent(newpcb, sent_callback);
	tcp_err(newpcb, err_callback);
	tcp_nagle_disable(newpcb);
	return ERR_OK;
}

static err_t accept_echo(void *arg, struct tcp_pcb *newpcb, err_t err)
{
	(void)arg;
	return accept_common(newpcb, err, MODE_ECHO);
}

static err_t accept_sink(void *arg, struct tcp_pcb *newpcb, err_t err)
{
	(void)arg;
	return accept_common(newpcb, err, MODE_SINK);
}

static err_t accept_source(void *arg, struct tcp_pcb *newpcb, err_t err)
{
	(void)arg;
	return accept_common(newpcb, err, MODE_SOURCE);
}

static int listen_on(unsigned int port, tcp_accept_fn fn)
{
	struct tcp_pcb *pcb = tcp_new_ip_type(IPADDR_TYPE_ANY);
	if (!pcb) {
		xil_printf("Error creating PCB. Out of Memory\n\r");
		return -1;
	}
	err_t err = tcp_bind(pcb, IP_ANY_TYPE, (u16_t)port);
	if (err != ERR_OK) {
		xil_printf("Unable to bind to port %u: err = %d\n\r", port, (int)err);
		return -2;
	}
	pcb = tcp_listen(pcb);
	if (!pcb) {
		xil_printf("Out of memory while tcp_listen\n\r");
		return -3;
	}
	tcp_accept(pcb, fn);
	return 0;
}

/* Called from start_application() in eth_job.c (which owns the template's hooks since step 10.2). */
int eth_test_start(void)
{
	pattern_init();
	if (listen_on(ECHO_PORT, accept_echo) || listen_on(SINK_PORT, accept_sink) ||
	    listen_on(SOURCE_PORT, accept_source)) {
		return -1;
	}
	xil_printf("PATRM_ETH ECHO READY port %u (sink %u, source %u)\n\r", (unsigned int)ECHO_PORT,
		   (unsigned int)SINK_PORT, (unsigned int)SOURCE_PORT);
	return 0;
}
