# Bayer-PATRM: real-time affine warp accelerator for raw Bayer images on the ZedBoard

Reconfigurable Computing course project (Abraar Ahmad Khan, Shreedhar S, Tushar).

We reproduce PATRM (Sensors 26(1):316, 2026), an FPGA accelerator for real-time affine
transformation, in grayscale on the Avnet ZedBoard (Zynq-7000 XC7Z020, `xc7z020clg484-1`).
Then we extend it to raw Bayer (RGGB) images in two builds: Option A (one shared core, four
plane passes) and Option B (four lanes). Speed-up is measured against the same fixed-point
algorithm running on the ARM Cortex-A9.

Project rules and fixed conventions are in [CLAUDE.md](CLAUDE.md). The step-by-step plan is in
[docs/implementation-plan.md](docs/implementation-plan.md).

## New laptop setup (do once per laptop)

Windows, native (not WSL). Do these steps in order. Step 9 checks the result and prints the fix for anything missing.
`<install>` is the folder that holds `Vivado` and `Vitis`: `D:\AMD\2026.1` on the first laptop and
`C:\AMDDesignTools\2026.1` on the second.

1. **Clone into a path without spaces.** This needs Git for Windows. Run every command in this README from the repo
   root unless it says otherwise.

   ```
   git clone https://github.com/rat-boii/Bayer_PATRM_FPGA.git C:\work\Bayer_PATRM_FPGA
   cd C:\work\Bayer_PATRM_FPGA
   ```

2. **Python 3.11 or newer, and the packages.**

   ```
   python -m pip install --user -r requirements.txt
   ```

   `requirements.txt` accepts numpy 2.4.6 up to any 2.5.x (2.5 needs Python 3.12 or newer, so pip picks the version
   that fits your Python) and exactly Pillow 13.0.0. If `python` opens the Microsoft Store, turn off the
   `python.exe`/`python3.exe` App execution aliases (Settings > Apps > Advanced app settings), or use `py -3` instead
   of `python` in every command.

3. **Vivado and Vitis 2026.1.** Install both. Our scripts find them without PATH changes: `scripts/amd_tools.py`
   searches `\AMD`, `\AMDDesignTools` and `\Xilinx` on C:, D: and E:. To run the tools by hand, add
   `<install>\Vivado\bin` and `<install>\Vitis\bin` to PATH.

4. **Licence.** Vivado 2026.1 does not start without a valid licence file. Open the Vivado License Manager
   (`<install>\Vivado\bin\vlm.bat`) and load your licence. If a file from another laptop is rejected, get one for this
   laptop.

