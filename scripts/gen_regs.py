"""Generate the register headers from spec/regs.json (the single source of truth, step 2.1).

Outputs (each starts with "generated from spec/regs.json, do not edit"):
  sw/include/patrm_regs.h   C #defines: offsets, reset values, field shift/width/mask, enums, constants
  rtl/patrm_regs.vh         Verilog-2001 localparams (include it INSIDE a module body)
  model/regs.py             Python tables + pack/unpack helpers

The JSON is validated first (aligned, non-overlapping offsets, no gaps, fields fit, resets
consistent, enum values fit their fields). Output is deterministic: same JSON -> same bytes.

Usage (repo root):
  python scripts/gen_regs.py            validate + write the three files
  python scripts/gen_regs.py --check    validate + exit 1 if any written file is out of date
  python scripts/gen_regs.py --table    validate + print the register map as a Markdown table
"""
import argparse
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SPEC = REPO / "spec" / "regs.json"
OUT_H = REPO / "sw" / "include" / "patrm_regs.h"
OUT_VH = REPO / "rtl" / "patrm_regs.vh"
OUT_PY = REPO / "model" / "regs.py"

BANNER = "generated from spec/regs.json, do not edit"
FIELD_ACCESS = {"RW", "RO", "W1C", "WP"}
BUILD = "build"     # reset value fixed per bitstream by synthesis parameters


class SpecError(ValueError):
    pass


def _int(v, what):
    if isinstance(v, bool):
        raise SpecError(f"{what}: boolean is not a number")
    if isinstance(v, int):
        return v
    if isinstance(v, str):
        try:
            return int(v, 0)
        except ValueError:
            pass
    raise SpecError(f"{what}: {v!r} is not an integer")


def load(path=SPEC):
    with open(path, encoding="utf-8") as f:
        return normalise(json.load(f))


