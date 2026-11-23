"""Step 10.1: Ethernet echo throughput, PC <-> ZedBoard, next to USB-JTAG measured in the same session.

    python scripts/eth/echo_test.py --load            program the board (Rev D bundle), load the echo ELF, then test
    python scripts/eth/echo_test.py                   board already running the echo server
    python scripts/eth/echo_test.py --no-jtag         skip the JTAG comparison

Board: sw/patrm_eth/echo.c (flow-controlled TCP echo, port 7), built by `vitis -s sw/patrm_eth/build_vitis.py`. With no
DHCP server it takes 192.168.1.10 after about 12 s. Laptop: static 192.168.1.100/24 on the Ethernet adapter.

Tests (--tests, default all three), for 1 MB and 5 MB, 10 runs each (1 MB = 2^20 bytes):
  echo    port 7: one thread sends N random bytes while the main thread receives the echo; pass = identical. Both
          directions carry N bytes at the same time: MB/s each direction = N / T (first byte sent -> last echo byte).
  sink    port 5001, PC -> board: send N random bytes, close; the board replies with its byte count; pass = count N.
          MB/s = N / T (first byte sent -> count received, so every byte has reached the board).
  source  port 5002, board -> PC: ask for N bytes; pass = every byte equals the board's pattern. MB/s = N / T.

JTAG comparison (unless --no-jtag; the echo server is stopped by it): scripts/board/put_image.tcl and get_image.tcl move
the same 1 MB and 5 MB files to/from DDR 0x1000_0000 and must read back identical; their s/MB is printed.

GEM0 counters (scripts/eth/gem_stats.tcl) are cleared before and read after the echo runs; nonzero error counters are
reported (they explain stalls: each lost frame costs a TCP retransmission).

Results: results/eth/echo_<date>_<time>.csv and .txt. Last line: ECHO TEST PASS or ECHO TEST FAIL: <reason>.
"""
import argparse
import csv
import datetime as dt
import os
import random
import re
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
from amd_tools import require_tool           # noqa: E402

BOARD_IP = "192.168.1.10"
PORT = 7
SINK_PORT = 5001
SOURCE_PORT = 5002
MB = 1 << 20
REV_D = REPO / "results" / "hw" / "rev D"
ELF = REPO / "results" / "hw" / "patrm_eth_echo.elf"
OUT_DIR = REPO / "results" / "eth"
RUN_DIR = REPO / "build" / "eth"


class TestError(Exception):
    pass


def find_uart(port):
    import serial.tools.list_ports as lp
    if port:
        return port
    hits = [p.device for p in lp.comports() if p.vid == 0x04B4]      # Cypress USB-UART on the ZedBoard
    if len(hits) != 1:
        raise TestError(f"ZedBoard UART not found uniquely (Cypress VID 0x04B4): {hits}; use --uart COMx")
    return hits[0]


class Uart:
    """Collects the board's UART lines in the background."""

    def __init__(self, port):
        import serial
        self.ser = serial.Serial(port, 115200, timeout=0.2)
        self.lines = []
        self.t0 = time.time()
        self._stop = False
        self._t = threading.Thread(target=self._run, daemon=True)
        self._t.start()

    def _run(self):
        buf = b""
        while not self._stop:
            buf += self.ser.read(256)
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                text = line.decode("ascii", errors="replace").strip()
                if text:
                    self.lines.append(text)
                    print(f"  UART {time.time() - self.t0:6.1f} s| {text}")

    def wait_for(self, pattern, timeout):
        end = time.time() + timeout
        while time.time() < end:
            if any(re.search(pattern, ln) for ln in self.lines):
                return True
            time.sleep(0.1)
        return False

    def close(self):
        self._stop = True
        self._t.join(timeout=1)
        self.ser.close()


def run_xsdb(script, args, timeout=300):
    xsdb = require_tool("xsdb")
    cmd = ["cmd", "/c", str(xsdb)] if xsdb.suffix.lower() in (".bat", ".cmd") else [str(xsdb)]
    cmd += [Path(script).as_posix()] + [str(a) for a in args]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=REPO)
    out = (proc.stdout or "") + (proc.stderr or "")
    if "BOARD ERROR" in out:
        raise TestError(f"{Path(script).name}: " + [ln for ln in out.splitlines() if "BOARD ERROR" in ln][0])
    return out


def load_board():
    """Program, ps7_init, load the ELF halted; then route MDIO to MIO 52/53 (scripts/eth/mdio_mio.tcl: the Rev D XSA
    has MDIO on EMIO, so lwIP cannot reach the PHY) and start core 0."""
    print(f"loading: {REV_D / 'patrm_gray.bit'}, {ELF.name}")
    out = run_xsdb(REPO / "scripts" / "board" / "load_run.tcl",
                   ["--bit", REV_D / "patrm_gray.bit", "--init", REV_D / "ps7_init.tcl", "--elf", ELF, "--no-run"])
    if "load_run: DONE" not in out:
        raise TestError("load_run.tcl did not print 'load_run: DONE':\n" + out[-1500:])
    out = run_xsdb(REPO / "scripts" / "eth" / "mdio_mio.tcl", ["--con"])
    if "mdio_mio: DONE" not in out:
        raise TestError("mdio_mio.tcl did not print 'mdio_mio: DONE':\n" + out[-1500:])
    print("MDIO routed to MIO 52/53, core 0 started")


