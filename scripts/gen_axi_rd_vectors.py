"""Case list and vectors for tb/tb_axi_rd_master.v (step 3.4). Every expected burst comes from the Python model.

    python -m model.gen_vectors            (first, if data/vectors/sched_bursts_* are missing)
    python scripts/gen_axi_rd_vectors.py

Reads the step 2.2 burst lists data/vectors/sched_bursts_<tf>_<W>x<H>_L<L>_S<S>.txt (every transform of
model/transforms.json, every SIM_SIZE, every (L, S) in memmodel.SCHED_CONFIGS) and writes into
data/vectors/axi_rd/ (not tracked; rerun this before the testbench):

  mem.hex           memory image of the HP0 window at SRC_ADDR: MEM_WORDS 64-bit words, one hex word per line,
                    byte k of a word = bits 8k+7:8k (address order). Pseudo-random, so a wrong address shows.
  cmds_<name>.txt   row commands for the master, one per line:   addr words slot
  bursts_<name>.txt expected AR bursts in issue order, one per line:   addr beats slot word cmd_last
                    (word = first word of the burst inside its command; cmd_last = 1 on the command's last burst)
  cases.txt         one line per testbench case (CASE_HEADER), file names relative to data/vectors/axi_rd/

Schedule cases (groups a, d, e, g): the row commands are rebuilt from the 2.2 burst list by grouping the bursts
of one (block, row): addr = first burst address, words = sum of beats, slot = the slot. The expected AR stream is
the 2.2 burst list itself (unchanged). Directed cases (groups b, c, e): commands written here, expected bursts =
memmodel.split_bursts of each command.

A single command is at most 64 words = 512 bytes (spec section 5, cmd_words [7] 1..64), so one command can cross
at most ONE 4 KB boundary. "Spanning 2 and 3 boundaries" is therefore tested as a back-to-back command stream
covering a byte range that spans 2 and 3 boundaries.
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
OUT_DIR = VEC_DIR / "axi_rd"
BASE = MM.SRC_ADDR                           # 0x1000_0000, 4 KB aligned
MEM_WORDS = 16384                            # 128 KB window (sim sizes need <= 48 KB)
MEM_BYTES = MEM_WORDS * MM.BEAT
MAX_WORDS = 64                               # cmd_words 1..64 (spec section 5)
NSLOT = 32
SEED = 34_001
MAX_CMDS = 65536                             # testbench array sizes (tb_axi_rd_master.v MAXC / MAXB)
MAX_BURSTS = 65536

GROUP = {"a": 0, "b": 1, "c": 2, "d": 3, "e": 4, "g": 6}
CASE_HEADER = ("group name ncmd nburst nbeat lat_min lat_max ar_bp r_gap cmd_gap err_burst abort_at max_out "
               "seed cmds_file bursts_file")


def load_sched_bursts(path):
    out = []
    for line in path.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        blk, row, slot, word, addr, beats = map(int, line.split())
        out.append((blk, row, slot, word, addr, beats))
    return out


def commands_from_sched(bursts):
    """Group the 2.2 bursts by (block, row) -> commands; returns (cmds, expected burst lines)."""
    cmds, exp = [], []
    i = 0
    while i < len(bursts):
        blk, row, slot, _, addr, _ = bursts[i]
        j, words = i, 0
        while j < len(bursts) and bursts[j][0] == blk and bursts[j][1] == row:
            b = bursts[j]
            if b[2] != slot or b[3] != words or b[4] != addr + 8 * words:
                raise ValueError(f"burst list not contiguous at line {j}: {b}")
            words += b[5]
            j += 1
        if not 1 <= words <= MAX_WORDS:
            raise ValueError(f"command of {words} words at burst {i}")
        cmds.append((addr, words, slot))
        for k in range(i, j):
            b = bursts[k]
            exp.append((b[4], b[5], b[2], b[3], int(k == j - 1)))
        i = j
    return cmds, exp


def expected_from_cmds(cmds):
    """Independent split with memmodel.split_bursts (the spec's splitting rule)."""
    exp = []
    for addr, words, slot in cmds:
        if addr % 8 or not 1 <= words <= MAX_WORDS:
            raise ValueError(f"bad command {addr:#x} {words}")
        if addr < BASE or addr + 8 * words > BASE + MEM_BYTES:
            raise ValueError(f"command {addr:#x} +{words} outside the memory window")
        bl = MM.split_bursts(addr, addr + 8 * words)
        for k, (a, n) in enumerate(bl):
            exp.append((a, n, slot, (a - addr) // 8, int(k == len(bl) - 1)))
    return exp


def range_cmds(s, e, slot0=0):
    """Back-to-back commands of up to 64 words covering byte range [s, e) (offsets from BASE)."""
    out, a, k = [], BASE + s, 0
    while a < BASE + e:
        n = min(MAX_WORDS, (BASE + e - a) // 8)
        out.append((a, n, (slot0 + k) % NSLOT))
        a += 8 * n
        k += 1
    return out


def directed_sets():
    P = MM.PAGE
    d = {}
    # requests ending exactly at a 4 KB boundary (last beat at 4096 - 8)
    d["b_end_at_4k"] = [(BASE + P - 8, 1, 0), (BASE + 2 * P - 128, 16, 1), (BASE + 3 * P - 512, 64, 2),
                        (BASE + 4 * P - 24, 3, 3), (BASE + 5 * P - 136, 17, 4)]
    # requests starting at 4096 - 8 (one beat before the boundary)
    d["b_start_at_4k_m8"] = [(BASE + 6 * P - 8, 2, 5), (BASE + 7 * P - 8, 16, 6), (BASE + 8 * P - 8, 17, 7),
                             (BASE + 9 * P - 8, 64, 8), (BASE + 10 * P - 8, 1, 9)]
    # crossing one boundary with different split points (single commands)
    d["b_cross_one"] = [(BASE + 11 * P - 24, 16, 10), (BASE + 12 * P - 256, 64, 11), (BASE + 13 * P - 120, 33, 12),
                        (BASE + 14 * P - 64, 64, 13), (BASE + 15 * P - 8 * 15, 16, 14)]
    # command streams spanning 2 and 3 boundaries
    d["b_span_2_boundaries"] = range_cmds(16 * P - 120, 17 * P + 120, 15)
    d["b_span_3_boundaries"] = range_cmds(18 * P - 8, 21 * P + 16, 3)
    # lengths: 1, 15, 16, 17, 31, 32, 33, 48, 63, 64 beats; 128-byte aligned and unaligned (8, 64, 120)
    lens = (1, 15, 16, 17, 31, 32, 33, 48, 63, 64)
    lc, a = [], BASE + 22 * P + 256
    for off in (0, 8, 64, 120):
        for n in lens:
            a = (a + 127) // 128 * 128 + off
            if (a % P) + 8 * n > P:              # keep these inside one page (boundaries tested above)
                a = (a // P + 1) * P + 256 + off
            lc.append((a, n, len(lc) % NSLOT))
            a += 8 * n + 8
    d["b_lengths_aligned_unaligned"] = lc
    # last 512 bytes of the memory window and a command crossing into the last page
    d["b_window_end"] = [(BASE + MEM_BYTES - 512, 64, 31), (BASE + MEM_BYTES - P - 64, 64, 30)]
    return d


def random_cmds(rng, n):
    out = []
    for _ in range(n):
        w = rng.choice([rng.randint(1, 64), 64, 1, 16, 17, rng.randint(1, 16)])
        a = BASE + 8 * rng.randrange(0, (MEM_BYTES - 8 * w) // 8 + 1)
        if rng.random() < 0.3:                   # bias towards the last beats of a page
            page = rng.randrange(1, MEM_BYTES // MM.PAGE)
            a = BASE + page * MM.PAGE - 8 * rng.randint(1, 16)
            a = min(a, BASE + MEM_BYTES - 8 * w)
        out.append((a, w, rng.randrange(NSLOT)))
    return out


def write_lines(path, rows):
    path.write_text("".join(" ".join(str(x) for x in r) + "\n" for r in rows))


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    rng = random.Random(SEED)
    # memory image
    words = [rng.getrandbits(64) for _ in range(MEM_WORDS)]
    (OUT_DIR / "mem.hex").write_text("".join(f"{w:016x}\n" for w in words))

    sets = {}                                    # name -> (cmds, exp)
    sched = []
    for tf in load_transforms():
        for (W, H) in SIM_SIZES:
            for (L, S) in MM.SCHED_CONFIGS:
                name = f"{tf['name']}_{W}x{H}_L{L}_S{S}"
                p = VEC_DIR / f"sched_bursts_{name}.txt"
                if not p.is_file():
                    sys.exit(f"missing {p}; run python -m model.gen_vectors first")
                cmds, exp = commands_from_sched(load_sched_bursts(p))
                # the 2.2 list must equal the spec's split of the rebuilt commands (same rule, two sources)
                if expected_from_cmds(cmds) != exp:
                    sys.exit(f"{name}: 2.2 burst list differs from split_bursts of its commands")
                sets[name] = (cmds, exp)
                sched.append(name)
    for name, cmds in directed_sets().items():
        sets[name] = (cmds, expected_from_cmds(cmds))
    for k in range(4):
        cmds = random_cmds(rng, 3000)
        sets[f"rand{k}"] = (cmds, expected_from_cmds(cmds))
    # throughput sets: back-to-back 4 KB-aligned stream with 16-, 8- and 1-beat bursts
    sets["c_burst16"] = (range_cmds(0, 64 * 1024), None)
    sets["c_burst8"] = ([(BASE + 64 * k, 8, k % NSLOT) for k in range(1024)], None)
    sets["c_burst1"] = ([(BASE + 8 * k, 1, k % NSLOT) for k in range(2048)], None)
    sets["e_two_bursts"] = ([(BASE + 9 * MM.PAGE - 8, 17, 4), (BASE + 0x200, 64, 5), (BASE + 0x400, 1, 6)], None)
    for n, (c, e) in list(sets.items()):
        if e is None:
            sets[n] = (c, expected_from_cmds(c))

    for name, (cmds, exp) in sets.items():
        if len(cmds) > MAX_CMDS or len(exp) > MAX_BURSTS:
            sys.exit(f"{name}: {len(cmds)} commands / {len(exp)} bursts exceed the testbench arrays")
        write_lines(OUT_DIR / f"cmds_{name}.txt", cmds)
        write_lines(OUT_DIR / f"bursts_{name}.txt", exp)

    cases = []
    seed = [1000]

    def case(group, name, lat=(4, 4), ar_bp=0, r_gap=0, cmd_gap=0, err=-1, abort=-1, max_out=8, label=None):
        cmds, exp = sets[name]
        seed[0] += 1
        cases.append((GROUP[group], label or name, len(cmds), len(exp), sum(e[1] for e in exp), lat[0], lat[1],
                      ar_bp, r_gap, cmd_gap, err, abort, max_out, seed[0], f"cmds_{name}.txt", f"bursts_{name}.txt"))

    # a: every 2.2 schedule, plain memory (fixed latency 4, no back-pressure, no gaps)
    for n in sched:
        case("a", n)
    # b: directed 4 KB / length cases, plain and with random timing
    for n in directed_sets():
        case("b", n)
        case("b", n, lat=(1, 30), ar_bp=25, r_gap=25, cmd_gap=20, label=n + "_rand")
    # c: throughput, latency 20, no back-pressure
    for n in ("c_burst16", "c_burst8", "c_burst1"):
        case("c", n, lat=(20, 20))
    case("c", "identity_256x192_L64_S512", lat=(20, 20), label="c_sched_identity_256x192_L64_S512")
    case("c", "rot37_256x192_L64_S512", lat=(20, 20), label="c_sched_rot37_256x192_L64_S512")
    case("c", "c_burst16", lat=(20, 20), max_out=4, label="c_burst16_mem_accepts_4")
    for L in (40, 60):                           # latency sweep: short bursts are latency-bound (8 outstanding)
        case("c", "c_burst16", lat=(L, L), label=f"c_burst16_lat{L}")
        case("c", "c_burst1", lat=(L, L), label=f"c_burst1_lat{L}")
        case("c", "rot37_256x192_L64_S512", lat=(L, L), label=f"c_sched_rot37_256x192_L64_S512_lat{L}")
    # d: every schedule again with random ARREADY / latency / RVALID gaps / command gaps (0-30 %)
    for i, n in enumerate(sched):
        pct = (0, 5, 10, 15, 20, 25, 30)
        case("d", n, lat=(1, 40), ar_bp=pct[i % 7], r_gap=pct[(i + 3) % 7], cmd_gap=pct[(i + 5) % 7],
             max_out=4 + i % 5, label=n + "_rand")
    for k in range(4):
        case("d", f"rand{k}", lat=(1, 60), ar_bp=10 * k, r_gap=30 - 10 * k, cmd_gap=15, max_out=4 + k)
    # e: SLVERR on the first and the second burst of a 2-burst command, on a 1-beat command, in a schedule
    case("e", "e_two_bursts", err=0, label="e_err_burst0")
    case("e", "e_two_bursts", err=1, label="e_err_burst1")
    case("e", "e_two_bursts", err=3, label="e_err_burst3_last")
    nb = len(sets["rot37_128x96_L64_S512"][1])
    case("e", "rot37_128x96_L64_S512", lat=(1, 30), ar_bp=20, r_gap=20, err=nb // 2, label="e_err_rot37_mid")
    # g: reset in the middle (master and memory), then the same frame in full
    for n, ab in (("combined_128x96_L64_S512", None), ("rot15_64x64_L32_S32", 1), ("c_burst16", 300)):
        nbeat = sum(e[1] for e in sets[n][1])
        at = ab if ab is not None else nbeat // 2
        case("g", n, lat=(1, 30), ar_bp=20, r_gap=20, cmd_gap=10, abort=at, label=f"g_{n}_reset_at_{at}")
        case("g", n, lat=(1, 30), ar_bp=20, r_gap=20, cmd_gap=10, label=f"g_{n}_after_reset")

    (OUT_DIR / "cases.txt").write_text("".join(" ".join(str(x) for x in c) + "\n" for c in cases))
    tot_b = sum(c[3] for c in cases)
    tot_beats = sum(c[4] for c in cases)
    print(f"{len(cases)} cases, {tot_b} bursts, {tot_beats} beats -> {OUT_DIR}")
    print(f"largest case: {max(c[3] for c in cases)} bursts")


if __name__ == "__main__":
    main()