def normalise(spec):
    """Validate the JSON and return a cleaned copy with integer offsets/resets. Raises SpecError."""
    dw = _int(spec.get("data_width"), "data_width")
    if dw != 32:
        raise SpecError("data_width must be 32")
    abits = _int(spec.get("addr_bits"), "addr_bits")

    consts = {}
    for c in spec.get("constants", []):
        if c["name"] in consts:
            raise SpecError(f"constant {c['name']} defined twice")
        consts[c["name"]] = _int(c["value"], f"constant {c['name']}")

    enums = {}
    for e in spec.get("enums", []):
        if e["name"] in enums:
            raise SpecError(f"enum {e['name']} defined twice")
        names, vals = set(), set()
        for v in e["values"]:
            val = _int(v["value"], f"enum {e['name']}.{v['name']}")
            if v["name"] in names or val in vals or val < 0:
                raise SpecError(f"enum {e['name']}: duplicate or negative entry {v['name']}={val}")
            names.add(v["name"])
            vals.add(val)
        enums[e["name"]] = [dict(v, value=_int(v["value"], "")) for v in e["values"]]

    regs, seen_names, seen_off = [], set(), {}
    for r in spec["registers"]:
        name = r["name"]
        if name in seen_names:
            raise SpecError(f"register {name} defined twice")
        seen_names.add(name)
        off = _int(r["offset"], f"{name}.offset")
        if off % 4:
            raise SpecError(f"{name}: offset 0x{off:02X} is not 32-bit aligned")
        if not 0 <= off < (1 << abits):
            raise SpecError(f"{name}: offset 0x{off:02X} does not fit in {abits} address bits")
        if off in seen_off:
            raise SpecError(f"{name}: offset 0x{off:02X} overlaps {seen_off[off]}")
        seen_off[off] = name
        if not r.get("description"):
            raise SpecError(f"{name}: missing description")

        build_reset = r["reset"] == BUILD
        fields, used, fnames, accesses = [], 0, set(), []
        reset_from_fields = 0
        for f in r["fields"]:
            fn = f"{name}.{f['name']}"
            if f["name"] in fnames:
                raise SpecError(f"{fn} defined twice")
            fnames.add(f["name"])
            lsb, width = _int(f["lsb"], fn + ".lsb"), _int(f["width"], fn + ".width")
            if lsb < 0 or width < 1 or lsb + width > 32:
                raise SpecError(f"{fn}: bits [{lsb + width - 1}:{lsb}] do not fit in 32 bits")
            mask = ((1 << width) - 1) << lsb
            if used & mask:
                raise SpecError(f"{fn}: bits [{lsb + width - 1}:{lsb}] overlap another field of {name}")
            used |= mask
            acc = f["access"]
            if acc not in FIELD_ACCESS:
                raise SpecError(f"{fn}: unknown access {acc!r}")
            accesses.append("RW" if acc == "WP" else acc)
            if not f.get("description"):
                raise SpecError(f"{fn}: missing description")
            signed = bool(f.get("signed", False))
            if f["reset"] == BUILD:
                if not build_reset or acc != "RO":
                    raise SpecError(f"{fn}: reset 'build' only allowed for RO fields of a 'build' register")
                freset = None
            else:
                if build_reset:
                    raise SpecError(f"{fn}: every field of a 'build' register must have reset 'build'")
                freset = _int(f["reset"], fn + ".reset")
                lo, hi = ((-(1 << (width - 1)), (1 << (width - 1)) - 1) if signed else (0, (1 << width) - 1))
                if not lo <= freset <= hi:
                    raise SpecError(f"{fn}: reset {freset} does not fit {width} {'signed' if signed else 'unsigned'} bits")
                if acc == "WP" and freset != 0:
                    raise SpecError(f"{fn}: WP fields read 0, reset must be 0")
                reset_from_fields |= (freset & ((1 << width) - 1)) << lsb
            if "enum" in f:
                if f["enum"] not in enums:
                    raise SpecError(f"{fn}: unknown enum {f['enum']}")
                big = [v for v in enums[f["enum"]] if v["value"] >= (1 << width)]
                if big:
                    raise SpecError(f"{fn}: enum value {big[0]['name']}={big[0]['value']} does not fit {width} bits")
            fields.append(dict(name=f["name"], lsb=lsb, width=width, mask=mask, access=acc, reset=freset,
                               signed=signed, enum=f.get("enum"), description=f["description"]))

        # register access must summarise the field accesses (WP counts as RW)
        summary = "/".join(dict.fromkeys(sorted(set(accesses), key=["RW", "RO", "W1C"].index)))
        if r["access"] != summary:
            raise SpecError(f"{name}: access {r['access']!r} does not match its fields ({summary!r})")
        if build_reset:
            reset = None
        else:
            reset = _int(r["reset"], f"{name}.reset")
            if reset != reset_from_fields:
                raise SpecError(f"{name}: reset 0x{reset:08X} != field resets 0x{reset_from_fields:08X}")
        regs.append(dict(name=name, offset=off, access=r["access"], reset=reset, used=used,
                         description=r["description"], fields=fields))

    regs.sort(key=lambda r: r["offset"])
    # no unexplained gaps: offsets 0, 4, 8, ... up to the last register, unless listed in "reserved"
    reserved = {_int(x["offset"], "reserved.offset"): x for x in spec.get("reserved", [])}
    for x, rr in reserved.items():
        if not rr.get("description"):
            raise SpecError(f"reserved 0x{x:02X} needs a description")
        if x in seen_off:
            raise SpecError(f"reserved 0x{x:02X} is also register {seen_off[x]}")
    for off in range(0, regs[-1]["offset"] + 4, 4):
        if off not in seen_off and off not in reserved:
            raise SpecError(f"unexplained gap at offset 0x{off:02X}")

    # cross-checks between constants and fields
    reg = {r["name"]: r for r in regs}
    fld = {(r["name"], f["name"]): f for r in regs for f in r["fields"]}
    for rn, fn in (("WIDTH", "W"), ("HEIGHT", "H"), ("BLOCK_LEN", "L"), ("BUILD_ID", "BLOCK_LEN_MAX")):
        if fld[(rn, fn)]["width"] != consts["SIZE_BITS"]:
            raise SpecError(f"{rn}.{fn} must be SIZE_BITS = {consts['SIZE_BITS']} wide")
    if consts["MAX_SIZE"] >= (1 << consts["SIZE_BITS"]):
        raise SpecError("MAX_SIZE does not fit SIZE_BITS")
    if fld[("BUILD_ID", "VERSION")]["width"] < consts["VERSION"].bit_length():
        raise SpecError("VERSION does not fit BUILD_ID.VERSION")
    if consts["VERSION"] != _int(spec.get("version"), "version"):
        raise SpecError("constant VERSION != top-level version")
    if fld[("BUILD_ID", "MODES")]["width"] < len(enums["MODE"]):
        raise SpecError("BUILD_ID.MODES needs one bit per mode")
    if consts["ADDR_ALIGN"] & (consts["ADDR_ALIGN"] - 1):
        raise SpecError("ADDR_ALIGN must be a power of two")
    del reg
    return dict(title=spec["title"], version=consts["VERSION"], addr_bits=abits, notes=spec.get("notes", []),
                constants=spec["constants"], const=consts, enums=enums,
                enum_desc={e["name"]: e.get("description", "") for e in spec.get("enums", [])},
                registers=regs, reserved=reserved)


# ---------------------------------------------------------------------------
# Generators
# ---------------------------------------------------------------------------

def _hex32(v):
    return f"0x{v & 0xFFFFFFFF:08X}"


