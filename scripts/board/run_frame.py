"""Run one grayscale frame on the ZedBoard with XSDB only, no ARM program, and compare it with the model (step 4.2a).

    python scripts/board/run_frame.py <image> <transform> <W> <H> [options]
    python scripts/board/run_frame.py mixed identity 64 64
    python scripts/board/run_frame.py photo rot15 480 272
    python scripts/board/run_frame.py mixed rot15 128 96 --dry-run      prints every XSDB command, needs no board

<image> is a raw GRAY8 file of W x H bytes, or a name from data/gen (gray_<name>_<W>x<H>.raw; a unique start of the
name is enough, so "photo" works). <transform> is a name from the transform list (model/gen_transforms.py).

The model gives the source file, the register values (SRC 0x1000_0000, DST 0x1800_0000, BLOCK_LEN 64, IRQ_EN = 0), the
expected frame and the BYTES_RD prediction. run_frame_xsdb.tcl does the board work. Before START the output area is
filled with 0xA5, so bytes the engine never wrote are seen as such. The run folder is
build/board/frame_<image>_<transform>_<W>x<H>/ (source.raw, expected.raw, output.raw, job.tcl, xsdb.log).

xsdb can exit with code 0 after a failure, so only its "run_frame: DONE" line counts, and any "BOARD ERROR" is a failure.
The last line is FRAME PASS, FRAME FAIL: <reasons> or FRAME ERROR: <reason>. Exit code 0 / 1 / 2 in that order.
"""
import argparse
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))

from amd_tools import require_tool           # noqa: E402
from model import job as J                   # noqa: E402
from model import memmodel as MM             # noqa: E402
from model import patrm as P                 # noqa: E402
from model import regs as R                  # noqa: E402
from model.gen_transforms import load as load_transforms   # noqa: E402

EXIT_PASS, EXIT_FAIL, EXIT_ERROR = 0, 1, 2
XSDB_TCL = Path(__file__).resolve().parent / "run_frame_xsdb.tcl"
GEN_DIR = ROOT / "data" / "gen"
RUN_ROOT = ROOT / "build" / "board"
HW_DIR = ROOT / "results" / "hw"
REG_BASE = J.REG_BASE                        # spec/memory_map.md section 2
BUILD_ID_EXPECTED = 0x0040_1001
BLOCK_LEN = 64                               # driver default (D15)
FILL_BYTE = 0xA5
GUARD_BYTES = 4096                           # filled and checked after the output image
COUNTERS = ("CYCLES", "BYTES_RD", "BYTES_WR", "RD_STALL", "WR_STALL")
PL_CLOCK_HZ = 100_000_000                    # D8
VALUE_RE = re.compile(r"^VALUE (\w+) 0x([0-9A-Fa-f]{8})\s*$")
ERR_NAME = {v: k for k, v in R.ERR.items()}


class FrameError(Exception):
    pass


def find_image(image, W, H):
    path = Path(image)
    if path.is_file():
        return path, path.stem
    exact = GEN_DIR / f"gray_{image}_{W}x{H}.raw"
    if exact.is_file():
        return exact, image
    found = sorted(GEN_DIR.glob(f"gray_{image}*_{W}x{H}.raw"))
    if len(found) == 1:
        return found[0], found[0].name[len("gray_"):-len(f"_{W}x{H}.raw")]
    if found:
        raise FrameError(f"image {image!r} is ambiguous at {W}x{H}: " + ", ".join(p.name for p in found))
    raise FrameError(f"no image {image!r} at {W}x{H}: not a file and not in {GEN_DIR} (run python -m model.gen_images)")


def find_transform(name):
    transforms = {t["name"]: t for t in load_transforms()}
    if name not in transforms:
        raise FrameError(f"unknown transform {name!r}; choose from {', '.join(transforms)}")
    return transforms[name]


def predict_bytes_rd(W, H, b):
    ps = MM.build_passes("gray", W, H, b)[0]
    return MM.pass_reads(ps, MM.make_blocks(ps, BLOCK_LEN, MM.SPAN_MAX), W, "P1")["beats"] * MM.BEAT


def hex32(value):
    return f"0x{value & 0xFFFFFFFF:08X}"


def status_mask(*names):
    return R.pack("STATUS", **{n: 1 for n in names})


