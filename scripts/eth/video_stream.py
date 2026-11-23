"""Video streaming through the PATRM engine over Ethernet (step 10.3): core used by the GUI, plus a headless run.

    python scripts/eth/video_stream.py                                     data/gen/burst_800x480, 800x480, spin
    python scripts/eth/video_stream.py --frames <png folder> --size 640x480 --transform rot15
    python scripts/eth/video_stream.py --engine arm                        the ARM software baseline instead
    python scripts/eth/video_stream.py --load                              program the board first (about 70 s)
    python scripts/eth/video_gui.py                                        the GUI on top of this

Frames: every PNG/JPG in the folder, in name order, converted to grayscale and cover-cropped to exactly W x H (D3:
W a multiple of 8). The PC prepares them before streaming (decoding PNGs live would limit the rate, not the board).
Transform per frame (--transform):
    spin            one full turn over the frames (rotation 0..360 degrees about the centre)
    sweep:A:B       rotation from A to B degrees over the frames, e.g. sweep:-30:30
    zoom:S1:S2      scale from S1 to S2 over the frames, e.g. zoom:0.8:1.3
    <name>          a fixed transform of model/transforms.json (identity, rot15, rot90, ...)
Each frame is one job: source up, run, output down, one after the other on one TCP connection (no UART line on the
board). Measured per frame: upload, board (receive + job), download, round trip; stream fps = frames / streaming time.
Check: every output against model/patrm.warp_gray with the same integer b, in parallel worker processes; a frame
counts as bit-exact only with 0 differing bytes. Result: results/eth/video_<date>_<time>.csv / .txt; the last line
is VIDEO PASS (all frames bit-exact, rc OK) or VIDEO FAIL: <reason>.
"""
import argparse
import csv
import datetime as dt
import math
import os
import sys
import threading
import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from model import job as J                    # noqa: E402
from model import memmodel as MM              # noqa: E402
from model import patrm as P                  # noqa: E402
from model.gen_transforms import load as load_transforms   # noqa: E402
import eth_link as EL                          # noqa: E402

BLOCK_LEN = 64                                 # driver default (D15)
DEFAULT_FRAMES = REPO / "data" / "gen" / "burst_800x480"
OUT_DIR = REPO / "results" / "eth"
IMAGE_EXT = (".png", ".jpg", ".jpeg", ".bmp")


class VideoError(Exception):
    pass


def parse_size(text):
    w, h = text.lower().split("x")
    return int(w), int(h)


def load_frames(folder, W, H, progress=None):
    """Grayscale W x H frames from every image in the folder (name order), cover-cropped (no distortion)."""
    P.check_size(W, H, "gray")
    files = sorted(p for p in Path(folder).iterdir() if p.suffix.lower() in IMAGE_EXT)
    if not files:
        raise VideoError(f"no PNG/JPG images in {folder}")
    frames = []
    for i, f in enumerate(files):
        im = Image.open(f).convert("L")
        s = max(W / im.width, H / im.height)
        rw, rh = max(W, round(im.width * s)), max(H, round(im.height * s))
        im = im.resize((rw, rh), Image.BILINEAR)
        x0, y0 = (rw - W) // 2, (rh - H) // 2
        frames.append(np.asarray(im.crop((x0, y0, x0 + W, y0 + H)), dtype=np.uint8).copy())
        if progress:
            progress(i + 1, len(files))
    return frames, files


def transform_list(spec, n, W, H):
    """Integer b (Q15.16, D5) for each of n frames, checked against D4."""
    def lin(a, b, k):
        return a + (b - a) * (k / max(1, n - 1))
    if spec == "spin":
        bs = [P.make_b(W, H, rot_deg=360.0 * k / n) for k in range(n)]
    elif spec.startswith("sweep:"):
        a0, a1 = (float(x) for x in spec.split(":")[1:3])
        bs = [P.make_b(W, H, rot_deg=lin(a0, a1, k)) for k in range(n)]
    elif spec.startswith("zoom:"):
        s0, s1 = (float(x) for x in spec.split(":")[1:3])
        bs = [P.make_b(W, H, sx=lin(s0, s1, k), sy=lin(s0, s1, k)) for k in range(n)]
    else:
        tfs = {t["name"]: t for t in load_transforms()}
        if spec not in tfs:
            raise VideoError(f"unknown transform {spec!r}: spin, sweep:A:B, zoom:S1:S2 or one of {', '.join(tfs)}")
        b = tuple(int(c) for c in MM._b_for(tfs[spec], W, H))
        bs = [b] * n
    bs = [tuple(int(c) for c in b) for b in bs]
    for b in bs:
        P.check_transform(b, W, H)
    return bs


def verify_frame(k, src_bytes, W, H, b, out_bytes):
    """Worker process: model output for this frame against the board's. Returns (k, differing bytes)."""
    src = np.frombuffer(src_bytes, dtype=np.uint8).reshape(H, W)
    exp = P.warp_gray(src, W, H, b, check=False)
    got = np.frombuffer(out_bytes, dtype=np.uint8).reshape(H, W)
    return k, int(np.count_nonzero(exp != got))