def gem_stats():
    """Read (and clear) the GEM0 counters over JTAG (scripts/eth/gem_stats.tcl); core 0 keeps running."""
    out = run_xsdb(REPO / "scripts" / "eth" / "gem_stats.tcl", [])
    if "gem_stats: DONE" not in out:
        raise TestError("gem_stats.tcl did not finish:\n" + out[-800:])
    return {k: int(v) for k, v in re.findall(r"^(\w+)\s+(\d+)\s*$", out, re.M)}


def ping(ip):
    proc = subprocess.run(["ping", "-n", "3", "-w", "1000", ip], capture_output=True, text=True)
    ok = "TTL=" in proc.stdout
    times = re.findall(r"time[=<](\d+)ms", proc.stdout)
    return ok, times


def echo_once(data, timeout=60.0):
    """Send data, receive the echo. Returns (echo bytes, total s, send-only s)."""
    s = socket.create_connection((BOARD_IP, PORT), timeout=10)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    s.settimeout(timeout)
    sent = {}

    def sender():
        t = time.perf_counter()
        s.sendall(data)
        sent["t"] = time.perf_counter() - t
        s.shutdown(socket.SHUT_WR)

    got = bytearray()
    t0 = time.perf_counter()
    th = threading.Thread(target=sender, daemon=True)
    th.start()
    try:
        while len(got) < len(data):
            chunk = s.recv(1 << 18)
            if not chunk:
                break
            got += chunk
        total = time.perf_counter() - t0
        # after the echo, the board closes its side: expect EOF
        while s.recv(1 << 16):
            pass
    finally:
        th.join(timeout=timeout)
        s.close()
    return bytes(got), total, sent.get("t", float("nan"))


def pattern_bytes(n):
    """Source pattern of sw/patrm_eth/echo.c: byte i = p[i % 65536], p[k] = (k*31 + (k >> 8)) & 0xFF."""
    k = np.arange(65536, dtype=np.uint32)
    p = ((k * 31 + (k >> 8)) & 0xFF).astype(np.uint8)
    return np.resize(p, n).tobytes()


def sink_once(data, timeout=60.0):
    """PC -> board: send data, close our side, the board answers with its byte count. Returns (count, s)."""
    s = socket.create_connection((BOARD_IP, SINK_PORT), timeout=10)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    s.settimeout(timeout)
    try:
        t0 = time.perf_counter()
        s.sendall(data)
        s.shutdown(socket.SHUT_WR)
        reply = b""
        while len(reply) < 8:
            chunk = s.recv(8 - len(reply))
            if not chunk:
                break
            reply += chunk
        total = time.perf_counter() - t0
    finally:
        s.close()
    count = int.from_bytes(reply, "little") if len(reply) == 8 else -1
    return count, total


def source_once(n, timeout=60.0):
    """board -> PC: ask for n bytes, receive them. Returns (bytes, s)."""
    s = socket.create_connection((BOARD_IP, SOURCE_PORT), timeout=10)
    s.settimeout(timeout)
    got = bytearray()
    try:
        t0 = time.perf_counter()
        s.sendall(n.to_bytes(4, "little"))
        s.shutdown(socket.SHUT_WR)
        while len(got) < n:
            chunk = s.recv(1 << 18)
            if not chunk:
                break
            got += chunk
        total = time.perf_counter() - t0
    finally:
        s.close()
    return bytes(got), total


