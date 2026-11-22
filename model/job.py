"""Register image for one engine job (step 2.1), job descriptor and result record (step 4.2).

Given size, mode, transform and block length, check everything the hardware and the driver will check and
return the register values (offset -> 32-bit value), in the order the driver writes them. The C driver
(step 4.2) and the testbenches mirror this. Every value is packed through model/regs.py (generated from
spec/regs.json), so a value that does not fit its field is an error, and a stale model/regs.py is refused.

Checks: mode (MODE enum), size D3 + D11, transform D4 (Bayer: also every plane), BLOCK_LEN D13, buffer
placement and 4 KB alignment (spec/memory_map.md). T_p from model/bayer.py plane_shifts (D2, D12).

encode_job / decode_job and encode_result / decode_result are the PC side of the records exchanged with the ARM test
application (spec/memory_map.md section 5). JOB_FIELDS and RESULT_FIELDS are the one layout; model/test_job_layout.py
compiles it against sw/include/patrm_job.h with the ARM compiler.

Examples (repo root):
  python -m model.job --size 640x480 --mode bayer_a --b 52429 -39322 131072 39322 52429 65536 --block-len 16
  python -m model.job --size 1920x1080 --mode gray --rot 15 --block-len 32
"""

import argparse
import os
import struct
import sys

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from model import bayer as B          # noqa: E402
from model import patrm as P          # noqa: E402
from model import regs as R           # noqa: E402

# spec/memory_map.md section 1
DDR_END = 0x2000_0000                 # 512 MB
BUF_LO = 0x0F00_0000                  # buffers live above the program area ...
BUF_HI = 0x1F00_0000                  # ... and below the job descriptor / result areas
SRC_DEFAULT = 0x1000_0000
DST_DEFAULT = 0x1800_0000
REG_BASE = 0x43C0_0000                # section 2

# Job descriptor and result record (section 5). Same values as sw/include/patrm_job.h and patrm_defs.h.
JOB_ADDR = 0x1F00_0000
RESULT_ADDR = 0x1F00_1000
JOB_MAGIC = 0x424F_4A50               # "PJOB" in memory
RESULT_MAGIC = 0x5345_5250            # "PRES" in memory
LAYOUT_VERSION = 1
JOB_MAX_REPEAT = 10000
JOB_MAX_TIMEOUT_MS = 60000
JOB_TIMEOUT_MS_DEFAULT = 2000         # spec/memory_map.md section 4, step 9
JOB_FLAG_IRQ_EN = 0x1
JOB_FLAG_SRC_CPU = 0x2
JOB_FLAG_SW = 0x4                     # step 4.4: the ARM software baseline runs the frame, not the engine
JOB_FLAGS_KNOWN = JOB_FLAG_IRQ_EN | JOB_FLAG_SRC_CPU | JOB_FLAG_SW

# (field, struct format): little-endian, every field 32 bits wide
JOB_FIELDS = (("magic", "I"), ("seq", "I"), ("layout", "I"), ("mode", "I"), ("flags", "I"), ("width", "I"),
              ("height", "I"), ("block_len", "I"), ("src_addr", "I"), ("dst_addr", "I"), ("repeat", "I"),
              ("timeout_ms", "I"), ("b", "6i"), ("reserved", "6I"))
RESULT_FIELDS = (("magic", "I"), ("seq", "I"), ("layout", "I"), ("rc", "I"), ("status", "I"), ("runs", "I"),
                 ("flags", "I"), ("cycles", "I"), ("bytes_rd", "I"), ("bytes_wr", "I"), ("rd_stall", "I"),
                 ("wr_stall", "I"), ("cycles_min", "I"), ("cycles_avg", "I"), ("cycles_max", "I"),
                 ("engine_ns_min", "I"), ("engine_ns_avg", "I"), ("engine_ns_max", "I"),
                 ("total_ns_min", "I"), ("total_ns_avg", "I"), ("total_ns_max", "I"), ("timer_hz", "I"),
                 ("build_id", "I"), ("irq_count", "I"), ("irq_spurious", "I"), ("reserved", "7I"))
RC = {"OK": 0, "BAD_LAYOUT": 1, "BAD_JOB": 2, "BAD_SIZE": 3, "BAD_MODE": 4, "BAD_BLOCK_LEN": 5, "BAD_ADDR": 6,
      "BAD_TRANSFORM": 7, "BAD_BUILD_ID": 8, "BUSY": 9, "START_REJECTED": 10, "TIMEOUT": 11, "NO_INTERRUPT": 12,
      "BUS_ERROR": 13, "ENGINE_ERROR": 14, "IRQ_SETUP": 15, "NO_TIMER": 16}
