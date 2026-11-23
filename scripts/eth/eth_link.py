"""PC side of PATRM jobs over Ethernet (step 10.2): protocol of sw/patrm_eth/patrm_eth.h, board loading, ready wait.

    python scripts/eth/eth_link.py --selftest        layout and constants against sw/patrm_eth/patrm_eth.h

Used by scripts/board/run_job.py --link eth (and so run_all.py --link eth) and scripts/eth/echo_test.py.
The job descriptor and result record are model/job.py's (spec/memory_map.md section 5), unchanged.

Request  (PC -> board, TCP 5003): header 32 B | descriptor 96 B | source (src_bytes)
Response (board -> PC):           header 32 B | result 128 B | output area (out_bytes)
"""
import re
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
from amd_tools import require_tool           # noqa: E402

BOARD_IP = "192.168.1.10"
JOB_PORT = 5003
REQ_MAGIC = 0x4854_4550                       # "PETH" in memory
RSP_MAGIC = 0x5254_4550                       # "PETR" in memory
VERSION = 1
FLAG_FILL = 0x1
FLAG_QUIET = 0x2                              # no UART line per job (step 10.3)
FILL_BYTE = 0xA5
STATUS = {0: "OK", 1: "BAD_HEADER", 2: "BAD_SIZES"}
REQ_FMT = "<8I"                               # magic version src_bytes out_bytes flags reserved[3]
RSP_FMT = "<8I"                               # magic version status out_bytes rx_us job_us reserved[2]
HDR_SIZE = struct.calcsize(REQ_FMT)
RESULT_SIZE = 128
REV_D = REPO / "results" / "hw" / "rev D"
ETH_ELF = REPO / "results" / "hw" / "patrm_eth.elf"
HEADER_C = REPO / "sw" / "patrm_eth" / "patrm_eth.h"


class LinkError(Exception):
    pass


def encode_request(src_bytes, out_bytes, fill=True, quiet=False):
    flags = (FLAG_FILL if fill else 0) | (FLAG_QUIET if quiet else 0)
    return struct.pack(REQ_FMT, REQ_MAGIC, VERSION, src_bytes, out_bytes, flags, 0, 0, 0)


def decode_response(data):
    if len(data) != HDR_SIZE:
        raise LinkError(f"response header has {len(data)} bytes, not {HDR_SIZE}")
    magic, version, status, out_bytes, rx_us, job_us, _r0, _r1 = struct.unpack(RSP_FMT, data)
    if magic != RSP_MAGIC or version != VERSION:
        raise LinkError(f"bad response header: magic 0x{magic:08X}, version {version}")
    return dict(status=status, status_name=STATUS.get(status, f"unknown {status}"), out_bytes=out_bytes,
                rx_us=rx_us, job_us=job_us)


def recv_exact(sock, n):
    buf = bytearray(n)
    view = memoryview(buf)
    got = 0
    while got < n:
        k = sock.recv_into(view[got:], min(n - got, 1 << 20))
        if k == 0:
            raise LinkError(f"connection closed after {got} of {n} bytes")
        got += k
    return bytes(buf)


class JobLink:
    """One TCP connection to the board's job service; any number of jobs, one after the other."""

    def __init__(self, ip=BOARD_IP, port=JOB_PORT, timeout=60.0):
        self.sock = socket.create_connection((ip, port), timeout=10)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock.settimeout(timeout)

    def run(self, descriptor, src=None, out_bytes=0, fill=True, quiet=False):
        """Send one job; returns (response header dict, result record bytes, output bytes, PC timings dict).
        src None or b'' keeps the source already on the board."""
        src = src or b""
        t0 = time.perf_counter()
        self.sock.sendall(encode_request(len(src), out_bytes, fill, quiet) + descriptor)
        if src:
            self.sock.sendall(src)
        t_sent = time.perf_counter()
        rsp = decode_response(recv_exact(self.sock, HDR_SIZE))
        t_first = time.perf_counter()
        result = recv_exact(self.sock, RESULT_SIZE)
        out = recv_exact(self.sock, rsp["out_bytes"]) if rsp["out_bytes"] else b""
        t_end = time.perf_counter()
        times = dict(send_s=t_sent - t0, until_response_s=t_first - t0, download_s=t_end - t_first,
                     round_trip_s=t_end - t0)
        return rsp, result, out, times

    def close(self):
        self.sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def run_xsdb(script, args, timeout=300):
    xsdb = require_tool("xsdb")
    cmd = ["cmd", "/c", str(xsdb)] if xsdb.suffix.lower() in (".bat", ".cmd") else [str(xsdb)]
    cmd += [Path(script).as_posix()] + [str(a) for a in args]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=REPO)
    out = (proc.stdout or "") + (proc.stderr or "")
    bad = [ln for ln in out.splitlines() if "BOARD ERROR" in ln]
    if bad:
        raise LinkError(f"{Path(script).name}: {bad[0]}")
    return out


