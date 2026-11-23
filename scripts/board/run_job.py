"""Run one gray/Bayer A job through the ARM application (steps 4.2 / 5.3).

    --mode bayer_a --rev d selects the separate Option A Rev D bundle; input is raw RGGB.
    Named Bayer images use data/gen/rggb_<name>_<W>x<H>.raw (e.g. chart).

    python scripts/board/run_job.py <image> <transform> <W> <H> [options]
    python scripts/board/run_job.py mixed identity 64 64 --load     program the board, start the application, run the job
    python scripts/board/run_job.py photo rot15 480 272             the application is already running
    python scripts/board/run_job.py photo rot15 480 272 --n 10      ten frames, for timing
    python scripts/board/run_job.py mixed identity 64 64 --poll     the application polls STATUS, no interrupt
    python scripts/board/run_job.py mixed rot15 128 96 --dry-run    prints every XSDB command, needs no board
    python scripts/board/run_job.py photo rot15 480 272 --sw        the ARM software baseline runs the frame (step 4.4)

<image> and <transform> as in run_frame.py. The source goes to 0x1000_0000 and the output area (0x1800_0000) is filled with
0xA5 first. run_job_xsdb.tcl writes the job descriptor, polls the result record until its sequence number matches, and
reads the result and the output. With N > 1 the output compared is that of the last frame. The run folder is
build/board/job_<image>_<transform>_<W>x<H>/.

xsdb can exit with code 0 after a failure, so only its "run_job: DONE" line counts, and any "BOARD ERROR" is a failure.
The last line is JOB PASS, JOB FAIL: <reasons> or JOB ERROR: <reason>. Exit code 0 / 1 / 2 in that order.
"""
import argparse
import math
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import run_frame as RF                       # noqa: E402
from run_frame import FrameError, hex32, HW_DIR, MM, R, J   # noqa: E402

XSDB_TCL = HERE / "run_job_xsdb.tcl"
APP_WAIT_S = 15                              # application start, or an answer from one already running
RESULT_MARGIN_S = 10                         # on top of N x the frame timeout


