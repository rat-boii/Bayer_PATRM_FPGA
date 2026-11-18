"""Case list and vectors for tb/tb_system.v (step 4.1b, full system with the Zynq VIP). Everything comes from the model.

    python scripts/gen_system_vectors.py

Writes into data/vectors/system/ (not tracked; rerun this before the testbench):

  src_noise_<W>x<H>.hex        source image (seeded pseudo-random bytes): one 32-bit word per line, 8 lower-case hex
                               digits, byte at address 4k+i in bits [8i+7:8i]. This is the word format of the VIP DDR
                               model, which pre_load_mem_from_file reads with $readmemh.
  exp_noise_<tf>_<W>x<H>.hex   expected output frame (patrm.warp_gray), same format
  regs_<name>_<W>x<H>.txt      registers in driver write order, from model/job.py: "<offset> <value>" in hex, CTRL last
  regs_flush.txt               an 8 x 1 identity job into a scratch buffer, IRQ_EN = 0. The testbench runs it after each
                               frame: the VIP DDR model commits an HP write burst only when the next one arrives.
  cases.txt                    one line per case:
                               kind name W H bytes_rd rd_bursts wr_bursts err_code regs_file src_file exp_file

kind 0 = frame. kind 1 = rejected start: the registers of a valid job, with WIDTH changed so that it breaks D3. W and H
then give the size of the buffers, and exp_file is "-". bytes_rd, rd_bursts and wr_bursts come from model/memmodel.py.
"""
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from model import job as J                   # noqa: E402
from model import memmodel as MM             # noqa: E402
from model import patrm as P                 # noqa: E402
from model import regs as R                  # noqa: E402
from model.gen_transforms import load as load_transforms   # noqa: E402

OUT_DIR = ROOT / "data" / "vectors" / "system"
SEED = 41_000
BLOCK_LEN = MM.BLOCK_LEN_MAX                 # driver default (D15)
FLUSH_DST = 0x1C00_0000                      # same value as FLUSH_DST in tb/tb_system.v
BAD_WIDTH = 60                               # not a multiple of 8 (D3)
# name, transform, W, H, rejected. The rejected start sits between frames, so the next frame shows the engine recovered.
CASES = [("identity", "identity", 64, 64, False),
         ("rot15", "rot15", 64, 64, False),
         ("bad_size", "identity", 64, 64, True),
         ("rot37", "rot37", 128, 96, False),
         ("mirror_cols", "mirror_cols", 64, 64, False)]


def noise(W, H):
    return np.random.default_rng(SEED + 7 * W + H).integers(0, 256, size=(H, W), dtype=np.uint8)


def write_hex32(path, image):
    words = np.frombuffer(image.tobytes(), dtype="<u4")
    with open(path, "w", newline="\n") as f:
        f.write("".join(f"{int(w):08x}\n" for w in words))


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    J.check_regs_current()
    transforms = {t["name"]: t for t in load_transforms()}
    lines = []
    for name, tf, W, H, rejected in CASES:
        b = tuple(int(c) for c in MM._b_for(transforms[tf], W, H))
        src = noise(W, H)
        src_file = f"src_noise_{W}x{H}.hex"
        write_hex32(OUT_DIR / src_file, src)

        writes, _ = J.register_image(W, H, "gray", b, BLOCK_LEN, block_len_max=MM.BLOCK_LEN_MAX)
        if writes[-1][1] != "CTRL":
            raise SystemExit("model/job.py: CTRL must be the last register written")
        regs = [(off, val) for off, _, val in writes]
        if rejected:
            regs = [(off, R.pack("WIDTH", W=BAD_WIDTH) if off == R.OFFSET["WIDTH"] else val) for off, val in regs]
            exp_file, bytes_rd, rd_bursts, wr_bursts, err = "-", 0, 0, 0, R.ERR["BAD_SIZE"]
        else:
            exp = P.warp_gray(src, W, H, b)
            ref = {"identity": src, "mirror_cols": src[:, ::-1]}.get(tf)
            if ref is not None and not np.array_equal(exp, ref):
                raise SystemExit(f"{tf} {W}x{H}: the model output is not the (mirrored) input")
            exp_file = f"exp_noise_{tf}_{W}x{H}.hex"
            write_hex32(OUT_DIR / exp_file, exp)
            ps = MM.build_passes("gray", W, H, b)[0]
            reads = MM.pass_reads(ps, MM.make_blocks(ps, BLOCK_LEN, MM.SPAN_MAX), W, "P1")
            bytes_rd, rd_bursts = reads["beats"] * MM.BEAT, reads["bursts"]
            wr_bursts, err = MM.write_stats("gray", W, H)["write_bursts"], R.ERR["NONE"]

        regs_file = f"regs_{name}_{W}x{H}.txt"
        with open(OUT_DIR / regs_file, "w", newline="\n") as f:
            f.write("".join(f"{off:02x} {val:08x}\n" for off, val in regs))
        lines.append(f"{int(rejected)} {name} {W} {H} {bytes_rd} {rd_bursts} {wr_bursts} {err} "
                     f"{regs_file} {src_file} {exp_file}")

    b = tuple(int(c) for c in MM._b_for(transforms["identity"], 8, 1))
    writes, _ = J.register_image(8, 1, "gray", b, BLOCK_LEN, dst=FLUSH_DST, irq_en=0, block_len_max=MM.BLOCK_LEN_MAX)
    with open(OUT_DIR / "regs_flush.txt", "w", newline="\n") as f:
        f.write("".join(f"{off:02x} {val:08x}\n" for off, _, val in writes))

    with open(OUT_DIR / "cases.txt", "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print(f"gen_system_vectors: {len(lines)} cases -> {OUT_DIR / 'cases.txt'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