5. **ZedBoard board files (Digilent zedboard 1.3).**
   1. Download GitHub repository `Digilent/vivado-boards` (Code > Download ZIP, or
      `git clone https://github.com/Digilent/vivado-boards.git`).
   2. Close Vivado. Copy the `zedboard` folder from `new/board_files/` in that download into
      `<install>\Vivado\data\boards\board_files\`. The result must be
      `<install>\Vivado\data\boards\board_files\zedboard\1.3\board.xml`, next to `preset.xml`, `part0_pins.xml` and
      `zed_board.jpg`.
   3. Fallback, if the Vivado folder cannot be written: keep the `board_files` folder elsewhere (for example
      `C:\boards\board_files`) and add this line to `%APPDATA%\Xilinx\Vivado\Vivado_init.tcl`, creating the file if
      needed:

      ```
      set_param board.repoPaths [list C:/boards/board_files]
      ```

   Vivado shows the board as "ZedBoard", vendor digilentinc.com, with board part
   `digilentinc.com:zedboard:part0:1.1` (the part version is 1.1 although the folder is 1.3). Never use the ZC702 board
   or preset (same chip, different DDR and pins). The 1.3 preset sets the Rev D DDR part (MT41K128M16 JT-125). Our lab
   board is Rev C, so every block design overrides it to MT41J128M16 HA-15E after `apply_bd_automation` (D18 in
   CLAUDE.md).

6. **Two empty Vitis qemu folders.** Vitis platform creation needs them, and our install does not have the
   `emulation\platforms` folder, so without them it fails with "Application error processing RPC". Run once in an
   Administrator PowerShell, with your `<install>` filled in:

   ```
   New-Item -ItemType Directory -Force "<install>\Vitis\data\emulation\platforms\zynq\sw\a9_linux\qemu","<install>\Vitis\data\emulation\platforms\zynq\sw\a9_standalone\qemu"
   ```

7. **Digilent cable drivers (for the lab).** They let the laptop reach the board over USB-JTAG. If the AMD installer
   did not add them, run this as Administrator with the board unplugged:
   `<install>\Vivado\data\xicom\cable_drivers\nt64\digilent\install_digilent.exe`. Step 9 cannot test the drivers. Their
   first real test is step 3 of [First lab session](#first-lab-session).

8. **Regenerate the test images and vectors.** They are git-ignored. This took about 45 s on the second laptop.

   ```
   python -m model.gen_images
   python -m model.gen_vectors
   python scripts/gen_axil_vectors.py
   python scripts/gen_coord_gen_vectors.py
   python scripts/gen_axi_rd_vectors.py
   python scripts/gen_out_path_vectors.py
   python scripts/gen_block_planner_vectors.py
   python scripts/gen_fetch_path_vectors.py
   python scripts/gen_patrm_top_vectors.py
   python scripts/gen_system_vectors.py
   ```

   Do not run `model.gen_transforms` or `scripts/gen_regs.py` here. Their outputs are committed.

9. **Check the laptop.** Takes about a minute, because it starts Vivado once.

   ```
   python scripts/check_setup.py
   ```

   Every line must say `PASS` and the exit code must be 0. Each `FAIL` is followed by its fix. The script installs
   nothing and writes nothing to the repo.

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

## Known setup items

- Board files, the Vitis qemu folders and the other per-laptop items are in
  [New laptop setup](#new-laptop-setup-do-once-per-laptop).
- Pending for D18: decode the DDR chip marking on the lab board with Micron's FBGA decoder.
- Zynq-7000 VIP is available in Vivado 2026.1: `processing_system7_vip` 1.0 and
  `processing_system7` 5.5 (used by the full-system simulation in step 4.1b).

## Test images and vectors (step 1.2)

To regenerate all images and vectors, use step 8 of [New laptop setup](#new-laptop-setup-do-once-per-laptop). The output
is deterministic, with no random state outside fixed seeds: `gen_images` writes `data/gen/` and `gen_vectors` writes
`data/vectors/`, both git-ignored. The other step 1.2 commands:

```
python -m model.gen_transforms    # -> model/transforms.json (committed; only needed if transforms change)
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
| `model/transforms.json` | `{"transforms": [{"name", "forward": {rot_deg, sx, sy, shift [rows, cols], mirror_rows, mirror_cols, about}, "b": {"<W>x<H>": [b11, b12, b13, b21, b22, b23]}}]}`. b = Q15.16 inverse map (D5), one set per output size because the pivot is the image centre. Names: identity, mirror_cols, mirror_rows, rot5, rot15, rot37, scale0p8, scale1p25, combined (rot 10, scale 0.9, shift (6.5, -4.25)), rot90, rot180. Rotation + = counter-clockwise as displayed. |
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

## Step 3.1: AXI-Lite register file (rtl/axil_regs.v)

```
python scripts/gen_axil_vectors.py                                     # vectors from regs.json + model/job.py
python scripts/sim.py --top tb_axil_regs -f tb/axil_regs.f --incdir rtl
python scripts/sim.py --top tb_axil_regs -f tb/axil_regs.f --incdir rtl --define ALT_SEED
python scripts/sim.py --top tb_axil_regs -f tb/axil_regs.f --incdir rtl --define PATRM_FAULT_START_2CYC   # must FAIL
python scripts/sim.py --top tb_axil_regs -f tb/axil_regs.f --incdir rtl --define PATRM_FAULT_ERR_PRIO     # must FAIL
mkdir build\ooc\axil_regs   (first time only)
cd build\ooc\axil_regs
vivado -mode batch -source ../../../vivado/ooc_axil_regs.tcl          # reports -> results/ooc/
```
`PATRM_FAULT_*` are fault-injection defines in the RTL for the testbench only; never set them in a build.
`--define NAME=VALUE` reaches xvlog as `-d "NAME=VALUE"` (sim.py quotes it on Windows, where xvlog is a .bat
and cmd would split an unquoted argument at `=`; fixed in step 3.6a).