def gen_c(s):
    L = [f"/* {BANNER} */", f"/* {s['title']}, version {s['version']} */", "",
         "#ifndef PATRM_REGS_H", "#define PATRM_REGS_H", ""]
    L.append("/* Constants */")
    for c in s["constants"]:
        L.append(f"#define PATRM_{c['name']:<28} {s['const'][c['name']]}U   /* {c['description']} */")
    L.append("")
    for e, vals in s["enums"].items():
        L.append(f"/* {e}: {s['enum_desc'][e]} */")
        for v in vals:
            L.append(f"#define PATRM_{e}_{v['name']:<24} {v['value']}U   /* {v['description']} */")
        L.append("")
    for r in s["registers"]:
        n = r["name"]
        L.append(f"/* 0x{r['offset']:02X} {n} ({r['access']}): {r['description']} */")
        L.append(f"#define PATRM_{n}_OFFSET{'':<{max(1, 22 - len(n))}} 0x{r['offset']:02X}U")
        if r["reset"] is not None:
            L.append(f"#define PATRM_{n}_RESET{'':<{max(1, 23 - len(n))}} {_hex32(r['reset'])}U")
        for f in r["fields"]:
            p = f"PATRM_{n}_{f['name']}"
            L.append(f"#define {p}_SHIFT{'':<{max(1, 28 - len(p))}} {f['lsb']}U")
            L.append(f"#define {p}_WIDTH{'':<{max(1, 28 - len(p))}} {f['width']}U")
            L.append(f"#define {p}_MASK{'':<{max(1, 29 - len(p))}} {_hex32(f['mask'])}U   /* {f['access']}: {f['description']} */")
        L.append("")
    L += ["#endif /* PATRM_REGS_H */", ""]
    return "\n".join(L)


def gen_vh(s):
    ab = s["addr_bits"]
    L = [f"// {BANNER}", f"// {s['title']}, version {s['version']}",
         "// Verilog-2001 localparams. `include this file INSIDE a module body (no include guard on purpose).", ""]
    L.append(f"localparam integer PATRM_ADDR_BITS = {ab};")
    for c in s["constants"]:
        L.append(f"localparam integer PATRM_{c['name']} = {s['const'][c['name']]};   // {c['description']}")
    L.append("")
    fld_w = {f["enum"]: f["width"] for r in s["registers"] for f in r["fields"] if f["enum"]}
    for e, vals in s["enums"].items():
        w = fld_w[e]
        L.append(f"// {e}: {s['enum_desc'][e]}")
        for v in vals:
            L.append(f"localparam [{w - 1}:0] PATRM_{e}_{v['name']} = {w}'d{v['value']};   // {v['description']}")
        L.append("")
    for r in s["registers"]:
        n = r["name"]
        L.append(f"// 0x{r['offset']:02X} {n} ({r['access']}): {r['description']}")
        L.append(f"localparam [{ab - 1}:0] PATRM_REG_{n} = {ab}'h{r['offset']:02X};")
        if r["reset"] is not None:
            L.append(f"localparam [31:0] PATRM_{n}_RESET = 32'h{r['reset'] & 0xFFFFFFFF:08X};")
        for f in r["fields"]:
            p = f"PATRM_{n}_{f['name']}"
            L.append(f"localparam integer {p}_LSB = {f['lsb']};")
            L.append(f"localparam integer {p}_W = {f['width']};   // {f['access']}: {f['description']}")
        L.append("")
    return "\n".join(L)