RC_NAME = {v: k for k, v in RC.items()}

MODES = {"gray": R.MODE["GRAY"], "bayer_a": R.MODE["BAYER_A"], "bayer_b": R.MODE["BAYER_B"]}
MODE_NAME = {v: k for k, v in MODES.items()}
T_REGS = (("R", "T_R"), ("Gr", "T_GR"), ("Gb", "T_GB"), ("B", "T_B"))


class JobError(ValueError):
    pass


def check_regs_current():
    """Refuse to run with a model/regs.py that does not match spec/regs.json."""
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    sys.path.insert(0, os.path.join(here, "scripts"))
    try:
        import gen_regs
    finally:
        sys.path.pop(0)
    with open(gen_regs.OUT_PY, "rb") as f:
        # ignore CRLF vs LF (git core.autocrlf may convert on checkout)
        if f.read().replace(b"\r\n", b"\n") != gen_regs.gen_py(gen_regs.load()).encode("utf-8"):
            raise JobError("model/regs.py is out of date with spec/regs.json; run: python scripts/gen_regs.py")


def _mode(mode):
    if isinstance(mode, str):
        if mode.lower() not in MODES:
            raise JobError(f"mode must be one of {sorted(MODES)}, got {mode!r}")
        return MODES[mode.lower()]
    if mode not in MODE_NAME:
        raise JobError(f"mode must be one of {sorted(MODE_NAME)}, got {mode!r}")
    return mode


def _check_buffer(name, addr, size):
    if not isinstance(addr, int) or addr % R.ADDR_ALIGN:
        raise JobError(f"{name} = 0x{addr:08X} is not {R.ADDR_ALIGN}-byte (4 KB) aligned")
    if not (BUF_LO <= addr and addr + size <= BUF_HI):
        raise JobError(f"{name} buffer 0x{addr:08X}..0x{addr + size - 1:08X} is outside the buffer area "
                       f"0x{BUF_LO:08X}..0x{BUF_HI - 1:08X} (spec/memory_map.md)")


def register_image(W, H, mode, b, block_len, src=SRC_DEFAULT, dst=DST_DEFAULT, irq_en=1, block_len_max=None):
    """Return (writes, start) where writes is a list of (offset, name, value) in driver write order
    (configuration registers, then CTRL with START = 1 last) and start is the CTRL value.
    Raises JobError with a clear message if anything is invalid."""
    m = _mode(mode)
    bayer = m != R.MODE["GRAY"]

    # size: D11 then D3
    for n, v in (("W", W), ("H", H)):
        if not isinstance(v, int) or not 1 <= v <= R.MAX_SIZE:
            raise JobError(f"D11: {n} = {v} is outside 1..{R.MAX_SIZE} (W x H = {W}x{H})")
    try:
        P.check_size(W, H, "bayer" if bayer else "gray")
    except ValueError as e:
        raise JobError(str(e)) from None

    # transform: D4 (Bayer: full size and every plane) and T_p (D2, D12)
    b = tuple(int(c) for c in b)
    try:
        if bayer:
            B.check_bayer_transform(b, W, H)
            T = B.plane_shifts(b)
        else:
            P.check_transform(b, W, H)
            T = {p: (0, 0) for p, _ in T_REGS}
    except ValueError as e:
        raise JobError(str(e)) from None

    # BLOCK_LEN: D13. BLOCK_LEN_MAX is chosen in step 2.2; until then the only bound is MAX_SIZE (one row).
    lmax = R.MAX_SIZE if block_len_max is None else block_len_max
    if not isinstance(block_len, int) or not 1 <= block_len <= lmax:
        raise JobError(f"D13: BLOCK_LEN = {block_len} is outside 1..{lmax}"
                       + (" (BLOCK_LEN_MAX not chosen yet, step 2.2; bound = MAX_SIZE)" if block_len_max is None else ""))

    # buffers
    size = W * H
    _check_buffer("SRC_ADDR", src, size)
    _check_buffer("DST_ADDR", dst, size)
    if src < dst + size and dst < src + size:
        raise JobError(f"source 0x{src:08X} and output 0x{dst:08X} buffers overlap ({size} bytes each)")

    vals = [("SRC_ADDR", dict(ADDR=src)), ("DST_ADDR", dict(ADDR=dst)),
            ("WIDTH", dict(W=W)), ("HEIGHT", dict(H=H))]
    vals += [(n, dict(VALUE=c)) for n, c in zip(("B11", "B12", "B13", "B21", "B22", "B23"), b)]
    for p, rn in T_REGS:
        vals += [(rn + "_X", dict(VALUE=T[p][0])), (rn + "_Y", dict(VALUE=T[p][1]))]
    vals.append(("BLOCK_LEN", dict(L=block_len)))
    writes = []
    for name, fields in vals:
        try:
            writes.append((R.OFFSET[name], name, R.pack(name, **fields)))
        except ValueError as e:
            raise JobError(str(e)) from None
    if irq_en not in (0, 1):
        raise JobError(f"irq_en must be 0 or 1, got {irq_en}")
    start = R.pack("CTRL", START=1, MODE=m, IRQ_EN=irq_en)
    writes.append((R.OFFSET["CTRL"], "CTRL", start))
    return writes, start


