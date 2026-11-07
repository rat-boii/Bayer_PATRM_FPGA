"""data/manifest.json: SHA-256 of every generated file, so regeneration can be checked for determinism.

Layout: {"note": ..., "images": [entry, ...], "vectors": [entry, ...]}
entry = {"file": path relative to data/ with '/', "W": int|null, "H": int|null, "kind": str, "sha256": hex}

Generators call sync_section(): if the manifest has no entries for that section yet (or update=True) the
section is written; otherwise the new entries are compared with the stored ones and mismatches are reported.
"""

import hashlib
import json
import os

DATA_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data")
MANIFEST = os.path.join(DATA_DIR, "manifest.json")
NOTE = ("Generated files (git-ignored) and their SHA-256. Regenerate with: python -m model.gen_images, "
        "python -m model.gen_vectors. Paths are relative to data/.")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def entry(path, W, H, kind):
    try:
        rel = os.path.relpath(path, DATA_DIR)
    except ValueError:                 # other drive (Windows): keep the absolute path
        rel = os.path.abspath(path)
    rel = rel.replace(os.sep, "/")
    return {"file": rel, "W": W, "H": H, "kind": kind, "sha256": sha256_file(path)}


def load(path=MANIFEST):
    if not os.path.exists(path):
        return {"note": NOTE, "images": [], "vectors": []}
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save(m, path=MANIFEST):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(m, f, indent=1)
        f.write("\n")


def compare(stored, new):
    """Return a list of human-readable mismatches between two entry lists."""
    a = {e["file"]: e for e in stored}
    b = {e["file"]: e for e in new}
    out = []
    for k in sorted(set(a) - set(b)):
        out.append(f"missing (in manifest, not generated): {k}")
    for k in sorted(set(b) - set(a)):
        out.append(f"extra (generated, not in manifest): {k}")
    for k in sorted(set(a) & set(b)):
        if a[k] != b[k]:
            out.append(f"differs: {k}")
    return out


def sync_section(section, entries, update=False, path=MANIFEST):
    """Write the section if empty or update=True, else compare. Returns the mismatch list."""
    m = load(path)
    entries = sorted(entries, key=lambda e: e["file"])
    if update or not m.get(section):
        m["note"] = NOTE
        m[section] = entries
        save(m, path)
        print(f"manifest: wrote {len(entries)} '{section}' entries to {os.path.relpath(path)}")
        return []
    bad = compare(m[section], entries)
    if bad:
        print(f"manifest: {len(bad)} MISMATCHES in '{section}':")
        for line in bad[:20]:
            print("  " + line)
    else:
        print(f"manifest: all {len(entries)} '{section}' entries match (SHA-256)")
    return bad
