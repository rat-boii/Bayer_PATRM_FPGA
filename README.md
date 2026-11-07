# Bayer-PATRM: real-time affine warp accelerator for raw Bayer images on the ZedBoard

Reconfigurable Computing course project (Abraar Ahmad Khan, Shreedhar S, Tushar).

We reproduce PATRM (Sensors 26(1):316, 2026), an FPGA accelerator for real-time affine
transformation, in grayscale on the Avnet ZedBoard (Zynq-7000 XC7Z020, `xc7z020clg484-1`).
Then we extend it to raw Bayer (RGGB) images in two builds: Option A (one shared core, four
plane passes) and Option B (four lanes). Speed-up is measured against the same fixed-point
algorithm running on the ARM Cortex-A9.

Project rules and fixed conventions are in [CLAUDE.md](CLAUDE.md). The step-by-step plan is in
[docs/implementation-plan.md](docs/implementation-plan.md).

## Layout

| Folder     | Contents |
|------------|----------|
| `model/`   | Python reference model and image/coefficient generators (the single reference) |
| `spec/`    | `regs.json` register map and interface spec |
| `rtl/`     | Verilog-2001 sources (one module per file) |
| `tb/`      | Testbenches and bus models (`tb/smoke/` = toolchain smoke test) |
| `vivado/`  | Tcl build scripts (projects are rebuilt from Tcl, never checked in) |
| `sw/`      | Bare-metal driver and ARM baseline |
| `scripts/` | Python runners: environment check, simulation, board access (XSDB), tests |
| `data/`    | Test images and golden outputs (large files are git-ignored) |
| `results/` | CSV, reports, plots |
| `docs/`    | Plan, proposal, specs |
| `build/`   | All tool output (git-ignored, safe to delete) |

## Setup (Windows, native)

1. **Vivado/Vitis 2026.1** with a valid license. On our machine it is installed in `D:\AMD\2026.1`.
   Our scripts find the tools even when they are not on PATH. To run them by hand, add
   `D:\AMD\2026.1\Vivado\bin` and `D:\AMD\2026.1\Vitis\bin` to PATH.
2. **Git for Windows** (`C:\Program Files\Git\cmd`).
3. **Python 3.10 or newer** (we use 3.14). Install the packages:

   ```
   python -m pip install --user -r requirements.txt
   ```

   If `python` opens the Microsoft Store, the Store alias comes first in PATH. Turn off the
   `python.exe`/`python3.exe` App execution aliases (Settings > Apps > Advanced app settings),
   or use `py -3` instead of `python` in every command below.

## Known setup items

- ZedBoard Rev C board files are **not installed** (needed before step 4.1). Step 0.2a is
  postponed until lab access to the ZedBoard is confirmed.
- Zynq-7000 VIP is available in Vivado 2026.1: `processing_system7_vip` 1.0 and
  `processing_system7` 5.5 (used by the full-system simulation in step 4.1b).

## Test images and vectors (step 1.2)

Regenerate everything from the repo root (about 10 s; deterministic, no random state outside fixed seeds):

```
python -m model.gen_images        # -> data/gen/       (git-ignored)
python -m model.gen_transforms    # -> model/transforms.json (committed; only needed if transforms change)
python -m model.gen_vectors       # -> data/vectors/   (git-ignored)
python -m model.contact_sheet     # -> results/contact_sheet_step1_2.png
python -m model.test_step1_2      # checks; last line TEST PASS / TEST FAIL: <reason>
```

`gen_images` and `gen_vectors` compare every file's SHA-256 with `data/manifest.json` and report
mismatches. `--update-manifest` adds entries for new files only (existing entries are kept and still
checked); `--rewrite-manifest` rewrites the whole section (only after an intended change).

Bayer model (step 1.3): `python -m model.test_bayer` (checks), `python -m model.bayer_figure`
(-> `results/bayer_step1_3.png`, naive vs plane-wise warp with PSNR).
All sizes are written W x H.