## Step 3.2: coordinate generator (rtl/coord_gen.v)

```
python -m model.gen_vectors                                            # step 1.2 / 2.2 vectors (not gen_images)
python scripts/gen_coord_gen_vectors.py                                # case list + extra vectors from the model
python scripts/sim.py --top tb_coord_gen -f tb/coord_gen.f --plusarg VEC_DIR=data/vectors
python scripts/sim.py --top tb_coord_gen -f tb/coord_gen.f --plusarg VEC_DIR=data/vectors --define ALT_SEED
python scripts/sim.py --top tb_coord_gen -f tb/coord_gen.f --plusarg VEC_DIR=data/vectors --define PATRM_FAULT_COL_STEP   # must FAIL
mkdir build\ooc\coord_gen   (first time only)
cd build\ooc\coord_gen
vivado -mode batch -source ../../../vivado/ooc_coord_gen.tcl         # reports -> results/ooc/
```
`coord_gen` owns only the coordinates (spec/interface.md section 4): the block planner (section 3) and the D1
valid bit / integer-fraction split (pixel_fetch, section 7) are other modules. The testbench plays the planner
with the step 2.2 block lists and compares every pixel with the step 1.2 coordinate dumps.

D17 (no SystemVerilog): `sim.py` runs `scripts/check_no_sv.py` before compiling and stops on any `.sv` file or
`-sv` flag; `python scripts/check_no_sv.py --syntax` also scans `rtl/` and `tb/` for SystemVerilog-only syntax.

`sim.py --plusarg NAME=VALUE` passes `+NAME=VALUE` to the simulation (a VALUE that is an existing path is made
relative to the simulation folder `build/sim/<top>/`, so a repo path with spaces still works). `tb_coord_gen` reads `+VEC_DIR=<folder>`; without it, it uses `../../../data/vectors` (the repo folder
seen from `build/sim/tb_coord_gen/`).

| File | Format |
|------|--------|
| `data/vectors/coord_gen/cases.txt` | One testbench case per line: `group name W H b11 b12 b13 b21 b22 b23 nblk npix bp gap abort abort_at blocks_file coords_file`. group: 0 = a (stream, ready always 1), 2 = c (back-pressure), 3 = d (worked example), 4 = e (wrap), 5 = f (start / restart). bp = percent of cycles with `pix_ready` = 0, gap = percent of descriptors that arrive late. abort: 0 = whole frame, 1 = `aresetn` low after `abort_at` pixels, 2 = next `frame_start` after `abort_at` pixels. File names are relative to `data/vectors/`. |
| `data/vectors/coord_gen/coord_vectors_*.txt`, `sched_blocks_*.txt` | Same formats as the step 1.2 / 2.2 files, for the sets that are not in `transforms.json`: `worked` (worked example, 64x64), `wrap` (the 32-bit wrap case of `model/test_patrm.py`, 128x96, outside D4 on purpose), `rand0..3` (random descriptors, u and v0 up to 4095, full-range 32-bit b; not a frame). |

## Step 3.3: bilinear interpolator (rtl/bilinear_interp.v)