def write_job_tcl(path, f):
    """The job as Tcl. Every number the XSDB script uses comes from here."""
    reg = lambda name: hex32(REG_BASE + R.OFFSET[name])            # noqa: E731
    regs = " ".join("{" + f"{hex32(REG_BASE + off)} {hex32(val)} {name}" + "}" for off, name, val in f["writes"][:-1])
    counters = " ".join(f"{name} {reg(name)}" for name in COUNTERS)
    src = f["src_bytes"]
    lines = [
        ("bit", "{" + Path(f["bit"]).as_posix() + "}"), ("init", "{" + Path(f["init"]).as_posix() + "}"),
        ("src_file", "{" + f["src_file"].as_posix() + "}"), ("out_file", "{" + f["out_file"].as_posix() + "}"),
        ("w", f["W"]), ("h", f["H"]), ("timeout_s", f["timeout"]),
        ("src_addr", hex32(J.SRC_DEFAULT)), ("dst_addr", hex32(J.DST_DEFAULT)),
        ("src_first", hex32(int.from_bytes(src[:4], "little"))),
        ("src_last_addr", hex32(J.SRC_DEFAULT + len(src) - 4)),
        ("src_last", hex32(int.from_bytes(src[-4:], "little"))),
        ("fill_word", hex32(FILL_BYTE * 0x0101_0101)), ("out_words", f["out_bytes"] // 4),
        ("out_last_addr", hex32(J.DST_DEFAULT + f["out_bytes"] - 4)),
        ("build_id", hex32(BUILD_ID_EXPECTED)), ("reg_build_id", reg("BUILD_ID")),
        ("reg_status", reg("STATUS")), ("reg_ctrl", reg("CTRL")), ("start_value", hex32(f["writes"][-1][2])),
        ("busy_mask", hex32(status_mask("BUSY"))), ("done_mask", hex32(status_mask("DONE"))),
        ("error_mask", hex32(status_mask("ERROR"))), ("clear_mask", hex32(status_mask("DONE", "ERROR"))),
        ("counters", "{" + counters + "}"), ("regs", "{" + regs + "}"),
    ]
    path.write_text("".join(f"set job({k}) {v}\n" for k, v in lines), newline="\n")


def load_frame(a, irq_en=0, prefix="frame"):
    """Everything both runners need for one frame: source, transform, register values, model output, run folder."""
    W, H = a.W, a.H
    J.check_regs_current()
    image_path, image_name = find_image(a.image, W, H)
    tf = find_transform(a.transform)
    src_bytes = image_path.read_bytes()
    if len(src_bytes) != W * H:
        raise FrameError(f"{image_path} has {len(src_bytes)} bytes, expected W x H = {W * H}")
    b = tuple(int(c) for c in MM._b_for(tf, W, H))
    writes, _ = J.register_image(W, H, "gray", b, BLOCK_LEN, irq_en=irq_en, block_len_max=MM.BLOCK_LEN_MAX)
    if writes[-1][1] != "CTRL":
        raise FrameError("model/job.py: CTRL must be the last register written")
    src = np.frombuffer(src_bytes, dtype=np.uint8).reshape(H, W)
    expected = P.warp_gray(src, W, H, b)

    run_dir = RUN_ROOT / f"{prefix}_{image_name}_{tf['name']}_{W}x{H}"
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "source.raw").write_bytes(src_bytes)
    (run_dir / "expected.raw").write_bytes(expected.tobytes())
    return dict(W=W, H=H, b=b, writes=writes, src_bytes=src_bytes, expected=expected, image=image_path,
                run_dir=run_dir, src_file=run_dir / "source.raw", out_file=run_dir / "readback.bin",
                out_bytes=W * H + GUARD_BYTES, bit=a.bit, init=a.init, timeout=a.timeout,
                bytes_rd=predict_bytes_rd(W, H, b), job_file=run_dir / "job.tcl")


def prepare(a):
    f = load_frame(a)
    write_job_tcl(f["job_file"], f)
    return f


