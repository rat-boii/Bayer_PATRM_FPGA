"""Step 1.2 checks: images, manifest, transforms, hex vectors, interpolator vectors.

Run from the repo root after generating (python -m model.gen_images; python -m model.gen_vectors):
    python -m model.test_step1_2
Prints the numbers for each check, then exactly one final line: TEST PASS or TEST FAIL: <reason>.
"""

import os
import sys
import tempfile
import unittest

import numpy as np

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from model import gen_images as G  # noqa: E402
from model import gen_transforms as T  # noqa: E402
from model import gen_vectors as V  # noqa: E402
from model import manifest as M  # noqa: E402
from model import patrm as P  # noqa: E402

REPORT = {}


def report(n, line):
    REPORT.setdefault(n, []).append(line)


def data_path(rel):
    return os.path.join(M.DATA_DIR, rel.replace("/", os.sep))


class Step12(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.man = M.load()

    def test_1_raw_sizes(self):
        imgs = self.man["images"]
        self.assertGreater(len(imgs), 0, "manifest has no images")
        nbayer = 0
        for e in imgs:
            size = os.path.getsize(data_path(e["file"]))
            self.assertEqual(size, e["W"] * e["H"], e["file"])
            if e["kind"].startswith("rggb:"):
                P.check_size(e["W"], e["H"], "bayer")
                nbayer += 1
            else:
                P.check_size(e["W"], e["H"], "gray")
        on_disk = sorted(f for f in os.listdir(G.DEFAULT_OUT) if f.endswith(".raw"))
        listed = sorted(os.path.basename(e["file"]) for e in imgs)
        self.assertEqual(on_disk, listed, "data/gen and manifest disagree")
        report(1, f"{len(imgs)} raw images, every one exactly W*H bytes; {nbayer} RGGB files obey D3 "
                  f"(W%16==0, H even); {len(imgs) - nbayer} gray files obey D3 (W%8==0)")
        report(1, f"manifest lists {len(imgs) + len(self.man['vectors'])} files "
                  f"({len(imgs)} images + {len(self.man['vectors'])} vectors)")

    def test_2_hashes(self):
        n = bad = 0
        for e in self.man["images"] + self.man["vectors"]:
            n += 1
            if M.sha256_file(data_path(e["file"])) != e["sha256"]:
                bad += 1
        self.assertEqual(bad, 0)
        report(2, f"SHA-256 of all {n} generated files on disk match the manifest ({bad} mismatches)")

    def test_3_rggb(self):
        rng = np.random.default_rng(3)
        H, W = 96, 128
        rgb = rng.integers(0, 256, size=(H, W, 3), dtype=np.uint8)
        m = G.rgb_to_rggb(rgb)
        u, v = np.meshgrid(np.arange(H), np.arange(W), indexing="ij")
        chan = np.where((u % 2 == 0) & (v % 2 == 0), 0, np.where((u % 2 == 1) & (v % 2 == 1), 2, 1))
        exp = np.take_along_axis(rgb, chan[..., None], axis=2)[..., 0]
        nd = int(np.count_nonzero(m != exp))
        self.assertEqual(nd, 0)
        self.assertEqual(m[0, 0], rgb[0, 0, 0])
        self.assertEqual(m[0, 1], rgb[0, 1, 1])
        self.assertEqual(m[1, 0], rgb[1, 0, 1])
        self.assertEqual(m[1, 1], rgb[1, 1, 2])
        report(3, f"rgb_to_rggb on random {W}x{H} RGB: (0,0)=R (0,1)=G (1,0)=G (1,1)=B over the whole image, "
                  f"{nd} wrong pixels")

    def test_4_transforms(self):
        tfs = T.load()
        n = 0
        for t in tfs:
            kw = {k: (tuple(v) if k == "shift" else v) for k, v in t["forward"].items()}
            self.assertEqual(sorted(t["b"]), sorted(f"{W}x{H}" for W, H in G.GRAY_SIZES), t["name"])
            for key, b in t["b"].items():
                W, H = (int(x) for x in key.split("x"))
                P.check_transform(b, W, H)
                self.assertEqual(tuple(b), P.make_b(W, H, **kw), f"{t['name']} {key} not reproducible")
                n += 1
        report(4, f"{len(tfs)} transforms ({', '.join(t['name'] for t in tfs)}) x {len(G.GRAY_SIZES)} sizes = "
                  f"{n} entries: all pass D4 and equal make_b(forward); none skipped")

    def test_5_hex_roundtrip(self):
        pattern = bytes(range(16))
        lines = V.bytes_to_hex64(pattern)
        self.assertEqual(lines, ["0706050403020100", "0f0e0d0c0b0a0908"])
        self.assertEqual(V.hex64_to_bytes(lines), pattern)
        srcs = [e for e in self.man["vectors"] if e["kind"].startswith("frame_src")]
        exps = [e for e in self.man["vectors"] if e["kind"].startswith("frame_exp")]
        for e in srcs:
            stem = os.path.basename(e["file"])[len("src_"):-len(".hex")]
            image = stem.split("_", 1)[0]          # image names use "-", never "_"
            raw = os.path.join(G.DEFAULT_OUT, f"gray_{image}_{e['W']}x{e['H']}.raw")
            with open(raw, "rb") as f:
                self.assertEqual(V.read_hex(data_path(e["file"])), f.read(), e["file"])
        for e in exps:
            self.assertEqual(len(V.read_hex(data_path(e["file"]))), e["W"] * e["H"], e["file"])
        report(5, f"byte lanes: bytes 0..7 -> word 0x{lines[0]}, bytes 8..15 -> 0x{lines[1]}; "
                  f"{len(srcs)} src hex files == their raw images byte for byte; {len(exps)} exp hex files "
                  f"have W*H bytes")

    def test_6_expected_frames(self):
        exps = [e for e in self.man["vectors"] if e["kind"].startswith("frame_exp")]
        npix = 0
        for e in exps:
            stem = os.path.basename(e["file"])[len("exp_"):-len(".hex")]
            W, H, b = V.read_cfg(os.path.join(V.DEFAULT_OUT, f"cfg_{stem}.txt"))
            src = np.frombuffer(V.read_hex(os.path.join(V.DEFAULT_OUT, f"src_{stem}.hex")), np.uint8)
            exp = np.frombuffer(V.read_hex(data_path(e["file"])), np.uint8)
            out = P.warp_gray(src.reshape(H, W), W, H, b)
            nd = int(np.count_nonzero(out.ravel() != exp))
            self.assertEqual(nd, 0, stem)
            npix += W * H
        report(6, f"{len(exps)} frames: exp hex == warp_gray(src hex, cfg b) re-read from the files, "
                  f"0 differing bytes of {npix}")

    def test_7_interp_vectors(self):
        path = os.path.join(V.DEFAULT_OUT, "interp_vectors.txt")
        with open(path) as f:
            header = f.readline().strip()
        self.assertEqual(header, V.INTERP_HEADER)
        a = np.loadtxt(path, dtype=np.int64, comments="#")
        self.assertEqual(a.shape[1], 11)
        first = a[0].tolist()
        self.assertEqual(first, [13107, 26216, 100, 140, 120, 160, 31458, 20972, 7863, 5243, 120])
        r = a[:, 2:6]
        flat255 = np.all(r == 255, axis=1)
        flat0 = np.all(r == 0, axis=1)
        self.assertTrue(np.all(a[flat255, 10] == 255))
        self.assertTrue(np.all(a[flat0, 10] == 0))
        self.assertTrue(np.all(a[:, 6:10].sum(axis=1) == 65536))
        # Independent plain-Python recomputation of every row.
        bad = 0
        for row in a.tolist():
            xf, yf, r1, r2, r3, r4 = row[:6]
            w2 = ((65536 - xf) * yf) // 65536
            w3 = (xf * (65536 - yf)) // 65536
            w4 = (xf * yf) // 65536
            w1 = 65536 - w2 - w3 - w4
            D = (w1 * r1 + w2 * r2 + w3 * r3 + w4 * r4) // 65536
            if [w1, w2, w3, w4, D] != row[6:]:
                bad += 1
        self.assertEqual(bad, 0)
        report(7, f"{len(a)} rows; worked-example row: xf=13107 yf=26216 r=100,140,120,160 -> "
                  f"w=31458,20972,7863,5243 D=120; {int(flat255.sum())} flat-255 rows all D=255; "
                  f"{int(flat0.sum())} flat-0 rows all D=0; weights sum to 65536 in every row; "
                  f"{bad} rows differ from a plain-Python recomputation")

    def test_8_photos(self):
        n = len(G.find_photos(G.DEFAULT_PHOTOS))
        # Exercise the photo path on a temporary synthetic PNG so it is tested even without photos.
        from PIL import Image
        with tempfile.TemporaryDirectory() as td:
            pdir, odir = os.path.join(td, "photos"), os.path.join(td, "gen")
            os.makedirs(pdir)
            Image.fromarray(G.rgb_chart(300, 200)).save(os.path.join(pdir, "Test Photo.png"))
            ents, k = G.generate(odir, pdir, gray_sizes=[(64, 64), (128, 96)], bayer_sizes=[(128, 96)])
            names = sorted(os.path.basename(e["file"]) for e in ents)
            self.assertEqual(k, 1)
            self.assertIn("gray_photo-test-photo_128x96.raw", names)
            self.assertIn("rggb_photo-test-photo_128x96.raw", names)
            for e in ents:
                self.assertEqual(os.path.getsize(os.path.join(odir, os.path.basename(e["file"]))),
                                 e["W"] * e["H"])
        report(8, f"photos found in data/photos/: {n}" + (" -> synthetic images only" if n == 0 else "")
               + "; photo conversion path tested on a temporary PNG (gray + RGGB, sizes correct)")


def main():
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Step12)
    res = unittest.TextTestRunner(stream=sys.stderr, verbosity=2).run(suite)
    for n in sorted(REPORT):
        for line in REPORT[n]:
            print(f"[{n}] {line}")
    sys.stdout.flush()
    if res.wasSuccessful():
        print("TEST PASS")
        return 0
    first = (res.failures + res.errors)[0]
    print(f"TEST FAIL: {first[0].id().split('.')[-1]}: {first[1].strip().splitlines()[-1]}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