```
python -m model.gen_vectors                                            # interp_vectors.txt (not gen_images)
python scripts/sim.py --top tb_bilinear_interp -f tb/bilinear_interp.f --plusarg VEC_DIR=data/vectors
python scripts/sim.py --top tb_bilinear_interp -f tb/bilinear_interp.f --plusarg VEC_DIR=data/vectors --define ALT_SEED
python scripts/sim.py --top tb_bilinear_interp -f tb/bilinear_interp.f --plusarg VEC_DIR=data/vectors --define PATRM_FAULT_W1   # must FAIL
mkdir build\ooc\bilinear_interp   (first time only)
cd build\ooc\bilinear_interp
vivado -mode batch -source ../../../vivado/ooc_bilinear_interp.tcl   # reports -> results/ooc/
```
`bilinear_interp` computes the D10 weights and D (spec/interface.md section 8) and forces the output to 0 when
`ip_ok` = 0. The D1 range compare that makes `ip_ok`, the integer / fraction split and the clamp of the
neighbour indices belong to `pixel_fetch` (section 7). The testbench reads `<VEC_DIR>/interp_vectors.txt`
(default `../../../data/vectors`), compares D on every output pixel and w1..w4 inside the module, and builds the
corner, invalid-pixel, back-pressure and reset streams itself (seeded; `ALT_SEED` = second seed).

## Step 3.6a: block planner (rtl/block_planner.v)

```
python -m model.gen_vectors                                            # step 2.2 block lists (not gen_images)
python scripts/gen_block_planner_vectors.py                            # 208x120, BLOCK_LEN and D16-edge lists + cases
python scripts/sim.py --top tb_block_planner -f tb/block_planner.f --plusarg VEC_DIR=data/vectors
python scripts/sim.py --top tb_block_planner -f tb/block_planner.f --plusarg VEC_DIR=data/vectors --define ALT_SEED
python scripts/sim.py --top tb_block_planner -f tb/block_planner.f --plusarg VEC_DIR=data/vectors --define PATRM_FAULT_SPAN   # must FAIL
mkdir build\ooclock_planner   (first time only)
cd build\ooclock_planner
vivado -mode batch -source ../../../vivado/ooc_block_planner.tcl     # reports -> results/ooc/
```
`block_planner` (spec/interface.md section 3) scans the output frame with its own add-only coordinates, cuts the
blocks by D16, decides rows, P1 row reuse (D14) and slots, and holds the descriptor and fetch FIFOs. The testbench
compares every record of the model block lists (`sched_blocks_*.txt`) on both ports, plus the end reason and the
valid-pixel count inside the DUT; it runs two instances (SPAN_MAX 512 and 32). `tb_axi_rd_master` now also takes
`--define TB_RD_OUTSTANDING=<n>` (vectors: `--plusarg VEC_DIR=data/vectors/axi_rd`).

| File | Format |
|------|--------|
| `data/vectors/block_planner/cases.txt` | One case per line: `group name W H L S b11 b12 b13 b21 b22 b23 nblk nfetch bp abort abort_at blocks_file`. group 0..5 = a..f of the step 3.6a prompt; S = SPAN_MAX of the DUT instance (512 or 32); bp = percent of cycles with `desc_ready` = 0 and, independently, `fetch_ready` = 0; abort: 0 = whole frame, 1 = `aresetn` after `abort_at` descriptors, 2 = next `frame_start` after `abort_at` descriptors. File names are relative to `data/vectors/`. |
| `data/vectors/block_planner/sched_blocks_*.txt`, `sched_bursts_*.txt` | Step 2.2 formats. 208x120 (rows cross 4 KB pages) for every transform at both (L, S); BLOCK_LEN 1 / 7 / 63 / 64 and random lists; `c_span_exact`, `c_span_over`, `c_x0_lastpix`, `c_x0_and_len` (D16 edge cases found by search, see `scripts/gen_block_planner_vectors.py`). |

## Step 3.6b: prefetch, line buffers and pixel fetch (rtl/prefetch_ctrl.v, rtl/line_buf.v, rtl/pixel_fetch.v)