def run_xsdb(f, flags, tcl=None):
    """Run an XSDB script with the given flags and the job file. Shows the output and keeps it in xsdb.log.
    Returns the output lines; a hung XSDB is stopped."""
    xsdb = require_tool("xsdb")
    cmd = ["cmd", "/c", str(xsdb)] if xsdb.suffix.lower() in (".bat", ".cmd") else [str(xsdb)]
    cmd.append(Path(tcl or XSDB_TCL).as_posix())
    cmd += flags
    cmd.append(f["job_file"].as_posix())
    # generous upper bound for bitstream, JTAG transfers and the frame; the Tcl script has its own frame timeout
    limit_s = 600 + f["timeout"] + 120 * 2 * f["out_bytes"] / 1048576
    p = subprocess.Popen(cmd, cwd=ROOT, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, errors="replace")
    expired = []

    def stop():
        expired.append(True)
        subprocess.run(["taskkill", "/F", "/T", "/PID", str(p.pid)], capture_output=True)
    timer = threading.Timer(limit_s, stop)
    timer.start()
    lines = []
    with open(f["run_dir"] / "xsdb.log", "w") as log:
        for line in p.stdout:
            line = line.rstrip()
            lines.append(line)
            log.write(line + "\n")
            print(line, flush=True)
    p.wait()
    timer.cancel()
    if expired:
        raise FrameError(f"XSDB did not finish within {limit_s:.0f} s and was stopped")
    return lines


def parse_xsdb(lines, dry_run, tag="run_frame"):
    """Values printed by the Tcl script. Raises FrameError unless the run reached its success line."""
    errors = [ln.strip() for ln in lines if "BOARD ERROR" in ln]
    if errors:
        raise FrameError(errors[0])
    want = f"{tag}: DRY RUN OK, nothing was done" if dry_run else f"{tag}: DONE"
    if not any(ln.strip() == want for ln in lines):
        tail = next((ln.strip() for ln in reversed(lines) if ln.strip()), "no output")
        raise FrameError(f"XSDB ended without '{want}'; last line: {tail}")
    values = {}
    for ln in lines:
        m = VALUE_RE.match(ln.strip())
        if m:
            values[m.group(1)] = int(m.group(2), 16)
    return values


def compare_frame(got, exp):
    """Row-by-row comparison of two H x W arrays, including the last row and the bytes still holding the fill."""
    diff = got != exp
    rows = diff.any(axis=1)
    stale = diff & (got == FILL_BYTE)
    r = dict(rows=int(rows.sum()), bytes=int(diff.sum()), stale=int(stale.sum()), first=None,
             last_bytes=int(diff[-1].sum()), last_stale=int(stale[-1].sum()),
             last_all_fill=bool((got[-1] == FILL_BYTE).all()))
    if r["bytes"]:
        row = int(np.argmax(rows))
        col = int(np.argmax(diff[row]))
        r["first"] = (row, col, int(got[row, col]), int(exp[row, col]))
    return r


def status_text(value):
    s = R.unpack("STATUS", value)
    name = ERR_NAME.get(s["ERR_CODE"], "unknown")
    return (f"0x{value:08X}: BUSY={s['BUSY']} DONE={s['DONE']} ERROR={s['ERROR']} "
            f"ERR_CODE={s['ERR_CODE']} ({name})")


def check_bytes(f, bytes_rd, bytes_wr, fails):
    """BYTES_RD against the memory model and BYTES_WR against W x H."""
    for name, got_v, ref, what in (("BYTES_RD", bytes_rd, f["bytes_rd"], "memmodel"),
                                   ("BYTES_WR", bytes_wr, f["W"] * f["H"], "W x H")):
        same = got_v == ref
        print(f"{name:<14} {got_v}  ({what} {ref}: {'same' if same else 'DIFFERENT'})")
        if not same:
            fails.append(f"{name} {got_v} != {what} {ref}")


def check_output(f, fails):
    """Compare the read-back output with the model row by row, including the last row and the guard bytes."""
    W, H = f["W"], f["H"]
    if not f["out_file"].is_file() or f["out_file"].stat().st_size != f["out_bytes"]:
        raise FrameError(f"read-back file {f['out_file']} is missing or does not have {f['out_bytes']} bytes")
    data = np.frombuffer(f["out_file"].read_bytes(), dtype=np.uint8)
    got = data[:W * H].reshape(H, W)
    guard = data[W * H:]
    (f["run_dir"] / "output.raw").write_bytes(got.tobytes())

    c = compare_frame(got, f["expected"])
    print(f"differing rows {c['rows']} of {H}")
    print(f"differing bytes {c['bytes']} of {W * H}  ({c['stale']} of them still hold the 0x{FILL_BYTE:02X} fill)")
    if c["first"]:
        row, col, g, e = c["first"]
        print(f"first mismatch row {row}, column {col}: read 0x{g:02X}, model 0x{e:02X}")
        fails.append(f"{c['bytes']} bytes in {c['rows']} rows differ, first at row {row}, column {col}")
    else:
        print("first mismatch none")
    if c["last_bytes"] == 0:
        print(f"LAST ROW (row {H - 1}): MATCHES the model")
    else:
        note = "never written, all 0xA5" if c["last_all_fill"] else f"{c['last_stale']} bytes still hold the fill"
        print(f"LAST ROW (row {H - 1}): DOES NOT MATCH, {c['last_bytes']} of {W} bytes differ ({note})")
        fails.append("the last row does not match")
    changed = int((guard != FILL_BYTE).sum())
    print(f"after the image {changed} of {GUARD_BYTES} guard bytes changed")
    if changed:
        fails.append(f"{changed} bytes after the output image changed")
    print(f"files          {f['run_dir']}")


