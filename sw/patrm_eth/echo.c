/*
 * TCP echo server with flow control (step 10.1), lwIP raw API, bare metal on the ZedBoard ARM.
 *
 * Replaces echo.c of AMD's lwip_echo_server template (sw/patrm_eth/build_vitis.py copies it over the template file;
 * the template's main.c and platform code stay). The template echo acknowledges received data at once and drops it
 * when the send buffer is full ("no space in tcp_sndbuf"), so a bulk transfer comes back incomplete. Here:
 *   - received pbufs wait in a per-connection queue;
 *   - they are copied into the send buffer only as far as tcp_sndbuf() allows (tcp_write with TCP_WRITE_FLAG_COPY);
 *   - tcp_recved() is called only for the bytes already queued for sending, so the receive window, and with it the
 *     PC, slows down while the board cannot send. Nothing is ever dropped.
 * Port 7. On close the server prints the number of bytes echoed on that connection.
 * xil_printf: 32-bit values with %u and an (unsigned int) cast (step 4.2 lesson, %l is 64-bit in this BSP).
 */
#include <string.h>

#include "lwip/err.h"
#include "lwip/pbuf.h"
#include "lwip/tcp.h"
#include "xil_printf.h"

#define ECHO_PORT  7
#define MAX_CONN   4

struct echo_conn {
	int used;
	unsigned int id;
	struct pbuf *queue;          /* received, not yet copied into the send buffer */
	unsigned long long echoed;   /* bytes copied into the send buffer (= acknowledged to the PC) */
	int closing;                 /* the PC closed its side; close ours when the queue is empty */
};

static struct echo_conn conns[MAX_CONN];
static unsigned int next_id = 1;

int transfer_data(void)
{
	return 0;
}

void print_app_header(void)
{
	xil_printf("\n\r\n\r-----PATRM_ETH echo server (step 10.1, flow-controlled) ------\n\r");
	xil_printf("TCP data sent to port %u is echoed back unchanged\n\r", (unsigned int)ECHO_PORT);
}

static void conn_free(struct echo_conn *c)
{
	if (c->queue) {
		pbuf_free(c->queue);
	}
	memset(c, 0, sizeof(*c));
}

static void conn_report(const struct echo_conn *c, const char *how)
{
	unsigned long long n = c->echoed;
	xil_printf("ECHO conn %u %s: %u MB + %u bytes echoed\n\r", c->id, how,
		   (unsigned int)(n >> 20), (unsigned int)(n & 0xFFFFFu));
}

static void conn_close(struct tcp_pcb *tpcb, struct echo_conn *c)
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

/* Copy as much of the queue as the send buffer takes; acknowledge exactly that much to the PC. */
static void send_queued(struct tcp_pcb *tpcb, struct echo_conn *c)
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
			xil_printf("ECHO conn %u: tcp_write error %d\n\r", c->id, (int)err);
			break;
		}
		wrote = 1;
		c->echoed += n;
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

static err_t sent_callback(void *arg, struct tcp_pcb *tpcb, u16_t len)
{
	(void)len;
	struct echo_conn *c = (struct echo_conn *)arg;
	if (c) {
		send_queued(tpcb, c);
	}
	return ERR_OK;
}

static err_t recv_callback(void *arg, struct tcp_pcb *tpcb, struct pbuf *p, err_t err)
{
	struct echo_conn *c = (struct echo_conn *)arg;
	if (!c) {
		if (p) {
			pbuf_free(p);
		}
		return ERR_OK;
	}
	if (!p || err != ERR_OK) {              /* the PC closed its side */
		if (p) {
			pbuf_free(p);
		}
		c->closing = 1;
		send_queued(tpcb, c);
		return ERR_OK;
	}
	if (c->queue) {
		pbuf_cat(c->queue, p);
	} else {
		c->queue = p;
	}
	send_queued(tpcb, c);
	return ERR_OK;
}

static void err_callback(void *arg, err_t err)
{
	struct echo_conn *c = (struct echo_conn *)arg;
	if (c) {
		xil_printf("ECHO conn %u: aborted, error %d\n\r", c->id, (int)err);
		conn_report(c, "aborted");
		conn_free(c);                           /* lwIP has already freed the pcb */
	}
}

static err_t accept_callback(void *arg, struct tcp_pcb *newpcb, err_t err)
{
	(void)arg;
	if (err != ERR_OK || !newpcb) {
		return ERR_VAL;
	}
	struct echo_conn *c = NULL;
	for (int i = 0; i < MAX_CONN; i++) {
		if (!conns[i].used) {
			c = &conns[i];
			break;
		}
	}
	if (!c) {
		xil_printf("ECHO: more than %u connections, refused\n\r", (unsigned int)MAX_CONN);
		tcp_abort(newpcb);
		return ERR_ABRT;
	}
	memset(c, 0, sizeof(*c));
	c->used = 1;
	c->id = next_id++;
	tcp_arg(newpcb, c);
	tcp_recv(newpcb, recv_callback);
	tcp_sent(newpcb, sent_callback);
	tcp_err(newpcb, err_callback);
	tcp_nagle_disable(newpcb);
	return ERR_OK;
}

int start_application(void)
{
	struct tcp_pcb *pcb = tcp_new_ip_type(IPADDR_TYPE_ANY);
	if (!pcb) {
		xil_printf("Error creating PCB. Out of Memory\n\r");
		return -1;
	}
	err_t err = tcp_bind(pcb, IP_ANY_TYPE, ECHO_PORT);
	if (err != ERR_OK) {
		xil_printf("Unable to bind to port %u: err = %d\n\r", (unsigned int)ECHO_PORT, (int)err);
		return -2;
	}
	pcb = tcp_listen(pcb);
	if (!pcb) {
		xil_printf("Out of memory while tcp_listen\n\r");
		return -3;
	}
	tcp_accept(pcb, accept_callback);
	xil_printf("PATRM_ETH ECHO READY port %u\n\r", (unsigned int)ECHO_PORT);
	return 0;
}