| File | Format |
|------|--------|
| `data/gen/gray_<kind>_<W>x<H>.raw` | GRAY8, row-major, no header, exactly W*H bytes. Kinds: `checker`, `gradient`, `grid`, `mixed` (synthetic), `photo-<name>` (from `data/photos/*.jpg/.png`: centre crop to W:H, LANCZOS resize, Pillow `convert('L')`). Sizes: 64x64, 128x96, 256x192, 480x272, 640x480, 800x480, 1920x1080, 2448x2048, 2448x2095. |
| `data/gen/rggb_<kind>_<W>x<H>.raw` | Raw Bayer RGGB8, row-major, W*H bytes: R at (even row, even col), Gr (even, odd), Gb (odd, even), B (odd, odd). Kinds: `chart` (synthetic RGB chart), `photo-<name>`. Sizes: the list above except 2448x2095 (D3: W%16==0, H even). |
| `data/manifest.json` | `{"images": [...], "vectors": [...]}`, each entry `{file (relative to data/), W, H, kind, sha256}`. |
| `model/transforms.json` | `{"transforms": [{"name", "forward": {rot_deg, sx, sy, shift [rows, cols], mirror_rows, mirror_cols, about}, "b": {"<W>x<H>": [b11, b12, b13, b21, b22, b23]}}]}`. b = Q15.16 inverse map (D5), one set per output size because the pivot is the image centre. Names: identity, mirror_cols, mirror_rows, rot5, rot15, rot37, scale0p8, scale1p25, combined (rot 10, scale 0.9, shift (6.5, -4.25)). Rotation + = counter-clockwise as displayed. |
| `data/vectors/interp_vectors.txt` | First line `# xf yf r1 r2 r3 r4 w1 w2 w3 w4 D`, then one case per line, 11 decimal integers separated by one space. xf, yf in 0..65535; r in 0..255; w and D per D10. Row 1 = worked example; next 175 = corner cases (xf, yf in {0, 1, 32767, 32768, 65535} x 7 pixel patterns incl. flat 0 and flat 255); then 100,000 random cases (seed 12345). |
| `data/vectors/coord_vectors_<transform>_<W>x<H>.txt` | First line `# u v X Y valid x0 y0 xf yf`, then one output pixel per line in raster order (u outer, v inner), signed decimal. X, Y = Q15.16 int32 source coordinates; valid per D1 (1/0); x0 = X>>16, y0 = Y>>16 (arithmetic, may be negative when invalid); xf = X & 0xFFFF, yf = Y & 0xFFFF. Sim sizes only. |
| `data/vectors/src_<stem>.hex`, `exp_<stem>.hex` | For `$readmemh` into a 64-bit memory: one word per line, 16 lower-case hex digits, no prefix, W*H/8 lines. Byte at address 8k+i is in bits [8i+7:8i] of word k (little-endian, same as the AXI 64-bit data bus): bytes 0..7 give `0706050403020100`. `src` = source image, `exp` = model output (`warp_gray`). `<stem>` = `<image>_<transform>_<W>x<H>`, sim sizes only. |
| `data/vectors/cfg_<stem>.txt` | One line: `W H b11 b12 b13 b21 b22 b23`, signed decimal, space-separated. |
| `data/vectors/src_rggb_<stem>.hex`, `exp_rggb_<stem>.hex` | Bayer RGGB frames, same hex format as above (W*H bytes of the full mosaic). `src` = `data/gen/rggb_<image>_<W>x<H>.raw`, `exp` = `bayer.warp_bayer` (four planes warped at W/2 x H/2, merged). `<stem>` = `<image>_<transform>_<W>x<H>`; sim sizes only; b is the full-size b from `transforms.json`. |
| `data/vectors/cfg_rggb_<stem>.txt` | One line, 16 signed decimals: `W H b11 b12 b13 b21 b22 b23 TRx TRy TGrx TGry TGbx TGby TBx TBy` (T_p per D2, Q15.16). Plane p uses b_p = (b11, b12, T_px, b21, b22, T_py); Option B lane offset = T_p - T_R (D6). |

## Viewing images

Raw file to PNG (gray; `--bayer` = demosaiced colour; `--bayer --mosaic` = raw mosaic as gray):

```
python -m model.raw2png data/gen/rggb_chart_640x480.raw --w 640 --h 480 --bayer --out build/view/chart.png
```

Try the reference model on any photo (centre crop + resize to `--size` W x H; gray, or RGGB with
`--bayer`). Writes `results/try_<name>.png` (`try_<name>_bayer.png` with `--bayer`): input and output
side by side, labelled with the transform and the b integers:

```
python -m model.try_warp data/photos/street.jpg --size 640x480 --rot 15 --scale 0.9 --shift 10 -20
```
Options: `--rot DEG` (+ = counter-clockwise), `--scale S` or `--scale SX SY`, `--shift R C` (pixels),
`--mirror cols|rows`, `--bayer`, `--out file.png`. The transform is about the image centre.

Test window: `python -m model.warp_gui` opens a Tkinter window to load a photo or raw file, pick size,
transform (or a preset from `transforms.json`) and gray/Bayer, run the reference model, see input and output
side by side with b, T_p and run time, and save the output as PNG + raw.

## Checks (step 0.1)

Run them from the repo root:

```
python scripts/check_env.py
```
Prints version, path and PASS/FAIL for python, numpy, Pillow, git, vivado, xvlog, xelab, xsim,
xsdb and vitis. Exit code 0 only if every item passes.

```
mkdir build        (first time only)
cd build
vivado -mode batch -source ../vivado/check_part.tcl
cd ..
```
Prints the Vivado version, confirms that part `xc7z020clg484-1` exists, and lists ZedBoard board
files (`*zed*`). Vivado runs inside `build/` so its `.jou`/`.log` files stay out of the repo root.

```
python scripts/sim.py --top tb_counter4 tb/smoke/counter4.v tb/smoke/tb_counter4.v
python scripts/sim.py --top tb_counter4 tb/smoke/counter4.v tb/smoke/tb_counter4.v --define BREAK_EXPECTED
```
`sim.py` runs xvlog -> xelab -> xsim in batch mode inside `build/sim/<top>/` and keeps the logs
there. It exits 0 only if the log contains `TEST PASS`. The second command breaks the expected
value on purpose, so it must print `TEST FAIL` and exit non-zero.

`sim.py` options: `-f <filelist>` (one path per line), `--define NAME[=VALUE]`, `--incdir <dir>`,
`--gui` (opens the xsim GUI, off by default). Every testbench is self-checking and prints exactly
one final line: `TEST PASS` or `TEST FAIL: <reason>`.
