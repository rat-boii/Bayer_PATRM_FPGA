"""Test vectors for the RTL testbenches (step 1.2). Needs data/gen (python -m model.gen_images) and
model/transforms.json. Output: data/vectors/ (git-ignored). Formats are described in README.md.

    python -m model.gen_vectors [--out data/vectors] [--update-manifest]

  interp_vectors.txt                       D10 interpolator cases: xf yf r1 r2 r3 r4 w1 w2 w3 w4 D
  coord_vectors_<transform>_<W>x<H>.txt    u v X Y valid x0 y0 xf yf (sim sizes)
  src_<stem>.hex / exp_<stem>.hex          frames for $readmemh, 64-bit little-endian words
  cfg_<stem>.txt                           W H b11 b12 b13 b21 b22 b23
  with <stem> = <image>_<transform>_<W>x<H>
"""

import argparse
import os
import sys

import numpy as np

from model import manifest as M
from model import patrm as P
from model.gen_images import DEFAULT_OUT as GEN_DIR
from model.gen_images import SIM_SIZES
from model.gen_transforms import load as load_transforms

DEFAULT_OUT = os.path.join(M.DATA_DIR, "vectors")
N_RANDOM = 100_000
SEED_INTERP = 12_345

INTERP_HEADER = "# xf yf r1 r2 r3 r4 w1 w2 w3 w4 D"
COORD_HEADER = "# u v X Y valid x0 y0 xf yf"


# ---------------------------------------------------------------------------
# 64-bit hex words (byte at address 8k+i in bits [8i+7:8i], i.e. AXI little-endian)
# ---------------------------------------------------------------------------

def bytes_to_hex64(data):
    """bytes/uint8 array (length multiple of 8) -> list of 16-digit lower-case hex strings."""
    a = np.frombuffer(bytes(data), dtype=np.uint8)
    if a.size % 8:
        raise ValueError("length must be a multiple of 8")
    words = a.view("<u8")
    return [f"{int(w):016x}" for w in words]


def hex64_to_bytes(lines):
    """Inverse of bytes_to_hex64. Ignores blank lines and // comments."""
    vals = []
    for ln in lines:
        ln = ln.split("//")[0].strip()
        if ln:
            vals.append(int(ln, 16))
    return np.array(vals, dtype="<u8").tobytes()


def write_hex(path, data):
    with open(path, "w", newline="\n") as f:
        f.write("\n".join(bytes_to_hex64(data)))
        f.write("\n")


def read_hex(path):
    with open(path, "r") as f:
        return hex64_to_bytes(f.readlines())


def write_cfg(path, W, H, b):
    with open(path, "w", newline="\n") as f:
        f.write(" ".join(str(int(x)) for x in (W, H, *b)) + "\n")


def read_cfg(path):
    with open(path, "r") as f:
        vals = [int(x) for x in f.read().split()]
    return vals[0], vals[1], tuple(vals[2:8])


def _write_table(path, header, cols):
    cols = [np.asarray(c, dtype=np.int64).ravel() for c in cols]
    np.savetxt(path, np.stack(cols, axis=1), fmt="%d", delimiter=" ", header=header[2:], comments="# ",
               newline="\n")


# ---------------------------------------------------------------------------

def interp_cases():
    """Fixed cases first (worked example, corner cases), then N_RANDOM random cases."""
    rows = [(13107, 26216, 100, 140, 120, 160)]                      # worked example
    fr = (0, 1, 32767, 32768, 65535)
    rsets = [(0, 0, 0, 0), (255, 255, 255, 255), (255, 0, 0, 255), (0, 255, 255, 0),
             (0, 0, 0, 255), (255, 255, 255, 0), (100, 140, 120, 160)]
    for xf in fr:
        for yf in fr:
            for r in rsets:
                rows.append((xf, yf) + r)
    fixed = np.array(rows, dtype=np.int64)
    rng = np.random.default_rng(SEED_INTERP)
    rnd = np.concatenate([rng.integers(0, 65536, size=(N_RANDOM, 2)),
                          rng.integers(0, 256, size=(N_RANDOM, 4))], axis=1).astype(np.int64)
    return np.concatenate([fixed, rnd], axis=0), len(fixed)


