/* PATRM jobs over Ethernet (step 10.2): request and response headers on TCP port 5003.
 *
 * The job descriptor and the result record are the ones of the JTAG path (patrm_job.h, spec/memory_map.md section 5),
 * unchanged; Ethernet only wraps them. PC side: scripts/eth/eth_link.py (same layout, checked by its self-test).
 * All fields 32-bit little endian. One connection can carry any number of jobs, one after the other.
 *
 * PC -> board:  request header (32 bytes) | job descriptor (96 bytes) | source image (src_bytes)
 * board -> PC:  response header (32 bytes) | result record (128 bytes) | output area (out_bytes)
 *
 * src_bytes = 0 keeps the source already in DDR (a GUI sends the image once, then only new transforms).
 * src_bytes > 0 must equal width x height and needs the descriptor flag SRC_CPU (the ARM writes the source).
 * out_bytes = bytes of the output area sent back from dst_addr (0 = none; W x H + 4096 for the guard check).
 * Flag FILL: the board fills those out_bytes with 0xA5 before the job, as the JTAG runner does, so bytes the engine
 * never wrote and writes past the image (guard) are visible.
 */
#ifndef PATRM_ETH_H
#define PATRM_ETH_H

#include <stdint.h>

#define PATRM_ETH_PORT            5003U
#define PATRM_ETH_REQ_MAGIC       0x48544550U   /* "PETH" in memory */
#define PATRM_ETH_RSP_MAGIC       0x52544550U   /* "PETR" in memory */
#define PATRM_ETH_VERSION         1U
#define PATRM_ETH_FLAG_FILL       0x1U
#define PATRM_ETH_FILL_BYTE       0xA5U

/* response status (protocol level; the job's own result is the rc in the result record) */
#define PATRM_ETH_OK              0U
#define PATRM_ETH_BAD_HEADER      1U            /* magic, version or unknown flags */
#define PATRM_ETH_BAD_SIZES       2U            /* src_bytes / out_bytes / addresses / SRC_CPU flag */

/* the buffer window of spec/memory_map.md section 1 (model/job.py BUF_LO / BUF_HI) */
#define PATRM_ETH_BUF_LO          0x0F000000U
#define PATRM_ETH_BUF_HI          0x1F000000U

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t src_bytes;
    uint32_t out_bytes;
    uint32_t flags;
    uint32_t reserved[3];
} patrm_eth_req_t;

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t status;                /* PATRM_ETH_* */
    uint32_t out_bytes;             /* bytes of the output area that follow the result record */
    uint32_t rx_us;                 /* board: first request byte to last source byte received */
    uint32_t job_us;                /* board: fill + patrm_jobrun (all frames) + cache work */
    uint32_t reserved[2];
} patrm_eth_rsp_t;

_Static_assert(sizeof(patrm_eth_req_t) == 32U, "request header size");
_Static_assert(sizeof(patrm_eth_rsp_t) == 32U, "response header size");

#endif /* PATRM_ETH_H */