def jtag_round_trip(size, seed):
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    src = RUN_DIR / f"jtag_{size // MB}MB.bin"
    back = RUN_DIR / f"jtag_{size // MB}MB_back.bin"
    src.write_bytes(random.Random(seed).randbytes(size))
    back.unlink(missing_ok=True)
    out_put = run_xsdb(REPO / "scripts" / "board" / "put_image.tcl", [src, "0x10000000"])
    out_get = run_xsdb(REPO / "scripts" / "board" / "get_image.tcl", ["0x10000000", size, back])
    t_put = re.search(r"put_image: DONE, \d+ bytes in ([\d.]+) s", out_put)
    t_get = re.search(r"get_image: DONE, \d+ bytes in ([\d.]+) s", out_get)
    if not (t_put and t_get):
        raise TestError(f"JTAG {size // MB} MB: put/get did not finish:\n{out_put[-600:]}\n{out_get[-600:]}")
    same = back.is_file() and back.read_bytes() == src.read_bytes()
    return float(t_put.group(1)), float(t_get.group(1)), same


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--load", action="store_true", help="program the FPGA and load the echo ELF first")
    ap.add_argument("--uart", default="", help="UART port (default: the ZedBoard's Cypress USB-UART)")
    ap.add_argument("--runs", type=int, default=10)
    ap.add_argument("--sizes", default="1,5", help="MB list (default 1,5)")
    ap.add_argument("--no-jtag", action="store_true")
    ap.add_argument("--tests", default="echo,sink,source",
                    help="echo (port 7), sink (PC->board, port 5001), source (board->PC, port 5002)")
    a = ap.parse_args(argv)
    sizes = [int(x) * MB for x in a.sizes.split(",")]
    rows, fails, lines = [], [], []

    def say(text):
        print(text)
        lines.append(text)

    uart = None
    try:
        uart = Uart(find_uart(a.uart))
        if a.load:
            if not ELF.is_file():
                raise TestError(f"{ELF} missing: vitis -s sw/patrm_eth/build_vitis.py")
            load_board()
            if not uart.wait_for(r"PATRM_ETH ECHO READY", 60):
                raise TestError("no 'PATRM_ETH ECHO READY' on the UART within 60 s")
        ok, times = ping(BOARD_IP)
        say(f"ping {BOARD_IP}: {'OK' if ok else 'NO REPLY'} {times} ms")
        if not ok:
            raise TestError(f"{BOARD_IP} does not answer ping (cable, laptop IP 192.168.1.100/24, board booted?)")

        for test in a.tests.split(","):
            gem_stats()                                  # clear the counters before this test
            for size in sizes:
                for run in range(1, a.runs + 1):
                    send_s = float("nan")
                    if test == "echo":
                        data = random.Random(size * 1000 + run).randbytes(size)
                        got, total, send_s = echo_once(data)
                        same = got == data
                        what = f"echo differs (got {len(got)} of {size} bytes)"
                        unit = "MB/s each direction"
                    elif test == "sink":
                        data = random.Random(size * 1000 + run).randbytes(size)
                        count, total = sink_once(data)
                        same = count == size
                        what = f"board counted {count} of {size} bytes"
                        unit = "MB/s PC->board"
                    elif test == "source":
                        got, total = source_once(size)
                        same = got == pattern_bytes(size)
                        what = f"pattern differs (got {len(got)} of {size} bytes)"
                        unit = "MB/s board->PC"
                    else:
                        raise TestError(f"unknown test {test} (echo, sink, source)")
                    if not same:
                        fails.append(f"{test} {size // MB} MB run {run}: {what}")
                    rate = size / MB / total
                    rows.append({"test": f"eth_{test}", "MB": size // MB, "run": run, "identical": int(same),
                                 "total_s": f"{total:.4f}", "MBps_each_direction": f"{rate:.2f}",
                                 "send_only_s": "" if send_s != send_s else f"{send_s:.4f}"})
                    say(f"{test} {size // MB} MB run {run:2d}: {'identical' if same else 'DIFFERENT'}  "
                        f"{total:.3f} s  {rate:.2f} {unit}")
            st = gem_stats()
            errs = {k: v for k, v in st.items() if k.endswith(("errors", "overruns", "underruns")) and v}
            say(f"GEM0 counters over the {test} runs: frames_tx {st.get('frames_tx')}; nonzero error counters: "
                f"{errs if errs else 'none'}")
            for size in sizes:
                ok_runs = [r for r in rows if r["test"] == f"eth_{test}" and r["MB"] == size // MB]
                rates = sorted(float(r["MBps_each_direction"]) for r in ok_runs)
                n_same = sum(r["identical"] for r in ok_runs)
                say(f"SUMMARY {test} {size // MB} MB: {n_same} of {len(ok_runs)} identical; MB/s "
                    f"min {rates[0]:.2f} median {rates[len(rates) // 2]:.2f} max {rates[-1]:.2f}")

        if not a.no_jtag:
            say("JTAG comparison (put_image / get_image, DDR 0x1000_0000; stops the echo server)")
            for size in sizes:
                t_put, t_get, same = jtag_round_trip(size, size)
                if not same:
                    fails.append(f"JTAG {size // MB} MB read back differs")
                rows.append({"test": "jtag_put", "MB": size // MB, "run": 1, "identical": int(same),
                             "total_s": f"{t_put:.3f}", "MBps_each_direction": f"{size / MB / t_put:.3f}",
                             "send_only_s": ""})
                rows.append({"test": "jtag_get", "MB": size // MB, "run": 1, "identical": int(same),
                             "total_s": f"{t_get:.3f}", "MBps_each_direction": f"{size / MB / t_get:.3f}",
                             "send_only_s": ""})
                say(f"JTAG {size // MB} MB: PC->DDR {t_put:.2f} s ({t_put / (size / MB):.2f} s/MB, "
                    f"{size / MB / t_put:.3f} MB/s), DDR->PC {t_get:.2f} s ({t_get / (size / MB):.2f} s/MB, "
                    f"{size / MB / t_get:.3f} MB/s), read back {'identical' if same else 'DIFFERENT'}")
    except (TestError, OSError, subprocess.TimeoutExpired) as e:
        fails.append(str(e))
    finally:
        if uart:
            time.sleep(0.5)
            uart.close()

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y-%m-%d_%H%M%S")
    if rows:
        with open(OUT_DIR / f"echo_{stamp}.csv", "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
    final = "ECHO TEST PASS" if not fails else "ECHO TEST FAIL: " + "; ".join(fails[:3])
    lines.append(final)
    (OUT_DIR / f"echo_{stamp}.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(final)
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