```
python scripts/check_slot_words.py                                     # proof: a slot never needs > 64 words (option A)
python scripts/gen_fetch_path_vectors.py                               # images, per-pixel dumps, frames, cases
python scripts/sim.py --top tb_fetch_path -f tb/fetch_path.f --plusarg VEC_DIR=data/vectors
python scripts/sim.py --top tb_fetch_path -f tb/fetch_path.f --plusarg VEC_DIR=data/vectors --define ALT_SEED
python scripts/sim.py --top tb_fetch_path -f tb/fetch_path.f --plusarg VEC_DIR=data/vectors --define PATRM_FAULT_CLAMP       # must FAIL (group b)
python scripts/sim.py --top tb_fetch_path -f tb/fetch_path.f --plusarg VEC_DIR=data/vectors --define PATRM_FAULT_SLOT_EARLY  # must FAIL (group d)
mkdir build/ooc/fetch_path   (first time only)
cd build/ooc/fetch_path
vivado -mode batch -source ../../../vivado/ooc_fetch_path.tcl          # prefetch_ctrl, line_buf, pixel_fetch, joined
```
`prefetch_ctrl` turns fetch records into row read commands (a slot is written only after every block using it was
read out) and writes the beats into `line_buf`; `line_buf` (8 RAMB36: even / odd word banks x two copies) gives
`pixel_fetch` four 64-bit words per clock; `pixel_fetch` applies D1, waits for its block and picks r1..r4. Words are
stored by source column (spec/interface.md 6.2, the step 3.6b spec fix). The testbench runs the whole read path
(block_planner to bilinear_interp) against the model: per-pixel stream, output frame, every command and buffer
write, slot reuse and aliasing, BYTES_RD vs memmodel, RD_STALL vs its own count. One line per case shows BYTES_RD,
RD_STALL, cycles and the memmodel estimate.

