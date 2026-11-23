"""Step 10.3 measurement: video stream fps for several sizes and transforms, FPGA engine against the ARM baseline.

    python scripts/eth/video_matrix.py                     board running patrm_eth.elf; frames data/gen/burst_800x480

Runs scripts/eth/video_stream.py for each size x transform x engine (100 frames each, every frame checked against
the model) and writes results/eth/video_matrix_<date>_<time>.txt. Last line VIDEO_MATRIX PASS when every run ends
with VIDEO PASS.
"""
import datetime as dt
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SIZES = ("800x480", "640x480", "480x272")
TRANSFORMS = ("identity", "spin")
ENGINES = ("fpga", "arm")


def main():
    lines = [f"video_matrix (step 10.3), {dt.datetime.now():%Y-%m-%d %H:%M}, frames data/gen/burst_800x480 "
             f"(cover-cropped to each size), 100 frames per run, one frame at a time, every frame checked",
             "", f"{'size':<9}{'transform':<10}{'engine':<7}{'fps':>7}{'engine ms':>11}{'board job ms':>14}"
                 f"{'round trip ms':>15}  bit-exact"]
    fails = []
    for size in SIZES:
        for tf in TRANSFORMS:
            for eng in ENGINES:
                p = subprocess.run([sys.executable, str(REPO / "scripts" / "eth" / "video_stream.py"), "--size", size,
                                    "--transform", tf, "--engine", eng], cwd=REPO, capture_output=True, text=True)
                o = p.stdout

                def grab(pattern):
                    m = re.search(pattern, o)
                    return m.group(1) if m else "-"
                chk = re.search(r"checked against the model: (\d+) of (\d+) frames, (\d+) bit-exact", o)
                last = o.strip().splitlines()[-1] if o.strip() else "no output"
                if last != "VIDEO PASS":
                    fails.append(f"{size} {tf} {eng}: {last}")
                lines.append(f"{size:<9}{tf:<10}{eng:<7}{grab(r'in [\d.]+ s: ([\d.]+) fps'):>7}"
                             f"{grab(r'engine\s+median\s+([\d.]+)'):>11}{grab(r'board_job\s+median\s+([\d.]+)'):>14}"
                             f"{grab(r'round_trip\s+median\s+([\d.]+)'):>15}  "
                             f"{(chk.group(3) + ' of ' + chk.group(2)) if chk else '-'}")
                print(lines[-1], flush=True)
    lines += ["", "VIDEO_MATRIX PASS" if not fails else "VIDEO_MATRIX FAIL: " + "; ".join(fails)]
    out = REPO / "results" / "eth" / f"video_matrix_{dt.datetime.now():%Y-%m-%d_%H%M%S}.txt"
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(lines[-1], f"({out})")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