def write_job_tcl(f):
    src = f["src_bytes"]
    words = " ".join(hex32(w) for w in J.record_words(f["descriptor"]))
    lines = [
        ("bit", "{" + Path(f["bit"]).as_posix() + "}"), ("init", "{" + Path(f["init"]).as_posix() + "}"),
        ("elf", "{" + Path(f["elf"]).as_posix() + "}"), ("src_file", "{" + f["src_file"].as_posix() + "}"),
        ("out_file", "{" + f["out_file"].as_posix() + "}"), ("result_file", "{" + f["result_file"].as_posix() + "}"),
        ("w", f["W"]), ("h", f["H"]), ("repeat", f["repeat"]), ("timeout_s", f["timeout"]), ("app_wait_s", APP_WAIT_S),
        ("src_addr", hex32(J.SRC_DEFAULT)), ("src_words", len(src) // 4), ("dst_addr", hex32(J.DST_DEFAULT)),
        ("src_first", hex32(int.from_bytes(src[:4], "little"))),
        ("src_last_addr", hex32(J.SRC_DEFAULT + len(src) - 4)),
        ("src_last", hex32(int.from_bytes(src[-4:], "little"))),
        ("fill_word", hex32(RF.FILL_BYTE * 0x0101_0101)), ("out_words", f["out_bytes"] // 4),
        ("out_last_addr", hex32(J.DST_DEFAULT + f["out_bytes"] - 4)),
        ("job_addr", hex32(J.JOB_ADDR)), ("job_words", J.JOB_SIZE // 4), ("job_magic", hex32(J.JOB_MAGIC)),
        ("result_addr", hex32(J.RESULT_ADDR)), ("result_words", J.RESULT_SIZE // 4),
        ("result_magic", hex32(J.RESULT_MAGIC)), ("layout", J.LAYOUT_VERSION), ("desc_words", "{" + words + "}"),
    ]
    f["job_file"].write_text("".join(f"set job({k}) {v}\n" for k, v in lines), newline="\n")


def run_prefix(sw, link, mode="gray"):
    """Run folder prefix under build/board/ (run_all.py reads result.bin from there): jobsw / job / job_bayer_a,
    plus _eth over Ethernet."""
    base = "jobsw" if sw else ("job" if mode == "gray" else f"job_{mode}")
    return base + ("_eth" if link == "eth" else "")


def prepare(a):
    mode = getattr(a, "mode", "gray")
    if a.sw and mode != "gray":
        raise J.JobError("the ARM software baseline is grayscale only")
    a.timeout = math.ceil(a.n * a.timeout_ms / 1000) + RESULT_MARGIN_S
    a.link = getattr(a, "link", "jtag")              # callers that build their own Namespace (model/test_bayer_jobs.py)
    eth = a.link == "eth"
    # a software job does not use the engine or its interrupt; over Ethernet the engine is polled (lwIP owns the GIC)
    irq = not (a.poll or a.sw or eth)
    f = RF.load_frame(a, irq_en=1 if irq else 0, prefix=run_prefix(a.sw, a.link, mode))
    f.update(repeat=a.n, irq=irq, sw=a.sw, elf=a.elf, result_file=f["run_dir"] / "result.bin", link=a.link,
             descriptor=J.encode_job(1, a.W, a.H, mode, f["b"], RF.BLOCK_LEN, repeat=a.n, timeout_ms=a.timeout_ms,
                                     irq=irq, src_by_cpu=eth, block_len_max=MM.BLOCK_LEN_MAX, sw=a.sw))
    if not eth:
        write_job_tcl(f)
    return f


def run_eth(f, a):
    """Step 10.2: the job over Ethernet (scripts/eth/eth_link.py). Writes result.bin and readback.bin like the XSDB
    path, plus eth_times.json. Returns the job's sequence number."""
    import json
    sys.path.insert(0, str(HERE.parent / "eth"))
    import eth_link as EL
    if a.load:
        print(f"run_job: loading {a.bit}, {a.elf} (Ethernet application)")
        # the Bayer A bundle has the build.tcl MDIO fix: check it instead of patching the pins (step 10.4)
        EL.load_board(a.bit, a.init, a.elf, mdio="check" if "bayer_a" in Path(a.bit).as_posix() else "fix")
        print(f"run_job: job port reachable after {EL.wait_ready(a.ip):.1f} s")
    with EL.JobLink(a.ip, timeout=a.timeout + 30) as link:
        rsp, result, out, t = link.run(f["descriptor"], f["src_bytes"], f["out_bytes"], fill=True)
    if rsp["status"] != 0:
        raise FrameError(f"the board rejected the request: {rsp['status_name']}")
    f["result_file"].write_bytes(result)
    f["out_file"].write_bytes(out)
    times = dict(board_rx_ms=rsp["rx_us"] / 1e3, board_job_ms=rsp["job_us"] / 1e3, pc_send_ms=1e3 * t["send_s"],
                 pc_until_response_ms=1e3 * t["until_response_s"], pc_download_ms=1e3 * t["download_s"],
                 pc_round_trip_ms=1e3 * t["round_trip_s"], src_bytes=len(f["src_bytes"]), out_bytes=len(out))
    (f["run_dir"] / "eth_times.json").write_text(json.dumps(times, indent=1), encoding="utf-8")
    print(f"ethernet       source {len(f['src_bytes'])} B received by the board in {times['board_rx_ms']:.2f} ms; "
          f"job on the board {times['board_job_ms']:.2f} ms; output {len(out)} B downloaded in "
          f"{times['pc_download_ms']:.2f} ms; PC round trip {times['pc_round_trip_ms']:.2f} ms")
    return J.decode_job(f["descriptor"])["seq"]


def us(ns):
    return ns / 1000


def report(f, seq):
    """Print the result; returns the list of failure reasons."""
    path = f["result_file"]
    if not path.is_file():
        raise FrameError(f"result file {path} is missing")
    r = J.decode_result(path.read_bytes())
    W, H, n = f["W"], f["H"], f["repeat"]
    fails = []
    print("\n--- result")
    print(f"sequence       job {seq}, result {r['seq']}")
    if r["seq"] != seq:
        fails.append(f"result is for job {r['seq']}, not {seq}")
    print(f"result code    {r['rc']} ({r['rc_name']})")
    if f["sw"]:
        print("path           ARM software baseline (flags bit 2), not the engine")
    else:
        print(f"wait mode      {'interrupt' if r['flags'] & J.JOB_FLAG_IRQ_EN else 'polling'}")
    if r["flags"] != J.decode_job(f["descriptor"])["flags"]:
        fails.append(f"result flags 0x{r['flags']:X} differ from the job's")
    print(f"BUILD_ID       0x{r['build_id']:08X}")
    expected_id = f["build_id"]
    # The Option A build also supports gray jobs; accept either known build for a gray job.
    valid_ids = (expected_id,) if f["mode"] != "gray" else (expected_id, 0x00403101)
    if r["build_id"] not in valid_ids:
        fails.append(f"BUILD_ID 0x{r['build_id']:08X} does not support the requested {f['mode']} build")
    print(f"STATUS at DONE {RF.status_text(r['status'])}")
    print(f"frames         {r['runs']} of {n} completed")
    print(f"interrupts     {r['irq_count']} handled since the application started, {r['irq_spurious']} without DONE")
    if r["rc"] != J.RC["OK"]:
        print(f"CYCLES         {r['cycles']}, RD_STALL {r['rd_stall']}, WR_STALL {r['wr_stall']} (at the failure)")
        fails.append(f"the application reports {r['rc_name']} after {r['runs']} of {n} frames")
        return fails                                # the output of a failed job says nothing
    if f["sw"]:
        # the software path leaves every engine field 0; anything else means the ELF ignored the SW flag
        if r["status"] or r["cycles"] or r["bytes_rd"] or r["bytes_wr"]:
            fails.append("engine counters are not 0: the application ran the engine, not the software "
                         "baseline (an ELF from before step 4.4?)")
        if r["runs"] != n:
            fails.append(f"{r['runs']} of {n} frames completed")
    else:
        st = R.unpack("STATUS", r["status"])
        if not st["DONE"] or st["BUSY"] or st["ERROR"]:
            fails.append("STATUS at the end of the frame is not DONE alone")
        if r["runs"] != n:
            fails.append(f"{r['runs']} of {n} frames completed")
        if f["irq"] and r["irq_count"] < n:
            fails.append(f"{r['irq_count']} interrupts handled, the job needs {n}")

        print(f"CYCLES         {r['cycles']}  ({1e6 * r['cycles'] / RF.PL_CLOCK_HZ:.1f} us at 100 MHz); "
              f"over N = {r['runs']}: min {r['cycles_min']}, avg {r['cycles_avg']}, max {r['cycles_max']}")
        RF.check_bytes(f, r["bytes_rd"], r["bytes_wr"], fails)
        print(f"RD_STALL       {r['rd_stall']}")
        print(f"WR_STALL       {r['wr_stall']}")
    RF.check_output(f, fails)

    print(f"timer          {r['timer_hz']} Hz")
    for name, key in ((("software warp" if f["sw"] else "engine time"), "engine"), ("end-to-end", "total")):
        print(f"{name:<14} min {us(r[key + '_ns_min']):.3f} us, avg {us(r[key + '_ns_avg']):.3f} us, "
              f"max {us(r[key + '_ns_max']):.3f} us")
    if r["engine_ns_avg"] and r["total_ns_avg"]:
        engine_s, total_s = r["engine_ns_avg"] / 1e9, r["total_ns_avg"] / 1e9
        what = "software warp time" if f["sw"] else "engine time"
        print(f"throughput     {W * H / engine_s / 1e6:.2f} Mpix/s ({what}, average)")
        print(f"frame rate     {1 / engine_s:.1f} fps from {what}, {1 / total_s:.1f} fps end to end")
    else:
        fails.append("the application reported a time of 0")
    return fails


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image")
    ap.add_argument("transform")
    ap.add_argument("W", type=int)
    ap.add_argument("H", type=int)
    ap.add_argument("--rev", choices=("c", "d"), default=None, help="select board bundle; default remains Rev C")
    ap.add_argument("--mode", choices=("gray", "bayer_a"), default="gray")
    ap.add_argument("--n", type=int, default=1, help="frames to run (N > 1 for timing)")
    ap.add_argument("--poll", action="store_true", help="the application polls STATUS (IRQ_EN = 0)")
    ap.add_argument("--load", action="store_true", help="program the bitstream, set up the PS, load and start the ELF")
    ap.add_argument("--sw", action="store_true", help="run the frame with the ARM software baseline (step 4.4)")
    ap.add_argument("--dry-run", action="store_true", help="print every XSDB command, touch no board")
    ap.add_argument("--timeout-ms", type=int, default=J.JOB_TIMEOUT_MS_DEFAULT, help="DONE timeout per frame, on the ARM")
    ap.add_argument("--bit", default=None, help="bitstream for --load")
    ap.add_argument("--init", default=None, help="ps7_init script for --load")
    ap.add_argument("--elf", default=None,
                    help="application for --load (default: patrm_app.elf of the bundle; with --link eth patrm_eth.elf of the bundle)")
    ap.add_argument("--link", choices=("jtag", "eth"), default="jtag",
                    help="jtag: XSDB mailbox (step 4.2); eth: Ethernet job service (step 10.2, engine polled)")
    ap.add_argument("--ip", default="192.168.1.10", help="board address for --link eth")
    a = ap.parse_args(argv)
    bundle = (HW_DIR / "bayer_a" / f"rev_{a.rev or 'c'}") if a.mode == "bayer_a" else (HW_DIR / "rev D" if a.rev == "d" else HW_DIR)
    a.bit = a.bit or str(bundle / f"patrm_{a.mode}.bit")
    a.init = a.init or str(bundle / "ps7_init.tcl")
    if a.link == "eth":
        a.elf = a.elf or str((bundle if a.mode == "bayer_a" else HW_DIR) / "patrm_eth.elf")
    else:
        a.elf = a.elf or str((bundle if a.mode == "bayer_a" else HW_DIR) / "patrm_app.elf")
    try:
        if a.link == "eth" and a.dry_run:
            raise FrameError("--dry-run is for the XSDB path only")
        f = prepare(a)
        print(f"run_job: image {f['image']}")
        print(f"run_job: transform {a.transform}, {a.W} x {a.H}, b = {f['b']}")
        wait = "ARM software baseline" if a.sw else ("polling" if not f["irq"] else "interrupt")
        print(f"run_job: N = {a.n}, BLOCK_LEN {RF.BLOCK_LEN}, {wait}, link {a.link}, "
              f"mode {f['mode']}, predicted BYTES_RD {f['bytes_rd']}, BYTES_WR {f['bytes_wr']}")
        f["out_file"].unlink(missing_ok=True)
        f["result_file"].unlink(missing_ok=True)
        start = time.time()
        if a.link == "eth":
            seq = run_eth(f, a)
        else:
            flags = (["--dry-run"] if a.dry_run else []) + (["--load"] if a.load else [])
            values = RF.parse_xsdb(RF.run_xsdb(f, flags, XSDB_TCL), a.dry_run, tag="run_job")
            if a.dry_run:
                print("JOB DRY RUN OK: nothing was done on a board")
                return RF.EXIT_PASS
            if "SEQ" not in values:
                raise FrameError("XSDB output has no value for SEQ")
            seq = values["SEQ"]
        fails = report(f, seq)
        print(f"run time       {time.time() - start:.0f} s")
    except Exception as e:                       # FrameError, JobError, LinkError, OSError, ValueError, ...
        if isinstance(e, (KeyboardInterrupt, SystemExit)):
            raise
        print(f"JOB ERROR: {e}")
        return RF.EXIT_ERROR
    if fails:
        print("JOB FAIL: " + "; ".join(fails))
        return RF.EXIT_FAIL
    print("JOB PASS")
    return RF.EXIT_PASS


if __name__ == "__main__":
    sys.exit(main())
