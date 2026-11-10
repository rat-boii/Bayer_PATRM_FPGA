"""Step 2.1 checks: spec/regs.json, generated headers, model/job.py.

Run from the repo root:  python -m model.test_regs   (or: python model/test_regs.py)
Prints one line per check, then exactly one final line: TEST PASS or TEST FAIL: <reason>.

Uses arm-none-eabi-gcc (or gcc) for the C header if one is found, and xvlog for the Verilog header.
"""

import copy
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if __package__ in (None, ""):
    sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "scripts"))

import gen_regs                      # noqa: E402
from amd_tools import find_tool      # noqa: E402
from model import job as J           # noqa: E402

WORKED_B = (52429, -39322, 131072, 39322, 52429, 65536)


class Fail(Exception):
    pass


def check(cond, msg):
    if not cond:
        raise Fail(msg)


def t1_validate():
    s = gen_regs.load()
    regs = s["registers"]
    offs = [r["offset"] for r in regs]
    check(len(set(offs)) == len(offs), "duplicate offsets")
    check(all(o % 4 == 0 for o in offs), "unaligned offset")
    check(offs == list(range(0, 4 * len(regs), 4)), "offsets not contiguous")
    for r in regs:
        used = 0
        for f in r["fields"]:
            check(f["lsb"] + f["width"] <= 32 and not used & f["mask"], f"{r['name']}.{f['name']} does not fit")
            used |= f["mask"]
    # the validator must catch broken specs
    with open(gen_regs.SPEC, encoding="utf-8") as fh:
        raw = json.load(fh)
    bad_cases = []

    def mutate(desc, fn):
        sp = copy.deepcopy(raw)
        fn(sp)
        try:
            gen_regs.normalise(sp)
        except gen_regs.SpecError as e:
            bad_cases.append(f"{desc} -> '{e}'")
            return
        raise Fail(f"validator accepted a broken spec: {desc}")

    def rg(sp, n):
        return next(r for r in sp["registers"] if r["name"] == n)

    mutate("overlapping offset", lambda sp: rg(sp, "B12").update(offset="0x18"))
    mutate("unaligned offset", lambda sp: rg(sp, "B12").update(offset="0x1A"))
    mutate("gap", lambda sp: sp["registers"].remove(rg(sp, "B12")))
    mutate("field past bit 31", lambda sp: rg(sp, "STATUS")["fields"][3].update(lsb=30))
    mutate("overlapping fields", lambda sp: rg(sp, "CTRL")["fields"][2].update(lsb=2))
    mutate("reset does not match fields", lambda sp: rg(sp, "B11").update(reset="0x0"))
    mutate("enum value too wide", lambda sp: rg(sp, "STATUS")["fields"][3].update(width=2))
    print(f"[1] regs.json valid: {len(regs)} registers 0x00..0x{offs[-1]:02X}, aligned, no overlaps, no gaps, "
          f"all fields fit; validator rejects {len(bad_cases)}/7 broken variants")
    for c in bad_cases:
        print(f"      {c}")
    print(gen_regs.table(s))


def t2_generated_current_and_deterministic():
    s1 = gen_regs.outputs(gen_regs.load())
    s2 = gen_regs.outputs(gen_regs.load())
    for path, text in s1.items():
        check(text == s2[path], f"{path.name}: two generations differ")
        with open(path, "rb") as f:
            check(f.read().replace(b"\r\n", b"\n") == text.encode("utf-8"),
                  f"{path.name} is out of date; run python scripts/gen_regs.py")
        first = text.splitlines()[0]
        check(gen_regs.BANNER in first, f"{path.name}: first line lacks the banner")
    # run the script twice, hash the files after each run
    hashes = []
    for _ in range(2):
        r = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "gen_regs.py")], capture_output=True, text=True)
        check(r.returncode == 0, f"gen_regs.py failed: {r.stdout}{r.stderr}")
        hashes.append({p.name: hashlib.sha256(p.read_bytes()).hexdigest()[:16] for p in s1})
    check(hashes[0] == hashes[1], f"gen_regs.py runs differ: {hashes}")
    print(f"[2] gen_regs.py run twice: byte-identical ({', '.join(f'{k} {v}' for k, v in hashes[0].items())}); "
          f"files on disk match regs.json; each starts with the banner")


def t3_c_header():
    cc = None
    for name in ("gcc", "arm-none-eabi-gcc"):
        p = shutil.which(name)
        if p and "WindowsApps" not in p:
            cc = p
            break
    if cc is None:
        print("[3] C header: NOT CHECKED (no gcc or arm-none-eabi-gcc found)")
        return
    with tempfile.TemporaryDirectory() as td:
        src = os.path.join(td, "t.c")
        with open(src, "w") as f:
            f.write('#include "patrm_regs.h"\n#include "patrm_regs.h"\n'
                    "_Static_assert(PATRM_BUILD_ID_OFFSET == 0x68U, \"offset\");\n"
                    "_Static_assert((PATRM_STATUS_ERR_CODE_MASK >> PATRM_STATUS_ERR_CODE_SHIFT) >= PATRM_ERR_START_BUSY, \"err\");\n"
                    "_Static_assert(PATRM_B11_RESET == 0x00010000U, \"reset\");\n"
                    "int main(void) { return (int)PATRM_CTRL_START_MASK; }\n")
        r = subprocess.run([cc, "-std=c99", "-Wall", "-Wextra", "-Werror", "-fsyntax-only",
                            "-I", os.path.join(ROOT, "sw", "include"), src], capture_output=True, text=True)
        check(r.returncode == 0, f"C header does not compile: {r.stderr}")
    ver = subprocess.run([cc, "--version"], capture_output=True, text=True).stdout.splitlines()[0]
    print(f"[3] patrm_regs.h: {os.path.basename(cc)} -std=c99 -Wall -Wextra -Werror -fsyntax-only OK "
          f"(included twice, 3 static asserts) [{ver}]")