| File | Format |
|------|--------|
| `data/vectors/fetch_path/cases.txt` | One case per line: `group name W H L S b11 b12 b13 b21 b22 b23 lat_min lat_max ar_bp r_gap op_bp seed abort abort_at check bytes_rd est_cycles bursts src_file dump_file exp_file`. group 0 a, 1 b, 3 d, 5 f, 6 g (c = BYTES_RD and e = RD_STALL are checked in every case); lat / ar_bp / r_gap = tb/axi_mem.v knobs; op_bp = percent of cycles with op_ready = 0; abort 1 = `aresetn`, 2 = next `frame_start`, after `abort_at` pixels; check 1/2/3 = output must equal the input / mirrored columns / mirrored rows. |
| `data/vectors/fetch_path/dump_*.hex` | One 104-bit hex word per output pixel, raster order: `{valid[8], x0[16], y0[16], xf[16], yf[16], r1, r2, r3, r4}` (x0, y0 two's complement; r = 0 for invalid pixels). |
| `data/vectors/fetch_path/src_*.hex`, `exp_*.hex` | Source image and expected frame, 64-bit little-endian words (step 1.2 format). |

## Step 3.6c: block planner timing

No behaviour change: `rtl/block_planner.v` gets the rule-(c) bound precomputed (monotonic columns along a row) and
stage D split into D1 (reuse) and D2 (slots, FIFO writes). Same commands as step 3.6a / 3.6b. NSLOT = 16 data for Q2:
`python scripts/sim.py --top tb_fetch_path -f tb/fetch_path.f --plusarg VEC_DIR=data/vectors --define TB_SLOT_BITS=4`.

## Step 3.7: grayscale engine top level (rtl/ctrl_fsm.v, rtl/patrm_top.v)

```
python scripts/gen_patrm_top_vectors.py                                # images, model frames, memmodel counts, cases
python scripts/sim.py --top tb_patrm_top -f tb/patrm_top.f --incdir rtl --plusarg VEC_DIR=data/vectors
python scripts/sim.py --top tb_patrm_top -f tb/patrm_top.f --incdir rtl --plusarg VEC_DIR=data/vectors --define PATRM_FAULT_DONE_EARLY  # must FAIL
python scripts/sim.py --top tb_patrm_top -f tb/patrm_top.f --incdir rtl --plusarg VEC_DIR=data/vectors --define PATRM_FAULT_BUSY_GAP    # must FAIL
mkdir build/synth/patrm_top   (first time only)
cd build/synth/patrm_top
vivado -mode batch -source ../../../vivado/synth_patrm_top.tcl         # synthesis only; reports -> results/ooc/
```
`tb_patrm_top` acts like the ARM driver: it programs the registers over AXI-Lite, starts the engine, waits for the
interrupt or polls STATUS, and compares the output in memory with the model. The log has one line per case, the
`SPEED` lines of the table in spec/interface.md section 12, and the totals per group.

| File | Format |
|------|--------|
| `data/vectors/patrm_top/cases.txt` | One case per line: `group op name W H L b11 b12 b13 b21 b22 b23 lat_min lat_max ar_bp r_gap aw_bp w_bp b_lat_min b_lat_max seed irq arg bytes_rd rd_bursts wr_bursts src_file exp_file`. group 0..7 = a..h of the step 3.7 prompt (e = the counter checks of every frame). op: 0 frame, 1 lock + W1C checks, 2 / 3 SLVERR on read / write burst `arg`, 4 `aresetn` `arg` cycles after START, 5 START while busy, 6 the rejected starts. |
| `data/vectors/patrm_top/src_*.hex`, `exp_*.hex` | Source image and expected frame, 64-bit little-endian words (step 1.2 format). |

## Step 3.8: whole-engine implementation at 100 MHz (vivado/ooc_patrm_top.tcl)

```
mkdir build/ooc/patrm_top   (first time only)
cd build/ooc/patrm_top
vivado -mode batch -source ../../../vivado/ooc_patrm_top.tcl           # out-of-context synthesis, place and route
```
The console ends with an `OOC SUMMARY patrm_top ...` line. Reports go to `results/ooc/`:

| File | Content |
|------|---------|
| `patrm_top_summary.txt` | LUT / LUTRAM / FF / BRAM / DSP with % of the device, WNS / TNS / WHS, Fmax estimate, critical path, 10 worst paths, per-module table next to the module runs, power estimate, methodology and DRC rules, port paths |
| `patrm_top_utilization_{synth,route}.rpt`, `patrm_top_utilization_hier_route.rpt` | Flat and hierarchical utilization (Vivado leaves `u_interp` out of the hierarchical table; the summary counts it from its cells) |
| `patrm_top_timing_route.rpt`, `patrm_top_worst10_paths_route.rpt` | Timing summary and the 10 worst setup paths in full |
| `patrm_top_methodology_route.rpt`, `patrm_top_drc_route.rpt` | `report_methodology`, `report_drc` |
| `patrm_top_power_route.rpt` | `report_power`, default settings: a vectorless estimate |
| `patrm_top_vs_paper.md` | Comparison table with the paper, written by hand from the summary and the step 3.7 speed table |

## Step 4.1: block design, bitstream, XSA and bring-up software

```
mkdir build/vivado   (first time only)
cd build/vivado
vivado -mode batch -source ../../vivado/build.tcl                  # normal build, name patrm_gray
vivado -mode batch -source ../../vivado/build.tcl -tclargs ila=1   # debug build, name patrm_gray_ila
cd ../..
vitis -s sw/bringup/build_vitis.py                                 # platform + bring-up ELF from patrm_gray.xsa
```
`vivado/build.tcl` makes the whole project from nothing and stops with `CHECK FAILED ...` if a check fails. The last
console line of a good run is `BUILD: all checks passed`. `-tclargs bd_only=1` stops after `validate_bd_design`.
`vitis -s` can exit with code 0 after a failure, so the ELF build succeeded only if it prints `BRINGUP BUILD OK`.

Validate is **not fully clean**: it reports 0 errors and 4 known critical warnings, PSU-1..4 (negative
`DQS_TO_CLK_DELAY_0..3`). They come from the Digilent preset itself, and the team accepted them on 2026-11-18. The
script accepts only these four with exactly the preset's values. Any other critical warning stops the build. The first
real test of the DDR settings is the round trip in "First lab session".

Output in `results/hw/` (`.bit`, `.xsa`, `.ltx` and `.elf` are not tracked by git):

| File | Content |
|------|---------|
| `patrm_gray.bit`, `patrm_gray.xsa`, `ps7_init.tcl`, `bringup.elf` | What the board scripts load |
| `summary.txt` | Checks, WNS / WHS, `aresetn` path, clock interaction, utilization by block next to step 3.8, power estimate, PS7 settings |
| `address_map.txt` | Address map of the block design |
| `timing_summary.rpt`, `worst10_paths.rpt`, `clock_interaction.rpt`, `utilization.rpt`, `utilization_hier.rpt`, `power.rpt`, `methodology.rpt`, `drc.rpt` | Full Vivado reports of the normal build |
| `patrm_gray_ila.bit`, `.xsa`, `.ltx`, `patrm_gray_ila_summary.txt` | Debug build only. No reported number comes from it (D9) |

### Debug build (ila=1)

The Vivado BASIC licence refuses the System ILA IP and `create_debug_core`, but accepts the plain ILA IP with 5 probes.
So the debug build has one native ILA, `u_ila_0`, in the top level: 5 bus probes, clock FCLK_CLK0, depth 4096 samples,
26 RAMB36. `rtl/` is not changed. Two files generated under `build/vivado/` (`patrm_ila_top.v`, `system_wrapper_ila.v`)
bring the signals out to it. The normal build uses neither of them.

| Probe | Bits | Field (bit range) |
|-------|------|-------------------|
| `probe0` HP0 read address | 38 | `hp0_araddr` [31:0], `hp0_arlen` [35:32], `hp0_arready` [36], `hp0_arvalid` [37] |
| `probe1` HP0 read data | 69 | `hp0_rdata` [63:0], `hp0_rresp` [65:64], `hp0_rlast` [66], `hp0_rready` [67], `hp0_rvalid` [68] |
| `probe2` HP1 write address | 38 | `hp1_awaddr` [31:0], `hp1_awlen` [35:32], `hp1_awready` [36], `hp1_awvalid` [37] |
| `probe3` HP1 write data, response | 79 | `hp1_bresp` [1:0], `hp1_bready` [2], `hp1_bvalid` [3], `hp1_wdata` [67:4], `hp1_wstrb` [75:68], `hp1_wlast` [76], `hp1_wready` [77], `hp1_wvalid` [78] |
| `probe4` interrupt, GP0 AXI-Lite | 8 | `gp0_rvalid` [0], `gp0_arvalid` [1], `gp0_bvalid` [2], `gp0_wready` [3], `gp0_wvalid` [4], `gp0_awready` [5], `gp0_awvalid` [6], `interrupt` [7] |

`vivado/ila_map.tcl` is the single source of this map. In the hardware manager, program `patrm_gray_ila.bit` with
`patrm_gray_ila.ltx`, then split the buses into named signals from the Tcl console:
```
source scripts/board/ila_probes.tcl
```
This script has only been run without hardware, where it prints its 29 `create_hw_probe` commands. On the first capture,
check that a known signal (for example `hp0_arvalid`) behaves as expected before trusting the split.

### Board scripts (XSDB)

| Command | Does |
|---------|------|
| `xsdb scripts/board/load_run.tcl [--dry-run] [--bit f] [--init f] [--elf f] [--no-run]` | Program the bitstream, initialise the PS and DDR, load and run the ELF |
| `xsdb scripts/board/put_image.tcl [--dry-run] <file> <address>` | Raw file -> DDR, prints s/MB |
| `xsdb scripts/board/get_image.tcl [--dry-run] <address> <bytes> <file>` | DDR -> raw file, prints s/MB |

`--dry-run` checks the arguments and files and prints each step without touching the board. **`xsdb` exits with code 0
even when a script fails**, so read the output: success ends with `DONE` (or `DRY RUN OK`), failure prints `BOARD ERROR: ...`.

## Step 4.1b: full-system simulation with the Zynq VIP (no board)

```
python scripts/gen_system_vectors.py                               # cases, images, model frames, register lists
python scripts/sim_system.py                                       # block design -> compile -> elaborate -> run
python scripts/sim_system.py --reuse                               # after a testbench or RTL change
python scripts/sim_system.py --reuse --define PATRM_FAULT_W1       # must FAIL (fault injection, simulation only)
python scripts/regress.py                                          # whole regression, includes this simulation
```

`vivado/sim_system.tcl` builds the block design of `vivado/build.tcl` (`sim=1`: same settings, no ILA, own project
`build/vivado/patrm_gray_sim`) and generates the xsim scripts. `tb/tb_system.v` is plain Verilog and acts like the ARM
through the `processing_system7_vip` API tasks: it loads the image into the VIP DDR, programs the registers over GP0,
waits for IRQ_F2P[0], reads the counters, clears DONE and compares the output in the VIP DDR with the model. A full run
took 225 s on this laptop (Vivado 53 s, compile and elaborate 59 s, simulation 112 s).

| Case | Output | CYCLES | BYTES_RD (= memmodel) | BYTES_WR | Simulated START to interrupt |
|------|--------|-------:|----------------------:|---------:|-----------------------------:|
| identity 64x64 | byte-exact | 4,522 | 4,096 | 4,096 | 45.24 us |
| rot15 64x64 | byte-exact | 43,664 | 18,064 | 4,096 | 436.66 us |
| rot37 128x96 | byte-exact | 213,665 | 72,992 | 12,288 | 2,136.67 us |
| mirror_cols 64x64 | byte-exact | 4,519 | 4,096 | 4,096 | 45.21 us |
| WIDTH = 60 (rejected) | nothing written | - | - | - | ERR_CODE 1, no interrupt |

These cycle counts use the VIP's memory timing, so they are not a measurement of the real DDR on the board.

**VIP write lag.** In this simulation the VIP's DDR model commits an HP write burst only when the next HP write request
arrives, so the last burst of a frame stays pending and would land during the next frame. The AXI traffic from the
engine is correct (W data equals the model, every burst gets an OKAY response). After each frame the testbench therefore
runs an 8 x 1 job into a scratch buffer at 0x1C00_0000, and only then compares the frame in the VIP DDR. This is a
property of the simulation model, so the driver and the board need no such job.

## First lab session

Nothing below has been run on hardware yet. Use Git Bash in the repository root, with `<install>\Vivado\bin` on PATH.
Run the steps in this order.

1. **Board.** Set the boot-mode jumpers JP7 - JP11 to JTAG (all to GND; check against the ZedBoard hardware guide).
   Connect USB to PROG (J17) and UART (J14), then power on.
2. **Console.** Open the USB-UART port in a terminal at 115200 8N1.
3. **Hello and BUILD_ID.**
   ```
   xsdb scripts/board/load_run.tcl
   ```
   The XSDB output ends with `load_run: DONE`. The UART must show `hello ...`, the PS IDCODE, PS_VERSION and MIDR, then:
   ```
   BUILD_ID    0x00401001 (expected 0x00401001)
     VERSION 1, BUILD_TYPE 0, MODES 1, BLOCK_LEN_MAX 64
   STATUS      0x00000000 (expected 0x00000000)
   BRINGUP PASS
   ```
4. **DDR round trip, 1 MB.** Note the s/MB values that `put_image` and `get_image` print.
   ```
   mkdir -p build/board
   python -c "import os; open('build/board/rt_1M.bin','wb').write(os.urandom(1048576))"
   xsdb scripts/board/put_image.tcl build/board/rt_1M.bin 0x10000000
   xsdb scripts/board/get_image.tcl 0x10000000 1048576 build/board/rt_1M.back
   cmp build/board/rt_1M.bin build/board/rt_1M.back && echo SAME
   ```
5. **DDR round trip, 5 MB.**
   ```
   python -c "import os; open('build/board/rt_5M.bin','wb').write(os.urandom(5242880))"
   xsdb scripts/board/put_image.tcl build/board/rt_5M.bin 0x10000000
   xsdb scripts/board/get_image.tcl 0x10000000 5242880 build/board/rt_5M.back
   cmp build/board/rt_5M.bin build/board/rt_5M.back && echo SAME
   ```
   Both must print `SAME`. If bytes differ, check the DDR part (next step) first.
6. **DDR chip marking (D18).** Read the marking printed on a DDR3 chip on the board and decode it with Micron's FBGA
   marking decoder. `MT41J128M16HA-15E` confirms D18. `MT41K128M16JT-125` means D18 is reverted: stop and rebuild with
   that part before trusting any DDR result.