def gen_py(s):
    regs = []
    for r in s["registers"]:
        fields = [dict(name=f["name"], lsb=f["lsb"], width=f["width"], access=f["access"], reset=f["reset"],
                       signed=f["signed"], enum=f["enum"]) for f in r["fields"]]
        regs.append(dict(name=r["name"], offset=r["offset"], access=r["access"], reset=r["reset"], fields=fields))
    L = [f'"""{BANNER}.', "", f"{s['title']}, version {s['version']}.",
         "Tables plus pack/unpack helpers; see scripts/gen_regs.py.", '"""', ""]
    L.append(f"VERSION = {s['version']}")
    L.append(f"ADDR_BITS = {s['addr_bits']}")
    L.append("")
    L.append("# Constants")
    for c in s["constants"]:
        if c["name"] != "VERSION":
            L.append(f"{c['name']} = {s['const'][c['name']]}   # {c['description']}")
    L.append("")
    for e, vals in s["enums"].items():
        L.append(f"# {e}: {s['enum_desc'][e]}")
        L.append(f"{e} = {{" + ", ".join(f"{v['name']!r}: {v['value']}" for v in vals) + "}")
    L.append("")
    L.append("# Registers in offset order. reset None = fixed per build (synthesis parameters).")
    L.append("REGISTERS = [")
    for r in regs:
        L.append(f"    {{'name': {r['name']!r}, 'offset': 0x{r['offset']:02X}, 'access': {r['access']!r}, "
                 f"'reset': {'None' if r['reset'] is None else _hex32(r['reset'])}, 'fields': [")
        for f in r["fields"]:
            L.append(f"        {f!r},")
        L.append("    ]},")
    L.append("]")
    L += ["",
          "REG = {r['name']: r for r in REGISTERS}",
          "OFFSET = {r['name']: r['offset'] for r in REGISTERS}",
          "NAME = {r['offset']: r['name'] for r in REGISTERS}",
          "",
          "",
          "def field(reg, name):",
          "    for f in REG[reg]['fields']:",
          "        if f['name'] == name:",
          "            return f",
          "    raise KeyError(f'{reg}.{name}')",
          "",
          "",
          "def field_range(reg, name):",
          "    \"\"\"(lowest, highest) value the field can hold.\"\"\"",
          "    f = field(reg, name)",
          "    if f['signed']:",
          "        return -(1 << (f['width'] - 1)), (1 << (f['width'] - 1)) - 1",
          "    return 0, (1 << f['width']) - 1",
          "",
          "",
          "def pack(reg, **values):",
          "    \"\"\"32-bit register value from field values; raises ValueError if a value does not fit.",
          "    Fields not given are 0.\"\"\"",
          "    names = {f['name'] for f in REG[reg]['fields']}",
          "    word = 0",
          "    for name, v in values.items():",
          "        if name not in names:",
          "            raise ValueError(f'{reg} has no field {name}')",
          "        f = field(reg, name)",
          "        lo, hi = field_range(reg, name)",
          "        if not isinstance(v, int) or not lo <= v <= hi:",
          "            raise ValueError(f'{reg}.{name} = {v} does not fit {f[\"width\"]} '",
          "                             f'{\"signed\" if f[\"signed\"] else \"unsigned\"} bits ({lo}..{hi})')",
          "        word |= (v & ((1 << f['width']) - 1)) << f['lsb']",
          "    return word",
          "",
          "",
          "def unpack(reg, word):",
          "    \"\"\"Field values from a 32-bit register value (signed fields sign-extended).\"\"\"",
          "    out = {}",
          "    for f in REG[reg]['fields']:",
          "        v = (word >> f['lsb']) & ((1 << f['width']) - 1)",
          "        if f['signed'] and v >> (f['width'] - 1):",
          "            v -= 1 << f['width']",
          "        out[f['name']] = v",
          "    return out",
          ""]
    return "\n".join(L)


def outputs(s):
    return {OUT_H: gen_c(s), OUT_VH: gen_vh(s), OUT_PY: gen_py(s)}


def table(s):
    L = ["| offset | register | access | reset | fields (bits, access) |", "|---|---|---|---|---|"]
    for r in s["registers"]:
        fl = ", ".join(
            f"{f['name']} [{f['lsb'] + f['width'] - 1}:{f['lsb']}]" if f["width"] > 1 else f"{f['name']} [{f['lsb']}]"
            for f in r["fields"])
        fl += "" if len({f["access"] for f in r["fields"]}) == 1 else \
            " (" + ", ".join(f"{f['name']} {f['access']}" for f in r["fields"]) + ")"
        if any(f["signed"] for f in r["fields"]):
            fl += " signed Q15.16"
        rst = "build" if r["reset"] is None else _hex32(r["reset"])
        L.append(f"| 0x{r['offset']:02X} | {r['name']} | {r['access']} | {rst} | {fl} |")
    return "\n".join(L)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="do not write; exit 1 if a file is out of date")
    ap.add_argument("--table", action="store_true", help="print the register map as a Markdown table")
    args = ap.parse_args(argv)
    try:
        s = load()
    except SpecError as e:
        print(f"regs.json INVALID: {e}")
        return 1
    print(f"regs.json valid: {len(s['registers'])} registers, offsets 0x00..0x{s['registers'][-1]['offset']:02X}, "
          f"all 32-bit aligned, no overlaps, no gaps, every field fits")
    if args.table:
        print(table(s))
    stale = 0
    for path, text in outputs(s).items():
        rel = path.relative_to(REPO).as_posix()
        data = text.encode("utf-8")
        old = path.read_bytes() if path.is_file() else None
        if args.check:
            # compare ignoring CRLF vs LF (git core.autocrlf may convert on checkout)
            if old is None or old.replace(b"\r\n", b"\n") != data:
                print(f"OUT OF DATE: {rel}")
                stale += 1
        elif not args.table:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            print(f"wrote {rel} ({len(data)} bytes{', unchanged' if old == data else ''})")
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())
