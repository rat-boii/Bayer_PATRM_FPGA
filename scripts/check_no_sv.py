"""D17 check: no SystemVerilog in our sources.

    python scripts/check_no_sv.py            file and flag check (called by scripts/sim.py before compiling)
    python scripts/check_no_sv.py --syntax   also scan rtl/ and tb/ for SystemVerilog-only syntax (audit)

Fails (exit 1) on:
  - any .sv / .svh file in the repo (build/, .git/ and other ignored tool output are skipped);
  - an -sv / --sv flag or a .sv / .svh source in scripts/*.py, vivado/*.tcl or any .f file list;
  - with --syntax: a SystemVerilog-only construct in rtl/ or tb/ (comments and strings are ignored).
sim.py also passes its own source list and xvlog command line to check().
"""
import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SKIP_DIRS = {".git", "build", ".Xil", "xsim.dir", "__pycache__", ".venv", "venv"}
SV_EXT = {".sv", ".svh"}
THIS = Path(__file__).resolve()

# -sv / --sv as a tool flag (not part of a longer word such as -svf), or a .sv / .svh file name
FLAG_RE = re.compile(r"(?<![\w-])--?sv(?![\w-])|\.svh?(?![\w.])")

KEYWORDS = ("logic bit byte int shortint longint always_ff always_comb always_latch typedef enum struct union "
            "interface modport package import unique priority assert assume cover property string foreach "
            "break continue").split()
SYNTAX_RES = [
    (re.compile(r"(?<![\w$`.])(" + "|".join(KEYWORDS) + r")(?![\w$])"), "SystemVerilog keyword"),
    (re.compile(r"\+\+|--"), "++ / -- operator"),
    (re.compile(r"(?<![<>=!])(\+|-|\*|/|%|&|\||\^|<<|>>|<<<|>>>)=(?!=)"), "compound assignment"),
    (re.compile(r"(?<![\w'])'[01xXzZ](?![\w'])"), "'0 / '1 fill literal"),
    (re.compile(r"\$(error|fatal|info|warning|urandom|urandom_range)\b"), "SystemVerilog system task"),
]


def repo_files():
    for p in REPO_ROOT.rglob("*"):
        if p.is_file() and not (set(p.relative_to(REPO_ROOT).parts[:-1]) & SKIP_DIRS):
            yield p


def strip_code(text):
    """Blank out comments and string literals, keeping line numbers."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("\n" * text.count("\n", i, j))
            i = j
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append('""')
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def check(sources=(), command=()):
    """Return a list of problems (empty = OK). sources / command: what sim.py is about to compile."""
    bad = []
    for p in repo_files():
        if p.suffix.lower() in SV_EXT:
            bad.append(f"{p.relative_to(REPO_ROOT).as_posix()}: SystemVerilog file")
    scan = [p for p in repo_files() if p != THIS and (
        p.suffix == ".f" or (p.suffix == ".py" and p.parent.name == "scripts")
        or (p.suffix == ".tcl" and p.parent.name == "vivado"))]
    for p in scan:
        for ln, line in enumerate(p.read_text(errors="replace").splitlines(), 1):
            code = line.split("#")[0] if p.suffix != ".f" else line.split("//")[0].split("#")[0]
            if FLAG_RE.search(code):
                bad.append(f"{p.relative_to(REPO_ROOT).as_posix()}:{ln}: -sv flag or .sv file: {line.strip()}")
    for s in sources:
        if Path(s).suffix.lower() in SV_EXT:
            bad.append(f"{s}: SystemVerilog source on the compile list")
    for a in command:
        if str(a).lower() in ("-sv", "--sv"):
            bad.append(f"compile command contains {a}")
    return bad


def syntax_hits(dirs=("rtl", "tb")):
    hits = []
    for d in dirs:
        for p in sorted((REPO_ROOT / d).rglob("*")):
            if p.suffix not in (".v", ".vh"):
                continue
            for ln, line in enumerate(strip_code(p.read_text(errors="replace")).splitlines(), 1):
                for rx, what in SYNTAX_RES:
                    for m in rx.finditer(line):
                        hits.append(f"{p.relative_to(REPO_ROOT).as_posix()}:{ln}: {what}: {m.group(0)}")
    return hits


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--syntax", action="store_true", help="also scan rtl/ and tb/ for SystemVerilog-only syntax")
    args = ap.parse_args()
    bad = check()
    if args.syntax:
        bad += syntax_hits()
    for b in bad:
        print("D17: " + b)
    print(f"check_no_sv: {'FAIL' if bad else 'PASS'} ({len(bad)} problem(s))"
          + (" [files, flags, syntax]" if args.syntax else " [files, flags]"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