def gen_interp(out_dir):
    c, nfixed = interp_cases()
    w1, w2, w3, w4, D = P.interp_d10(*(c[:, i] for i in range(6)))
    path = os.path.join(out_dir, "interp_vectors.txt")
    _write_table(path, INTERP_HEADER, [c[:, i] for i in range(6)] + [w1, w2, w3, w4, D])
    return path, len(c), nfixed


def gen_coords(out_dir, tf, W, H):
    b = tuple(tf["b"][f"{W}x{H}"])
    X, Y = P.coords(b, W, H)
    X64, Y64 = X.astype(np.int64), Y.astype(np.int64)
    u, v = np.meshgrid(np.arange(H), np.arange(W), indexing="ij")
    valid = (X64 >= 0) & (X64 <= (H - 1) * P.ONE) & (Y64 >= 0) & (Y64 <= (W - 1) * P.ONE)
    path = os.path.join(out_dir, f"coord_vectors_{tf['name']}_{W}x{H}.txt")
    _write_table(path, COORD_HEADER, [u, v, X64, Y64, valid, X64 >> 16, Y64 >> 16, X64 & 0xFFFF, Y64 & 0xFFFF])
    return path


def gray_images_at(W, H, gen_dir=GEN_DIR):
    """(image name, path) of every gray image at this size in data/gen."""
    suffix = f"_{W}x{H}.raw"
    out = []
    for f in sorted(os.listdir(gen_dir)):
        if f.startswith("gray_") and f.endswith(suffix):
            out.append((f[len("gray_"):-len(suffix)], os.path.join(gen_dir, f)))
    return out


def gen_frames(out_dir, tf, W, H, gen_dir=GEN_DIR):
    b = tuple(tf["b"][f"{W}x{H}"])
    paths = []
    for name, raw in gray_images_at(W, H, gen_dir):
        src = np.fromfile(raw, dtype=np.uint8)
        if src.size != W * H:
            raise ValueError(f"{raw}: {src.size} bytes, expected {W * H}")
        exp = P.warp_gray(src.reshape(H, W), W, H, b)
        stem = f"{name}_{tf['name']}_{W}x{H}"
        ps = os.path.join(out_dir, f"src_{stem}.hex")
        pe = os.path.join(out_dir, f"exp_{stem}.hex")
        pc = os.path.join(out_dir, f"cfg_{stem}.txt")
        write_hex(ps, src.tobytes())
        write_hex(pe, exp.tobytes())
        write_cfg(pc, W, H, b)
        paths += [(ps, "frame_src"), (pe, "frame_exp"), (pc, "frame_cfg")]
    return paths


def generate(out_dir=DEFAULT_OUT, gen_dir=GEN_DIR):
    if not os.path.isdir(gen_dir) or not os.listdir(gen_dir):
        raise SystemExit(f"{gen_dir} is empty: run python -m model.gen_images first")
    os.makedirs(out_dir, exist_ok=True)
    entries = []
    path, n, nfixed = gen_interp(out_dir)
    entries.append(M.entry(path, None, None, "interp"))
    for tf in load_transforms():
        for (W, H) in SIM_SIZES:
            entries.append(M.entry(gen_coords(out_dir, tf, W, H), W, H, f"coord:{tf['name']}"))
            for p, kind in gen_frames(out_dir, tf, W, H, gen_dir):
                entries.append(M.entry(p, W, H, f"{kind}:{tf['name']}"))
    return entries, n, nfixed


def main(argv=None):
    p = argparse.ArgumentParser(prog="python -m model.gen_vectors", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out", default=DEFAULT_OUT)
    p.add_argument("--update-manifest", action="store_true",
                   help="rewrite the 'vectors' section of data/manifest.json instead of checking it")
    a = p.parse_args(argv)
    entries, n, nfixed = generate(a.out)
    print(f"gen_vectors: {len(entries)} files in {os.path.relpath(a.out)}; interp_vectors.txt has {n} cases "
          f"({nfixed} fixed + {n - nfixed} random)")
    bad = M.sync_section("vectors", entries, update=a.update_manifest)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