class Verifier:
    """Checks frames against the model in worker processes while the stream runs."""

    def __init__(self, workers=None):
        self.pool = ProcessPoolExecutor(max_workers=workers or max(1, (os.cpu_count() or 4) - 4))
        self.lock = threading.Lock()           # the GUI polls from its own thread while the stream submits
        self.futures = []
        self.submitted = 0
        self.done = 0
        self.bad = []                          # (frame, differing bytes)

    def submit(self, k, src, W, H, b, out):
        f = self.pool.submit(verify_frame, k, src.tobytes(), W, H, b, out)
        with self.lock:
            self.futures.append(f)
            self.submitted += 1

    def _collect(self, wait):
        with self.lock:
            still = []
            for f in self.futures:
                if wait or f.done():
                    k, ndiff = f.result()
                    self.done += 1
                    if ndiff:
                        self.bad.append((k, ndiff))
                else:
                    still.append(f)
            self.futures = still
            return self.done, len(self.bad)

    def poll(self):
        """Collect finished checks; returns (checked, mismatching frames)."""
        return self._collect(wait=False)

    def finish(self):
        """Wait for every submitted check; returns (checked, mismatching frames)."""
        result = self._collect(wait=True)
        self.pool.shutdown()
        return result


class Streamer:
    """One TCP connection to the board's job service; one job per frame."""

    def __init__(self, W, H, engine="fpga", ip=EL.BOARD_IP):
        if engine not in ("fpga", "arm"):
            raise VideoError("engine must be fpga or arm")
        self.W, self.H, self.engine = W, H, engine
        self.link = EL.JobLink(ip, timeout=60)
        self.seq = 0

    def frame(self, src, b):
        """Returns (output H x W uint8, result dict, timings dict in ms)."""
        self.seq = (self.seq % 0xFFFF_FFFF) + 1
        desc = J.encode_job(self.seq, self.W, self.H, "gray", b, BLOCK_LEN, repeat=1, irq=False, src_by_cpu=True,
                            block_len_max=MM.BLOCK_LEN_MAX, sw=(self.engine == "arm"))
        rsp, res, out, t = self.link.run(desc, src.tobytes(), self.W * self.H, fill=False, quiet=True)
        if rsp["status"] != 0:
            raise VideoError(f"board rejected the frame: {rsp['status_name']}")
        r = J.decode_result(res)
        if r["rc"] != J.RC["OK"] or r["seq"] != self.seq:
            raise VideoError(f"frame failed on the board: rc {r['rc_name']}, seq {r['seq']} (sent {self.seq})")
        times = dict(upload=1e3 * t["send_s"], board=rsp["rx_us"] / 1e3 + rsp["job_us"] / 1e3,
                     board_rx=rsp["rx_us"] / 1e3, board_job=rsp["job_us"] / 1e3,
                     engine=r["engine_ns_avg"] / 1e6, download=1e3 * t["download_s"],
                     round_trip=1e3 * t["round_trip_s"])
        return np.frombuffer(out, dtype=np.uint8).reshape(self.H, self.W), r, times

    def close(self):
        self.link.close()


def median(xs):
    s = sorted(xs)
    return s[len(s) // 2] if s else float("nan")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--frames", default=str(DEFAULT_FRAMES), help="folder of PNG/JPG frames")
    ap.add_argument("--size", type=parse_size, default=(800, 480), help="W x H (default 800x480)")
    ap.add_argument("--transform", default="spin", help="spin, sweep:A:B, zoom:S1:S2 or a transforms.json name")
    ap.add_argument("--engine", choices=("fpga", "arm"), default="fpga")
    ap.add_argument("--loops", type=int, default=1, help="play the frames this many times")
    ap.add_argument("--load", action="store_true", help="program the board and start patrm_eth.elf first")
    ap.add_argument("--ip", default=EL.BOARD_IP)
    a = ap.parse_args(argv)
    W, H = a.size
    lines, fails, rows = [], [], []

    def say(text):
        print(text, flush=True)
        lines.append(text)

    try:
        frames, files = load_frames(a.frames, W, H)
        bs = transform_list(a.transform, len(frames), W, H)
        say(f"video: {len(frames)} frames from {a.frames} at {W}x{H}, transform {a.transform}, engine {a.engine}, "
            f"loops {a.loops}")
        if a.load:
            EL.load_board()
            say(f"board ready after {EL.wait_ready(a.ip):.1f} s")
        ver = Verifier()
        st = Streamer(W, H, a.engine, a.ip)
        t0 = time.perf_counter()
        n = 0
        try:
            for loop in range(a.loops):
                for k, (src, b) in enumerate(zip(frames, bs)):
                    out, r, t = st.frame(src, b)
                    ver.submit(n, src, W, H, b, out.tobytes())
                    rows.append(dict(frame=n, file=files[k].name, cycles=r["cycles"], **{f"{x}_ms": f"{v:.3f}"
                                                                                       for x, v in t.items()}))
                    n += 1
        finally:
            st.close()
        stream_s = time.perf_counter() - t0
        checked, nbad = ver.finish()
        fps = n / stream_s
        say(f"streamed {n} frames in {stream_s:.2f} s: {fps:.1f} fps ({a.engine}, {W}x{H}, round trip, one frame at "
            f"a time)")
        for key in ("upload", "board_rx", "board_job", "engine", "download", "round_trip"):
            vals = [float(r_[f"{key}_ms"]) for r_ in rows]
            say(f"  {key:<11} median {median(vals):7.2f} ms  min {min(vals):7.2f}  max {max(vals):7.2f}")
        say(f"checked against the model: {checked} of {n} frames, {n - nbad} bit-exact"
            + (f"; differing: {ver.bad[:5]}" if nbad else ""))
        if nbad or checked != n:
            fails.append(f"{nbad} of {n} frames differ from the model")
    except (VideoError, EL.LinkError, OSError, ValueError) as e:
        fails.append(str(e))

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y-%m-%d_%H%M%S")
    if rows:
        with open(OUT_DIR / f"video_{stamp}.csv", "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
    final = "VIDEO PASS" if not fails else "VIDEO FAIL: " + "; ".join(fails)
    lines.append(final)
    (OUT_DIR / f"video_{stamp}.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(final)
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
