"""Transform a PNG on the ZedBoard (PATRM, grayscale) and get the result back as a PNG.

    python scripts/board/png_transform.py in.png out.png [--rot DEG] [--sx S] [--sy S] [--shift ROWS COLS]
                                          [--mirror-cols] [--mirror-rows] [--size WxH] [--rev c|d]
                                          [--model-only] [--dry-run]

Parameters are FORWARD parameters (same meaning as model/patrm.py make_b_float): rotation in degrees (+ = counter-clockwise
as displayed), sx scales rows, sy scales columns, shift = (rows, cols) in pixels (+rows moves the content down), mirror_cols =
left-right flip, mirror_rows = top-bottom flip. The pivot is the image centre. The script quantises them to the integer
b (D5), checks D4, runs the frame on the board with the same XSDB flow as run_frame.py and checks the result against the
Python model (must be 0 differing bytes) before it writes out.png.

The input is converted to 8-bit gray. If --size WxH is not given, the image keeps its size, except that the width is
reduced to a multiple of 8 (D3) by resizing. W and H must be at most 4096. Outside the source the output is black (D1).

    --model-only   no board: write the PNG from the Python model (same integer maths), for checking parameters
    --dry-run      print every XSDB command and touch no board
    --rev d        use the temporary Rev D bundle in results/hw/rev D (default: the Rev C files in results/hw)
    --bit / --init explicit bitstream and ps7_init script (override --rev)
    --no-program   do not program the FPGA or run ps7_init: use the bitstream already loaded (for example from the
                   Vivado Hardware Manager). The PS must already be set up in this power cycle (one earlier normal run).

Needs xsdb on PATH (or Vivado 2026.1 in C:\\AMDDesignTools). Run folder: build/board/frame_<name>_custom_<W>x<H>/.
Exit code: 0 pass, 1 mismatch against the model, 2 error.
"""
import argparse
import os
import shutil
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts" / "board"))

import run_frame as RF                           # noqa: E402
from model import job as J                       # noqa: E402
from model import patrm as P                     # noqa: E402

MAX_DIM = 4096                                   # D11
DEFAULT_XSDB_DIRS = [r"C:\AMDDesignTools\2026.1\Vivado\bin"]


def parse_size(text):
    try:
        w, h = text.lower().split("x")
        return int(w), int(h)
    except ValueError:
        raise argparse.ArgumentTypeError("size must look like 800x480 (W x H)")


def load_gray(path, size):
    im = Image.open(path).convert("L")
    W, H = size if size else im.size
    if not size and W % 8:
        W -= W % 8
        if W == 0:
            raise RF.FrameError("image is narrower than 8 pixels")
    if (W, H) != im.size:
        im = im.resize((W, H), Image.LANCZOS)
    P.check_size(W, H, "gray")                   # D3
    if W > MAX_DIM or H > MAX_DIM:
        raise RF.FrameError(f"size {W}x{H} is above the 4096 x 4096 limit (D11)")
    return np.asarray(im, dtype=np.uint8), W, H


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--rot", type=float, default=0.0, help="rotation in degrees, + = counter-clockwise")
    ap.add_argument("--sx", type=float, default=1.0, help="row scale")
    ap.add_argument("--sy", type=float, default=1.0, help="column scale")
    ap.add_argument("--shift", type=float, nargs=2, default=(0.0, 0.0), metavar=("ROWS", "COLS"))
    ap.add_argument("--mirror-cols", action="store_true", help="left-right flip (column axis, y)")
    ap.add_argument("--mirror-rows", action="store_true", help="top-bottom flip (row axis, x)")
    ap.add_argument("--size", type=parse_size, default=None, help="resize the input to WxH first")
    ap.add_argument("--rev", choices=["c", "d"], default=None, help="board revision bundle (see above)")
    ap.add_argument("--bit", default=None)
    ap.add_argument("--init", default=None)
    ap.add_argument("--timeout", type=int, default=10, help="seconds to wait for DONE")
    ap.add_argument("--model-only", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-program", action="store_true",
                    help="keep the bitstream already in the FPGA (e.g. programmed from the Vivado Hardware Manager) and "
                         "the PS setup of an earlier load in this power cycle")
    a = ap.parse_args(argv)

    try:
        src, W, H = load_gray(a.input, a.size)
        forward = {"rot_deg": a.rot, "sx": a.sx, "sy": a.sy, "shift": tuple(a.shift),
                   "mirror_rows": a.mirror_rows, "mirror_cols": a.mirror_cols, "about": "centre"}
        b = P.make_b(W, H, **forward)
        P.check_transform(b, W, H)               # D4
        print(f"png_transform: {a.input} -> {W} x {H} gray, forward {forward}")
        print(f"png_transform: b (Q15.16) = {tuple(int(c) for c in b)}")

        out_path = Path(a.output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        if a.model_only:
            out = P.warp_gray(src, W, H, tuple(int(c) for c in b))
            Image.fromarray(out, "L").save(out_path)
            print(f"png_transform: MODEL ONLY (no board) -> {out_path}")
            return RF.EXIT_PASS

        hw = ROOT / "results" / "hw" / ("rev D" if a.rev == "d" else "")
        bit = a.bit or str(hw / "patrm_gray.bit")
        init = a.init or str(hw / "ps7_init.tcl")
        if not a.dry_run:
            for label, p in (("bitstream", bit), ("ps7_init", init)):
                if not Path(p).is_file():
                    raise RF.FrameError(f"{label} not found: {p} (use --rev d, or --bit / --init)")
        if shutil.which("xsdb") is None:
            for d in DEFAULT_XSDB_DIRS:
                if (Path(d) / "xsdb.bat").is_file():
                    os.environ["PATH"] = d + os.pathsep + os.environ["PATH"]
                    break

        # Our own transform entry, in the form run_frame.py's loaders accept (forward parameters, no preset b).
        RF.find_transform = lambda name: {"name": "custom", "forward": dict(forward, shift=list(forward["shift"])), "b": {}}
        raw = ROOT / "build" / "board" / "png_in"
        raw.mkdir(parents=True, exist_ok=True)
        stem = Path(a.input).stem
        raw_file = raw / f"{stem}_{W}x{H}.raw"
        raw_file.write_bytes(src.tobytes())

        ns = argparse.Namespace(image=str(raw_file), transform="custom", W=W, H=H, bit=bit, init=init,
                                timeout=a.timeout)
        f = RF.prepare(ns)
        print(f"png_transform: predicted BYTES_RD {f['bytes_rd']}, BYTES_WR {W * H}")
        f["out_file"].unlink(missing_ok=True)
        start = time.time()
        flags = (["--dry-run"] if a.dry_run else []) + (["--no-program"] if a.no_program else [])
        values = RF.parse_xsdb(RF.run_xsdb(f, flags), a.dry_run)
        if a.dry_run:
            print("png_transform: DRY RUN OK: nothing was done on a board")
            return RF.EXIT_PASS
        fails = RF.report(f, values)
        print(f"run time       {time.time() - start:.0f} s")
        if fails:
            print("PNG TRANSFORM FAIL (no PNG written): " + "; ".join(fails))
            return RF.EXIT_FAIL
        out = np.frombuffer(f["out_file"].read_bytes()[:W * H], dtype=np.uint8).reshape(H, W)
        Image.fromarray(out, "L").save(out_path)
        print(f"png_transform: PASS (bit-exact with the model, from the FPGA) -> {out_path}")
        return RF.EXIT_PASS
    except (RF.FrameError, J.JobError, ValueError, OSError) as e:
        print(f"PNG TRANSFORM ERROR: {e}")
        return RF.EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