def t4_verilog_header():
    xvlog = find_tool("xvlog")[0]
    if xvlog is None:
        raise Fail("xvlog not found")
    work = os.path.join(ROOT, "build", "regs_check")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    with open(os.path.join(work, "regs_wrap.v"), "w") as f:
        f.write("// two modules include the header, as the RTL will\n"
                "module regs_wrap_a(output [6:0] a, output [31:0] r);\n"
                "`include \"patrm_regs.vh\"\n"
                "assign a = PATRM_REG_BUILD_ID;\nassign r = PATRM_B11_RESET;\nendmodule\n"
                "module regs_wrap_b(output [3:0] e, output [7:0] w);\n"
                "`include \"patrm_regs.vh\"\n"
                "assign e = PATRM_ERR_START_BUSY;\nassign w = PATRM_STATUS_ERR_CODE_W;\nendmodule\n")
    r = subprocess.run([str(xvlog), "-i", os.path.join(ROOT, "rtl"), "regs_wrap.v"], cwd=work,
                       capture_output=True, text=True, shell=str(xvlog).lower().endswith(".bat"))
    log = r.stdout + r.stderr
    check(r.returncode == 0 and "ERROR" not in log, f"xvlog failed:\n{log}")
    warns = [l for l in log.splitlines() if "WARNING" in l]
    print(f"[4] patrm_regs.vh: xvlog compiles a 2-module wrapper OK, {len(warns)} warnings ({xvlog})")
    for w in warns:
        print("      " + w)


def t5_py_import():
    from model import regs as R
    check(R.OFFSET["BUILD_ID"] == 0x68 and R.ERR["START_BUSY"] == 5 and R.MAX_SIZE == 4096, "regs.py content")
    check(R.unpack("B12", R.pack("B12", VALUE=-39322))["VALUE"] == -39322, "signed round trip")
    try:
        R.pack("WIDTH", W=8192)
        raise Fail("pack accepted W=8192 in a 13-bit field")
    except ValueError:
        pass
    print(f"[5] model/regs.py imports: {len(R.REGISTERS)} registers; pack/unpack round-trip signed; "
          f"WIDTH=8192 refused by the 13-bit field")


def t6_worked_example():
    J.check_regs_current()
    writes, start = J.register_image(640, 480, "bayer_a", WORKED_B, 16)
    img = J.as_dict(writes)
    from model import regs as R
    o = R.OFFSET
    check((img[o["T_B_X"]], img[o["T_B_Y"]]) == (39321, 45875), "T_B != (39321, 45875)")
    check(writes[-1][1] == "CTRL" and start == 0b1011, "CTRL must be last, START=1 MODE=1 IRQ_EN=1")
    check(set(img) == {0x00} | set(range(0x08, 0x54, 4)), "register image must cover CTRL and 0x08..0x50")
    print("[6] worked example, Bayer A, 640x480, BLOCK_LEN 16: T_B = (39321, 45875) as required")
    print(J.format_image(writes))


def t7_rejections():
    cases = [
        ("W=644 gray", dict(W=644, H=480, mode="gray", b=WORKED_B, block_len=16)),
        ("W=644 Bayer A", dict(W=644, H=480, mode="bayer_a", b=WORKED_B, block_len=16)),
        ("D4: b11=40.0", dict(W=640, H=480, mode="gray", b=(40 << 16, 0, 0, 0, 65536, 0), block_len=16)),
        ("BLOCK_LEN=0", dict(W=640, H=480, mode="bayer_a", b=WORKED_B, block_len=0)),
        ("BLOCK_LEN > BLOCK_LEN_MAX", dict(W=640, H=480, mode="gray", b=WORKED_B, block_len=65, block_len_max=64)),
        ("W=4112 (D11)", dict(W=4112, H=480, mode="gray", b=WORKED_B, block_len=16)),
        ("Bayer H odd", dict(W=640, H=481, mode="bayer_b", b=WORKED_B, block_len=16)),
        ("bad mode", dict(W=640, H=480, mode="rgb", b=WORKED_B, block_len=16)),
        ("SRC not 4 KB aligned", dict(W=640, H=480, mode="gray", b=WORKED_B, block_len=16, src=0x1000_0800)),
        ("buffers overlap", dict(W=640, H=480, mode="gray", b=WORKED_B, block_len=16, dst=0x1000_1000)),
    ]
    print("[7] rejections:")
    for desc, kw in cases:
        try:
            J.register_image(**kw)
        except J.JobError as e:
            print(f"      {desc:<26} -> {e}")
            continue
        raise Fail(f"job.py accepted: {desc}")
    # the CLI exits 1 with the message
    r = subprocess.run([sys.executable, "-m", "model.job", "--size", "644x480", "--mode", "gray", "--block-len", "16"],
                       cwd=ROOT, capture_output=True, text=True)
    check(r.returncode == 1 and r.stdout.startswith("JOB REJECTED: D3"), f"CLI did not reject W=644: {r.stdout}")
    print(f"      CLI --size 644x480 -> exit 1, '{r.stdout.strip()}'")


def main():
    try:
        for t in (t1_validate, t2_generated_current_and_deterministic, t3_c_header, t4_verilog_header,
                  t5_py_import, t6_worked_example, t7_rejections):
            t()
    except Fail as e:
        print(f"TEST FAIL: {e}")
        return 1
    print("TEST PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