def load_board(bit=REV_D / "patrm_gray.bit", init=REV_D / "ps7_init.tcl", elf=ETH_ELF):
    """Program, ps7_init, load the ELF halted, route MDIO to MIO 52/53 (scripts/eth/mdio_mio.tcl: the Rev D XSA has
    MDIO on EMIO), start core 0."""
    for p in (bit, init, elf):
        if not Path(p).is_file():
            raise LinkError(f"missing {p}")
    out = run_xsdb(REPO / "scripts" / "board" / "load_run.tcl",
                   ["--bit", bit, "--init", init, "--elf", elf, "--no-run"])
    if "load_run: DONE" not in out:
        raise LinkError("load_run.tcl did not print 'load_run: DONE':\n" + out[-1500:])
    out = run_xsdb(REPO / "scripts" / "eth" / "mdio_mio.tcl", ["--con"])
    if "mdio_mio: DONE" not in out:
        raise LinkError("mdio_mio.tcl did not print 'mdio_mio: DONE':\n" + out[-1500:])


def wait_ready(ip=BOARD_IP, port=JOB_PORT, timeout=90.0):
    """Until the job port accepts a connection (the board boots in about 27 s). Returns the seconds waited."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            with socket.create_connection((ip, port), timeout=2):
                return time.time() - t0
        except OSError:
            time.sleep(1)
    raise LinkError(f"{ip}:{port} not reachable within {timeout:.0f} s (cable, laptop IP 192.168.1.100/24, board?)")


def selftest():
    """Constants and sizes against sw/patrm_eth/patrm_eth.h."""
    text = HEADER_C.read_text(encoding="utf-8")
    defs = {k: int(v, 0) for k, v in re.findall(r"#define\s+(PATRM_ETH_\w+)\s+(0x[0-9A-Fa-f]+|\d+)U?", text)}
    want = {"PATRM_ETH_PORT": JOB_PORT, "PATRM_ETH_REQ_MAGIC": REQ_MAGIC, "PATRM_ETH_RSP_MAGIC": RSP_MAGIC,
            "PATRM_ETH_VERSION": VERSION, "PATRM_ETH_FLAG_FILL": FLAG_FILL, "PATRM_ETH_FLAG_QUIET": FLAG_QUIET,
            "PATRM_ETH_FILL_BYTE": FILL_BYTE,
            "PATRM_ETH_OK": 0, "PATRM_ETH_BAD_HEADER": 1, "PATRM_ETH_BAD_SIZES": 2}
    bad = [f"{k}: C {defs.get(k)} != Python {v}" for k, v in want.items() if defs.get(k) != v]
    if struct.pack("<I", REQ_MAGIC) != b"PETH" or struct.pack("<I", RSP_MAGIC) != b"PETR":
        bad.append("magic bytes")
    if HDR_SIZE != 32:
        bad.append(f"header size {HDR_SIZE}")
    sys.path.insert(0, str(REPO))
    from model import job as J
    if J.RESULT_SIZE != RESULT_SIZE:
        bad.append(f"result size {J.RESULT_SIZE} != {RESULT_SIZE}")
    print("ETH_LINK SELFTEST " + ("PASS" if not bad else "FAIL: " + "; ".join(bad)))
    return 0 if not bad else 1


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    print(__doc__)
