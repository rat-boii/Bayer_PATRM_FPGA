"""Job descriptor and result record: round trips, and the C layout against the Python one (step 4.2).

    python -m model.test_job_layout

The C check generates a file of _Static_assert lines from the tables in model/job.py (offset, size and signedness of
every field, record sizes, constants, result codes) and compiles it against sw/include/patrm_job.h with the ARM compiler
and the target's flags, so the sizes are those of the Cortex-A9 build. Wrong layouts must then fail to compile, which
shows the check can detect a difference. The last line is TEST PASS or TEST FAIL: <reason>.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))

from amd_tools import find_arm_gcc           # noqa: E402
from model import job as J                   # noqa: E402
from model import patrm as P                 # noqa: E402

C_FLAGS = ["-std=c11", "-fsyntax-only", "-Wall", "-Wextra", "-Werror", "-DSDT",
           "-mcpu=cortex-a9", "-mfpu=vfpv3", "-mfloat-abi=hard"]
ROT15_64 = (63303, -16962, 278720, 16962, 63303, -243200)
ID_B = (65536, 0, 0, 0, 65536, 0)
STRUCTS = (("patrm_job_desc_t", J.JOB_FIELDS), ("patrm_job_result_t", J.RESULT_FIELDS))
# C name -> value in the Python model
CONSTANTS = {"PATRM_JOB_ADDR": J.JOB_ADDR, "PATRM_RESULT_ADDR": J.RESULT_ADDR, "PATRM_JOB_MAGIC": J.JOB_MAGIC,
             "PATRM_RESULT_MAGIC": J.RESULT_MAGIC, "PATRM_LAYOUT_VERSION": J.LAYOUT_VERSION,
             "PATRM_JOB_MAX_REPEAT": J.JOB_MAX_REPEAT, "PATRM_JOB_MAX_TIMEOUT_MS": J.JOB_MAX_TIMEOUT_MS,
             "PATRM_JOB_FLAG_IRQ_EN": J.JOB_FLAG_IRQ_EN, "PATRM_JOB_FLAG_SRC_CPU": J.JOB_FLAG_SRC_CPU,
             "PATRM_JOB_SIZE": J.JOB_SIZE, "PATRM_RESULT_SIZE": J.RESULT_SIZE, "PATRM_REG_BASE": J.REG_BASE,
             "PATRM_BUF_LO": J.BUF_LO, "PATRM_BUF_HI": J.BUF_HI, "PATRM_COORD_LIMIT_PX": P.COORD_LIMIT_PX}


class Fail(Exception):
    pass


def check(cond, msg):
    if not cond:
        raise Fail(msg)


def rejected(what, func, *args, **kw):
    try:
        func(*args, **kw)
    except J.JobError as e:
        print(f"      {what:<30} -> {e}")
        return
    raise Fail(f"accepted: {what}")


def t1_job_round_trip():
    print("[1] job descriptor round trip")
    cases = [dict(seq=1, W=64, H=64, mode="gray", b=ID_B, block_len=64),
             dict(seq=0xFFFF_FFFF, W=480, H=272, mode="gray", b=ROT15_64, block_len=1, repeat=J.JOB_MAX_REPEAT,
                  timeout_ms=J.JOB_MAX_TIMEOUT_MS, irq=False, src_by_cpu=True, src=0x1100_0000, dst=0x1900_0000)]
    for c in cases:
        data = J.encode_job(**c, block_len_max=64)
        check(len(data) == J.JOB_SIZE, "wrong descriptor size")
        d = J.decode_job(data)
        flags = (J.JOB_FLAG_IRQ_EN if c.get("irq", True) else 0) | (J.JOB_FLAG_SRC_CPU if c.get("src_by_cpu") else 0)
        want = dict(magic=J.JOB_MAGIC, seq=c["seq"], layout=J.LAYOUT_VERSION, mode=0, flags=flags, width=c["W"],
                    height=c["H"], block_len=c["block_len"], src_addr=c.get("src", J.SRC_DEFAULT),
                    dst_addr=c.get("dst", J.DST_DEFAULT), repeat=c.get("repeat", 1),
                    timeout_ms=c.get("timeout_ms", J.JOB_TIMEOUT_MS_DEFAULT), b=tuple(c["b"]), reserved=(0,) * 6)
        check(d == want, f"descriptor changed in the round trip: {d} != {want}")
        check(J.record_words(data)[0] == J.JOB_MAGIC, "magic is not the first word")
    print(f"      {len(cases)} descriptors, {J.JOB_SIZE} bytes each, negative b kept")


def t2_result_round_trip():
    print("[2] result record round trip")
    values, n = {}, 1000
    for name, fmt in J.RESULT_FIELDS:              # every field a different value, so a swap cannot go unnoticed
        if name in ("magic", "layout"):
            continue
        count = len(fmt) > 1 and int(fmt[:-1]) or 1
        values[name] = n if count == 1 else tuple(range(n, n + count))
        n += count
    values["rc"] = J.RC["NO_INTERRUPT"]
    values["cycles_max"] = 0xFFFF_FFFF
    data = J.encode_result(**values)
    check(len(data) == J.RESULT_SIZE, "wrong result size")
    r = J.decode_result(data)
    check(r.pop("rc_name") == "NO_INTERRUPT", "wrong rc name")
    check(r == dict(values, magic=J.RESULT_MAGIC, layout=J.LAYOUT_VERSION), "result changed in the round trip")
    print(f"      {len(J.RESULT_FIELDS)} fields, {J.RESULT_SIZE} bytes, every field distinct")


def t3_rejections():
    print("[3] rejections")
    good = dict(seq=1, W=64, H=64, mode="gray", b=ID_B, block_len=64, block_len_max=64)
    for what, change in (("sequence number 0", dict(seq=0)), ("repeat 0", dict(repeat=0)),
                         ("repeat too large", dict(repeat=J.JOB_MAX_REPEAT + 1)), ("timeout 0", dict(timeout_ms=0)),
                         ("D3: W = 60", dict(W=60)), ("D11: H = 4097", dict(H=4097)),
                         ("D13: BLOCK_LEN = 65", dict(block_len=65)), ("buffer not aligned", dict(src=0x1000_0010)),
                         ("D4: far transform", dict(b=(0, 0, 16385 * 65536, 0, 0, 0)))):
        rejected(what, J.encode_job, **{**good, **change})
    data = J.encode_job(**good)
    rejected("descriptor too short", J.decode_job, data[:-4])
    rejected("descriptor magic 0", J.decode_job, bytes(4) + data[4:])
    rejected("descriptor other layout", J.decode_job, data[:8] + (2).to_bytes(4, "little") + data[12:])
    res = J.encode_result(seq=1)
    rejected("result too long", J.decode_result, res + bytes(4))
    rejected("result magic 0", J.decode_result, bytes(4) + res[4:])
    rejected("result other layout", J.decode_result, res[:8] + (2).to_bytes(4, "little") + res[12:])
    rejected("result field too large", J.encode_result, cycles=1 << 32)
    rejected("result field unknown", J.encode_result, nonsense=1)


def c_source(structs=STRUCTS, constants=None, rc=None):
    lines = ['#include <stddef.h>', '#include <stdint.h>', '#include "patrm_job.h"', '#include "patrm_defs.h"', '']
    for ctype, fields in structs:
        lines.append(f'_Static_assert(sizeof({ctype}) == {J.record_size(fields)}U, "{ctype} size");')
        for name, (offset, size, count, signed) in J.field_layout(fields).items():
            member = f"(({ctype} *)0)->{name}"
            element = f"{member}[0]" if count > 1 else member
            kind = "int32_t" if signed else "uint32_t"
            lines += [f'_Static_assert(offsetof({ctype}, {name}) == {offset}U, "{ctype}.{name} offset");',
                      f'_Static_assert(sizeof({member}) == {size}U, "{ctype}.{name} size");',
                      f'_Static_assert(_Generic({element}, {kind}: 1, default: 0), "{ctype}.{name} type");']
    for name, value in (CONSTANTS if constants is None else constants).items():
        lines.append(f'_Static_assert({name} == {value}U, "{name}");')
    for name, value in (J.RC if rc is None else rc).items():
        lines.append(f'_Static_assert(PATRM_RC_{name} == {value}, "PATRM_RC_{name}");')
    return "\n".join(lines) + "\n"


def compile_c(gcc, text, folder, name):
    path = Path(folder) / name
    path.write_text(text, newline="\n")
    p = subprocess.run([str(gcc)] + C_FLAGS + ["-I", str(ROOT / "sw" / "include"), str(path)],
                       capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def t4_c_layout():
    print("[4] C layout against the Python tables")
    gcc = find_arm_gcc()
    check(gcc is not None, "arm-none-eabi-gcc not found (README, New laptop setup, step 3)")
    print(f"      compiler {gcc}")
    print(f"      flags {' '.join(C_FLAGS)}")
    swapped = list(J.JOB_FIELDS)
    swapped[2], swapped[3] = swapped[3], swapped[2]            # same types, so only the offsets show it
    moved = list(J.RESULT_FIELDS)
    moved[7], moved[8] = moved[8], moved[7]
    unsigned_b = [(n, "6I" if n == "b" else f) for n, f in J.JOB_FIELDS]
    short = list(J.RESULT_FIELDS[:-1]) + [("reserved", "6I")]
    wrong = [("two job fields swapped", dict(structs=((STRUCTS[0][0], swapped), STRUCTS[1])), "offset"),
             ("two result fields swapped", dict(structs=(STRUCTS[0], (STRUCTS[1][0], moved))), "offset"),
             ("b unsigned", dict(structs=((STRUCTS[0][0], unsigned_b), STRUCTS[1])), "patrm_job_desc_t.b type"),
             ("result 4 bytes shorter", dict(structs=(STRUCTS[0], (STRUCTS[1][0], short))), "patrm_job_result_t size"),
             ("wrong magic", dict(constants={**CONSTANTS, "PATRM_JOB_MAGIC": J.JOB_MAGIC + 1}), "PATRM_JOB_MAGIC"),
             ("wrong buffer limit", dict(constants={**CONSTANTS, "PATRM_BUF_HI": J.BUF_HI + 4096}), "PATRM_BUF_HI"),
             ("wrong result code", dict(rc={**J.RC, "TIMEOUT": 99}), "PATRM_RC_TIMEOUT")]
    with tempfile.TemporaryDirectory() as folder:
        text = c_source()
        rc, out = compile_c(gcc, text, folder, "layout_ok.c")
        check(rc == 0, f"the C layout differs from the Python one:\n{out[:1500]}")
        print(f"      {text.count('_Static_assert')} static assertions compile: C and Python agree")
        for i, (what, kw, needle) in enumerate(wrong):
            rc, out = compile_c(gcc, c_source(**kw), folder, f"layout_bad{i}.c")
            check(rc != 0, f"the check did not notice: {what}")
            check(needle in out, f"{what}: failed for another reason:\n{out[:800]}")
            print(f"      must not compile: {what:<26} -> rejected")


def main():
    try:
        for t in (t1_job_round_trip, t2_result_round_trip, t3_rejections, t4_c_layout):
            t()
    except Fail as e:
        print(f"TEST FAIL: {e}")
        return 1
    print("TEST PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