def report(f, v):
    """Print the result; returns the list of failure reasons."""
    fails = []
    missing = [n for n in ("BUILD_ID", "STATUS_AT_DONE", "STATUS_AFTER_CLEAR") + COUNTERS if n not in v]
    if missing:
        raise FrameError("XSDB output has no value for " + ", ".join(missing))
    if not f["out_file"].is_file() or f["out_file"].stat().st_size != f["out_bytes"]:
        raise FrameError(f"read-back file {f['out_file']} is missing or does not have {f['out_bytes']} bytes")

    print("\n--- result")
    print(f"BUILD_ID       0x{v['BUILD_ID']:08X}")
    print(f"STATUS at DONE {status_text(v['STATUS_AT_DONE'])}")
    print(f"STATUS cleared {status_text(v['STATUS_AFTER_CLEAR'])}")
    st = R.unpack("STATUS", v["STATUS_AT_DONE"])
    if not st["DONE"] or st["BUSY"] or st["ERROR"]:
        fails.append("STATUS at the end of the frame is not DONE alone")
    if R.unpack("STATUS", v["STATUS_AFTER_CLEAR"])["DONE"]:
        fails.append("DONE did not clear")

    print(f"CYCLES         {v['CYCLES']}  ({1e3 * v['CYCLES'] / PL_CLOCK_HZ:.3f} ms at 100 MHz)")
    check_bytes(f, v["BYTES_RD"], v["BYTES_WR"], fails)
    print(f"RD_STALL       {v['RD_STALL']}")
    print(f"WR_STALL       {v['WR_STALL']}")

    check_output(f, fails)
    return fails


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image")
    ap.add_argument("transform")
    ap.add_argument("W", type=int)
    ap.add_argument("H", type=int)
    ap.add_argument("--dry-run", action="store_true", help="print every XSDB command, touch no board")
    ap.add_argument("--no-program", action="store_true", help="keep the loaded bitstream and PS setup (ILA debugging)")
    ap.add_argument("--bit", default=str(HW_DIR / "patrm_gray.bit"), help="bitstream to program")
    ap.add_argument("--init", default=str(HW_DIR / "ps7_init.tcl"), help="ps7_init script from the XSA")
    ap.add_argument("--timeout", type=int, default=10, help="seconds to wait for DONE")
    a = ap.parse_args(argv)
    try:
        f = prepare(a)
        print(f"run_frame: image {f['image']}")
        print(f"run_frame: transform {a.transform}, {a.W} x {a.H}, b = {f['b']}")
        print(f"run_frame: BLOCK_LEN {BLOCK_LEN}, IRQ_EN 0, predicted BYTES_RD {f['bytes_rd']}, BYTES_WR {a.W * a.H}")
        f["out_file"].unlink(missing_ok=True)
        start = time.time()
        flags = (["--dry-run"] if a.dry_run else []) + (["--no-program"] if a.no_program else [])
        values = parse_xsdb(run_xsdb(f, flags), a.dry_run)
        if a.dry_run:
            print("FRAME DRY RUN OK: nothing was done on a board")
            return EXIT_PASS
        fails = report(f, values)
        print(f"run time       {time.time() - start:.0f} s")
    except (FrameError, J.JobError, ValueError, OSError) as e:
        print(f"FRAME ERROR: {e}")
        return EXIT_ERROR
    if fails:
        print("FRAME FAIL: " + "; ".join(fails))
        return EXIT_FAIL
    print("FRAME PASS")
    return EXIT_PASS


if __name__ == "__main__":
    sys.exit(main())
