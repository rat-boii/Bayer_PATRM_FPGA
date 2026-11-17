"""Case list and vectors for tb/tb_out_path.v (step 3.5). Every expected value comes from the Python model.

    python -m model.gen_vectors            (first, if data/vectors/exp_* are missing)
    python scripts/gen_out_path_vectors.py

Pixel streams: the model's expected output frames data/vectors/exp_<image>_<transform>_<W>x<H>.hex (step 1.2,
64-bit little-endian words, byte k of word j = output pixel 8j + k) are fed to the output path unchanged, so the
memory at DST_ADDR must equal that file byte for byte. Directed sizes (4 KB page crossings) use a pseudo-random
frame written here. Writes into data/vectors/out_path/ (not tracked; rerun this before the testbench):

  img_<name>.hex   frame for a directed size (same format as exp_*.hex)
  aw_<name>.txt    expected AW bursts in issue order: addr beats  (memmodel.split_bursts of every output row
                   [DST + u W, DST + (u + 1) W), u = 0 .. H-1; the same bursts memmodel.write_stats counts)
  cases.txt        one line per testbench case (CASE_HEADER); file names relative to data/vectors/
"""
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from model import memmodel as MM             # noqa: E402
from model.gen_images import SIM_SIZES       # noqa: E402
from model.gen_transforms import load as load_transforms   # noqa: E402

VEC_DIR = ROOT / "data" / "vectors"
SUB = "out_path"
OUT_DIR = VEC_DIR / SUB
DST = MM.DST_ADDR                            # 0x1800_0000, 4 KB aligned
MEM_BYTES = 65536                            # testbench memory window (tb_out_path.v MEM_WORDS = 8192)
SEED = 35_001

GROUP = {"a": 0, "b": 1, "c": 2, "d": 3, "e": 4, "g": 6, "h": 7}
CASE_HEADER = ("group name W H nburst aw_bp w_bp b_lat_min b_lat_max ip_gap err_burst abort_at max_out seed "
               "img_file aw_file")

# directed sizes (W x H): rows crossing 4 KB pages, page-aligned rows, 1-beat bursts
DIRECTED = [(208, 120), (2448, 8), (4096, 2), (4096, 1), (4088, 3), (136, 60), (2056, 4), (8, 1024), (24, 200)]


