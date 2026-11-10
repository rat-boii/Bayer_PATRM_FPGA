"""Register image for one engine job (step 2.1).

Given size, mode, transform and block length, check everything the hardware and the driver will check and
return the register values (offset -> 32-bit value), in the order the driver writes them. The C driver
(step 4.2) and the testbenches mirror this. Every value is packed through model/regs.py (generated from
spec/regs.json), so a value that does not fit its field is an error, and a stale model/regs.py is refused.

Checks: mode (MODE enum), size D3 + D11, transform D4 (Bayer: also every plane), BLOCK_LEN D13, buffer
placement and 4 KB alignment (spec/memory_map.md). T_p from model/bayer.py plane_shifts (D2, D12).

Examples (repo root):
  python -m model.job --size 640x480 --mode bayer_a --b 52429 -39322 131072 39322 52429 65536 --block-len 16
  python -m model.job --size 1920x1080 --mode gray --rot 15 --block-len 32
"""

import argparse
import os
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