def as_dict(writes):
    """offset -> value."""
    return {off: val for off, _, val in writes}


def format_image(writes):
    lines = ["offset  register    value (hex)   value (dec)    fields"]
    for off, name, val in writes:
        f = R.unpack(name, val)
        if list(f) == ["VALUE"]:
            dec, desc = f["VALUE"], f"{f['VALUE'] / 65536:+.6f}"
        else:
            dec, desc = val, ", ".join(f"{k}={v}" for k, v in f.items())
        lines.append(f"0x{off:02X}    {name:<10}  0x{val:08X}    {dec:>11}    {desc}")
    return "\n".join(lines)


def record_format(fields):
    return "<" + "".join(fmt for _, fmt in fields)


def record_size(fields):
    return struct.calcsize(record_format(fields))


def field_layout(fields):
    """field -> (byte offset, byte size, element count, signed)."""
    out, offset = {}, 0
    for name, fmt in fields:
        size = struct.calcsize("<" + fmt)
        out[name] = (offset, size, size // 4, fmt[-1] == "i")
        offset += size
    return out


JOB_SIZE = record_size(JOB_FIELDS)
RESULT_SIZE = record_size(RESULT_FIELDS)


def _pack_record(fields, values, what):
    flat = []
    for name, fmt in fields:
        count = struct.calcsize("<" + fmt) // 4
        value = values.get(name, 0 if count == 1 else (0,) * count)
        flat += [value] if count == 1 else list(value)
    try:
        return struct.pack(record_format(fields), *flat)
    except struct.error as e:
        raise JobError(f"{what}: a value does not fit its 32-bit field ({e})") from None


def _unpack_record(fields, data, what):
    if len(data) != record_size(fields):
        raise JobError(f"{what} has {len(data)} bytes, expected {record_size(fields)}")
    flat = list(struct.unpack(record_format(fields), data))
    out = {}
    for name, fmt in fields:
        count = struct.calcsize("<" + fmt) // 4
        out[name] = flat[0] if count == 1 else tuple(flat[:count])
        del flat[:count]
    return out


def encode_job(seq, W, H, mode, b, block_len, repeat=1, timeout_ms=JOB_TIMEOUT_MS_DEFAULT, irq=True, src_by_cpu=False,
               src=SRC_DEFAULT, dst=DST_DEFAULT, block_len_max=None, sw=False):
    """The job descriptor as bytes. All the checks of register_image apply, plus seq, repeat and timeout.
    sw=True: the ARM software baseline (step 4.4) runs the frame instead of the engine (grayscale only)."""
    if not isinstance(seq, int) or not 1 <= seq <= 0xFFFF_FFFF:
        raise JobError(f"sequence number {seq} is outside 1..0xFFFFFFFF")
    if not isinstance(repeat, int) or not 1 <= repeat <= JOB_MAX_REPEAT:
        raise JobError(f"repeat count {repeat} is outside 1..{JOB_MAX_REPEAT}")
    if not isinstance(timeout_ms, int) or not 1 <= timeout_ms <= JOB_MAX_TIMEOUT_MS:
        raise JobError(f"timeout {timeout_ms} ms is outside 1..{JOB_MAX_TIMEOUT_MS}")
    register_image(W, H, mode, b, block_len, src, dst, irq_en=1 if irq else 0, block_len_max=block_len_max)
    if sw and _mode(mode) != R.MODE["GRAY"]:
        raise JobError("the ARM software baseline (sw=True) is grayscale only")
    flags = (JOB_FLAG_IRQ_EN if irq else 0) | (JOB_FLAG_SRC_CPU if src_by_cpu else 0) | (JOB_FLAG_SW if sw else 0)
    return _pack_record(JOB_FIELDS, dict(magic=JOB_MAGIC, seq=seq, layout=LAYOUT_VERSION, mode=_mode(mode), flags=flags,
                                         width=W, height=H, block_len=block_len, src_addr=src, dst_addr=dst,
                                         repeat=repeat, timeout_ms=timeout_ms, b=tuple(int(c) for c in b)),
                        "job descriptor")


def decode_job(data):
    job = _unpack_record(JOB_FIELDS, data, "job descriptor")
    if job["magic"] != JOB_MAGIC:
        raise JobError(f"job descriptor magic is 0x{job['magic']:08X}, expected 0x{JOB_MAGIC:08X}")
    if job["layout"] != LAYOUT_VERSION:
        raise JobError(f"job descriptor layout is {job['layout']}, expected {LAYOUT_VERSION}")
    return job


def encode_result(**values):
    """The result record as bytes, as the ARM application writes it. Unnamed fields are 0."""
    unknown = set(values) - {name for name, _ in RESULT_FIELDS}
    if unknown:
        raise JobError(f"unknown result fields: {sorted(unknown)}")
    return _pack_record(RESULT_FIELDS, {"magic": RESULT_MAGIC, "layout": LAYOUT_VERSION, **values}, "result record")


def decode_result(data):
    r = _unpack_record(RESULT_FIELDS, data, "result record")
    if r["magic"] != RESULT_MAGIC:
        raise JobError(f"result record magic is 0x{r['magic']:08X}, expected 0x{RESULT_MAGIC:08X}")
    if r["layout"] != LAYOUT_VERSION:
        raise JobError(f"result record layout is {r['layout']}, expected {LAYOUT_VERSION}")
    r["rc_name"] = RC_NAME.get(r["rc"], f"UNKNOWN({r['rc']})")
    return r


def record_words(data):
    """32-bit little-endian words of a record."""
    return list(struct.unpack(f"<{len(data) // 4}I", data))


def _parse_size(s):
    try:
        w, h = s.lower().split("x")
        return int(w), int(h)
    except ValueError:
        raise argparse.ArgumentTypeError(f"size must be W x H like 640x480, got {s!r}") from None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--size", type=_parse_size, required=True, help="W x H, e.g. 640x480")
    ap.add_argument("--mode", required=True, choices=sorted(MODES))
    ap.add_argument("--block-len", type=int, required=True)
    ap.add_argument("--block-len-max", type=int, default=None, help="BUILD_ID.BLOCK_LEN_MAX of the target build")
    ap.add_argument("--b", type=int, nargs=6, metavar="Bij", help="b11 b12 b13 b21 b22 b23 as Q15.16 integers")
    ap.add_argument("--rot", type=float, default=0.0, help="forward rotation in degrees (if --b not given)")
    ap.add_argument("--sx", type=float, default=1.0)
    ap.add_argument("--sy", type=float, default=1.0)
    ap.add_argument("--shift", type=float, nargs=2, default=(0.0, 0.0), metavar=("ROWS", "COLS"))
    ap.add_argument("--mirror-rows", action="store_true")
    ap.add_argument("--mirror-cols", action="store_true")
    ap.add_argument("--src", type=lambda s: int(s, 0), default=SRC_DEFAULT)
    ap.add_argument("--dst", type=lambda s: int(s, 0), default=DST_DEFAULT)
    ap.add_argument("--no-irq", action="store_true", help="IRQ_EN = 0 (polling)")
    a = ap.parse_args(argv)
    W, H = a.size
    try:
        check_regs_current()
        if a.b is not None:
            b = tuple(a.b)
        else:
            b = P.make_b(W, H, rot_deg=a.rot, sx=a.sx, sy=a.sy, shift=tuple(a.shift),
                         mirror_rows=a.mirror_rows, mirror_cols=a.mirror_cols)
        writes, start = register_image(W, H, a.mode, b, a.block_len, a.src, a.dst,
                                       irq_en=0 if a.no_irq else 1, block_len_max=a.block_len_max)
    except (JobError, ValueError) as e:
        print(f"JOB REJECTED: {e}")
        return 1
    print(f"job: {W}x{H} (W x H), mode {a.mode}, BLOCK_LEN {a.block_len}, b = {b}")
    print(format_image(writes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