def aw_list(W, H):
    if W % 8 or not (1 <= W <= 4096) or not (1 <= H <= 4096):
        raise ValueError(f"bad size {W}x{H}")
    if W * H > MEM_BYTES:
        raise ValueError(f"{W}x{H} does not fit the testbench memory window")
    out = []
    for u in range(H):
        out += MM.split_bursts(DST + u * W, DST + (u + 1) * W)
    return out


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    rng = random.Random(SEED)
    frames = {}                                  # name -> (W, H, img_file relative to data/vectors)

    tfs = [t["name"] for t in load_transforms()]
    for img in ("mixed", "photo-mk-480x272"):
        for tf in tfs:
            for (W, H) in SIM_SIZES:
                f = f"exp_{img}_{tf}_{W}x{H}.hex"
                if not (VEC_DIR / f).is_file():
                    sys.exit(f"missing {VEC_DIR / f}; run python -m model.gen_vectors first")
                frames[f"{img}_{tf}_{W}x{H}"] = (W, H, f)
    for (W, H) in DIRECTED:
        name = f"dir_{W}x{H}"
        f = f"{SUB}/img_{name}.hex"
        (VEC_DIR / f).write_text("".join(f"{rng.getrandbits(64):016x}\n" for _ in range(W * H // 8)))
        frames[name] = (W, H, f)

    for name, (W, H, _) in frames.items():
        (OUT_DIR / f"aw_{name}.txt").write_text("".join(f"{a} {n}\n" for a, n in aw_list(W, H)))

    cases = []
    seed = [2000]

    def case(group, name, aw_bp=0, w_bp=0, lat=(4, 4), ip_gap=0, err=-1, abort=-1, max_out=8, label=None):
        W, H, f = frames[name]
        seed[0] += 1
        nb = len(aw_list(W, H))
        if err >= nb:
            raise ValueError("err burst out of range")
        cases.append((GROUP[group], label or name, W, H, nb, aw_bp, w_bp, lat[0], lat[1], ip_gap, err, abort, max_out,
                      seed[0], f, f"{SUB}/aw_{name}.txt"))

    # a: every transform x sim size (model output of the 'mixed' test image), plain memory, 1 pixel per clock
    for tf in tfs:
        for (W, H) in SIM_SIZES:
            case("a", f"mixed_{tf}_{W}x{H}")
    # b: sizes whose rows cross 4 KB pages, page-sized rows, 1-beat bursts; plain and random timing
    for (W, H) in DIRECTED:
        n = f"dir_{W}x{H}"
        case("b", n)
        case("b", n, aw_bp=25, w_bp=25, lat=(1, 60), ip_gap=20, max_out=4, label=n + "_rand")
    # c: throughput: 1 pixel per clock, no back-pressure, B latency 20
    for n in ("mixed_identity_256x192", "dir_2448x8", "dir_4096x2", "dir_8x1024"):
        case("c", n, lat=(20, 20), label="c_" + n)
    # d: random AWREADY / WREADY (0-30 %), B latency 1-60, pixel gaps (0-30 %), memory accepting 2..8 AWs
    pct = (0, 5, 10, 15, 20, 25, 30)
    i = 0
    for tf in tfs:
        for (W, H) in SIM_SIZES:
            case("d", f"photo-mk-480x272_{tf}_{W}x{H}", aw_bp=pct[i % 7], w_bp=pct[(i + 3) % 7], lat=(1, 60),
                 ip_gap=pct[(i + 5) % 7], max_out=2 + i % 7, label=f"photo_{tf}_{W}x{H}_rand")
            i += 1
    # d: out_fifo full -> ip_ready = 0 (slow memory: one AW at a time, long B latency, WREADY mostly low), and a
    #    heavily back-pressured AW channel (does not fill the FIFO: 128 pixel cycles per burst are enough)
    case("d", "dir_8x1024", lat=(60, 60), max_out=1, label="d_full_8x1024_one_aw_lat60")
    case("d", "dir_2448x8", w_bp=90, lat=(1, 60), max_out=2, label="d_full_2448x8_wready10")
    case("d", "mixed_rot37_256x192", aw_bp=90, lat=(30, 60), ip_gap=0, max_out=1, label="d_awready10_one_aw_rot37")
    # d: W before AW (AWREADY low most of the time, WREADY always high)
    case("d", "mixed_rot5_128x96", aw_bp=80, lat=(1, 10), label="d_w_before_aw_rot5_128x96")
    # e: BRESP = SLVERR on the first, a middle and the last burst; and in a random-timing frame
    nb64 = len(aw_list(64, 64))
    case("e", "mixed_identity_64x64", err=0, label="e_err_first")
    case("e", "mixed_identity_64x64", err=nb64 // 2, label="e_err_middle")
    case("e", "mixed_identity_64x64", err=nb64 - 1, label="e_err_last")
    case("e", "dir_2448x8", aw_bp=20, w_bp=20, lat=(1, 60), ip_gap=10, err=17, label="e_err_2448x8_rand")
    # g: done after the last BRESP (checked in every case; these make the gap long)
    case("g", "mixed_rot15_64x64", lat=(60, 60), label="g_lat60_rot15_64x64")
    case("g", "dir_8x1024", lat=(40, 60), max_out=8, label="g_lat40_60_8x1024")
    case("g", "dir_4096x1", lat=(60, 60), w_bp=30, label="g_lat60_4096x1")
    # h: reset in the middle of a frame (whole chain + memory), then the same frame in full
    for n, at in (("mixed_combined_128x96", 6000), ("dir_2448x8", 8), ("mixed_rot90_256x192", 30000)):
        case("h", n, aw_bp=20, w_bp=20, lat=(1, 60), ip_gap=10, abort=at, label=f"h_{n}_reset_at_{at}")
        case("h", n, aw_bp=20, w_bp=20, lat=(1, 60), ip_gap=10, label=f"h_{n}_after_reset")

    (OUT_DIR / "cases.txt").write_text("".join(" ".join(str(x) for x in c) + "\n" for c in cases))
    print(f"{len(cases)} cases, {sum(c[4] for c in cases)} bursts, {sum(c[2] * c[3] for c in cases)} bytes -> {OUT_DIR}")


if __name__ == "__main__":
    main()
