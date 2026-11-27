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

   Vitis compiles the ARM software with `arm-none-eabi-gcc`, which is not in the Vitis folder. Install the Arm GNU
   Toolchain for arm-none-eabi (version 14.2.Rel1 here) and put its `bin` folder on PATH.

   The ARM software baseline (step 4.4) is first checked on the laptop with a Windows gcc:
   `winget install BrechtSanders.WinLibs.POSIX.UCRT` (GCC 16.2 here, no admin rights). PATH is not needed:
   `model/test_patrm_sw.py` and `check_setup.py` also look in the winget package folder.

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
| `sw/`      | Bare-metal driver, ARM baseline, `sw/patrm_job/` job runner (JTAG + Ethernet), `sw/patrm_eth/` Ethernet (lwIP) app (Phase 10) |
| `scripts/` | Python runners: environment check, simulation, board access (XSDB), tests |
| `data/`    | Test images and golden outputs (large files are git-ignored) |
| `results/` | CSV, reports, plots |
| `docs/`    | Plan, proposal, specs |
| `build/`   | All tool output (git-ignored, safe to delete) |

**Ethernet link and GUI (plan Phase 10, a teammate's work in parallel):** start with `docs/handover-ethernet-gui.md`.
`AGENTS.md` points every coding agent (Codex, Claude Code) to `CLAUDE.md`, the single rule file.

### Repository map: grayscale and Bayer (D20)

One repo, one engine. Shared modules get a parameter or mode input and are never copied; Bayer-only files are
named `bayer_*`. **Role:** shared = used by every mode; A = Bayer Option A (MODE 1); B = Bayer Option B (MODE 2).
The Option A changes are specified in `spec/interface.md` section 18 (step 5.1) and built in step 5.2.

| File | Role | Bayer change |
|---|---|---|
| `rtl/axil_regs.v` | shared | none (MODE, T registers, Bayer size checks exist) |
| `rtl/ctrl_fsm.v` | shared | A: done from bayer_seq, BUSY over all passes |
| `rtl/bayer_seq.v` | A (step 5.2) | runs the four plane passes, per-pass values (gray: one pass) |
| `rtl/block_planner.v` | shared | A: plane grid, memory row 2x + o_row, column 2y + o_col |
| `rtl/coord_gen.v` | shared | A: b13 / b23 = T_p of the pass |
| `rtl/prefetch_ctrl.v` | shared | A: bottom row = top + 2W |
| `rtl/line_buf.v` | shared | none |
| `rtl/pixel_fetch.v` | shared | A: plane D1, stride-2 byte select |
| `rtl/bilinear_interp.v` | shared | none |
| `rtl/out_fifo.v` | shared | A: 4 pixels per word at bytes 2k + o_col |
| `rtl/axi_rd_master.v` | shared | none |
| `rtl/axi_wr_master.v` | shared | A: WSTRB 55 / AA, row step 2W |
| `rtl/patrm_top.v` | shared | MODES parameter selects the build |
| `rtl/bayer_lanes.v`, `rtl/bayer_geometry.v` | B | shared coordinate scan, block planning, fallback and four interpolation lanes |
| `rtl/bayer_store.v`, `rtl/bayer_merge.v` | B | bounded shared fetch and slot reuse, full-word RGGB row-pair output |
| `scripts/gen_bayer_b_vectors.py` | B | model reference, transaction traces and rectangular-only comparison for tb_patrm_top |
| `model/patrm.py` | shared | gray reference (bit-exact) |
| `model/bayer.py` | A, B | Bayer reference: split, warp each plane, merge (bit-exact) |
| `model/bayer_a.py`, `model/test_bayer_a.py` | A | Option A as the hardware does it, checked against `bayer.py` |
| `model/memmodel.py` | shared | block / fetch schedules for gray, A and B |
| `sw/` | shared | driver picks the path from MODE (Bayer jobs from step 5.3) |
| `results/hw/` | gray build | Bayer builds go to `results/hw/bayer_a/`, `results/hw/bayer_b/` |

## Known setup items

- Board files, the Vitis qemu folders and the other per-laptop items are in
  [New laptop setup](#new-laptop-setup-do-once-per-laptop).
- D18 confirmed 2026-11-19: DDR FBGA code D9LGQ = MT41J128M16HA-15E:D (Micron FBGA decoder).
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
| `python scripts/board/run_frame.py <image> <transform> <W> <H> [--dry-run] [--bit f] [--init f] [--no-program] [--timeout s]` | One frame with XSDB only (no ARM program), compared with the model (step 4.2a) |
| `python scripts/board/run_job.py <image> <transform> <W> <H> [--load] [--n N] [--poll] [--sw] [--dry-run] [--timeout-ms t] [--bit f] [--init f] [--elf f]` | One job through the ARM application, compared with the model, with timings (step 4.2); `--sw`: the ARM software baseline computes the frame instead of the engine (step 4.4) |
| `python scripts/board/run_all.py --rev c\|d [--sizes WxH,...] [--transforms a,b] [--images a,b] [--n N] [--sw] [--elf f] [--dry-run]` | Full grayscale set through the ARM application (step 4.3): default all 11 transforms at 480x272, 800x480, 2448x2095; one run_job.py per case, the first with `--load`; CSV and summary in `results/board/run_all_rev<r>.*`; last line `RUN_ALL PASS` |

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

## Step 4.2: ARM driver and test application

```
vitis -s sw/patrm_app/build_vitis.py                               # ends with PATRM_APP BUILD OK, writes results/hw/patrm_app.elf
python -m model.test_job_layout                                    # record round trips, C layout against Python
python scripts/board/run_job.py mixed identity 64 64 --load --dry-run   # every XSDB command, no board
```

`sw/patrm_drv` is the driver (spec/memory_map.md section 4), and `sw/patrm_app` is a program that waits for job
descriptors from the PC, runs each one N times, writes the result record and prints one `RESULT ...` line on the UART.
The application keeps running between jobs, so only the first job needs `--load`. Our C files are compiled with
`-Wall -Wextra -Werror -O2`. The build fails on any warning in its log, except that the linker's "LOAD segment with RWX
permissions" message is switched off: it comes from AMD's linker script and means nothing on bare metal.

The interrupt is programmed with trigger value `0x1` (active-high level, `XScuGic_SetPriorityTriggerType`), because the
engine holds its output high until DONE is cleared. The handler clears DONE before it returns.

Verified on hardware on 2026-11-21 (ZedBoard Rev D, `results/hw/rev D` bitstream and ps7_init): all of step 8 below
passes, with the interrupt and with `--poll`, including DDR access through the XSDB APU target while the ARM runs.
`xil_printf` in the 2026.1 standalone BSP is built with `SUPPORT_64BIT_PRINT`, so on the Cortex-A9 a single `l` (`%lu`,
`%lx`) reads a 64-bit argument. Print 32-bit values with `%u` / `%x` / `%d` and `unsigned int` arguments. A stray `%l`
shifts every following argument (the first build crashed with a data abort in `strlen` on a garbage `%s` pointer).

## First lab session

Nothing below has been run on hardware yet. Use Git Bash in the repository root, with `<install>\Vivado\bin` on PATH.
Run the steps in this order.

1. **Board.** Set the boot-mode jumpers JP7 - JP11 to JTAG (all to GND; check against the ZedBoard hardware guide).
   Checked from a photo on 2026-11-19: all five on GND (shunt on the GND + signal pins, 3V3 pin bare).
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
6. **DDR chip marking (D18).** DONE 2026-11-19: D9LGQ = MT41J128M16HA-15E:D, D18 confirmed. Read the marking printed on a DDR3 chip on the board and decode it with Micron's FBGA
   marking decoder. `MT41J128M16HA-15E` confirms D18. `MT41K128M16JT-125` means D18 is reverted: stop and rebuild with
   that part before trusting any DDR result.
7. **Frames with XSDB only (step 4.2a).** No ARM program is involved. Each run programs the bitstream, initialises the
   PS and DDR, loads the source, fills the output area with `0xA5`, starts the engine, polls STATUS and reads the output
   back. Run these in order, and do not go on after a failure:
   ```
   python scripts/board/run_frame.py mixed identity 64 64
   python scripts/board/run_frame.py mixed mirror_cols 64 64
   python scripts/board/run_frame.py mixed rot15 128 96
   python scripts/board/run_frame.py photo rot15 480 272
   python scripts/board/run_frame.py photo rot37 480 272
   ```

   | Run | BYTES_RD (memmodel) | BYTES_WR (W x H) |
   |-----|--------------------:|-----------------:|
   | mixed identity 64x64 | 4,096 | 4,096 |
   | mixed mirror_cols 64x64 | 4,096 | 4,096 |
   | mixed rot15 128x96 | 54,376 | 12,288 |
   | photo rot15 480x272 | 568,496 | 130,560 |
   | photo rot37 480x272 | 730,056 | 130,560 |

   **A pass** ends with `FRAME PASS` and exit code 0, and shows all of these:
   - `BUILD_ID 0x00401001`, and STATUS at DONE with `BUSY=0 DONE=1 ERROR=0 ERR_CODE=0`
   - `differing rows 0` and `differing bytes 0`
   - `LAST ROW (row H-1): MATCHES the model`. The VIP simulation of step 4.1b held back the last write burst, so this
     line is the hardware confirmation that the last burst reaches DDR.
   - `0 of 4096 guard bytes changed`, and BYTES_RD and BYTES_WR marked `same`

   Note CYCLES, RD_STALL and WR_STALL for each run. They are the first measured numbers from the board. To look at a
   result: `python -m model.raw2png build/board/<run folder>/output.raw --w 480 --h 272 --out build/view/out.png`.

   **If a run fails**, check in this order:
   1. **BUILD_ID.** `BOARD ERROR: BUILD_ID` or a hang on that read means the bitstream, the PS setup or the PL clock and
      reset are wrong. Repeat step 3.
   2. **DDR round trip.** Repeat steps 4 to 6. An error on the source or fill words, or scattered wrong bytes, points to
      DDR or the JTAG path and not to the engine.
   3. **ILA build.** Use it when BUILD_ID and DDR are good but the frame is wrong or times out. Bytes that still hold
      `0xA5` were never written, and a `timeout` prints STATUS and the counters. Load the build with one run, arm the ILA,
      then start the frame again without reprogramming. `CTRL.IRQ_EN` is 0 here, so trigger on `hp0_arvalid` or
      `hp1_awvalid`, not on `interrupt`.
      ```
      python scripts/board/run_frame.py mixed identity 64 64 --bit results/hw/patrm_gray_ila.bit
      # Vivado Hardware Manager: open the target, load patrm_gray_ila.ltx, source scripts/board/ila_probes.tcl, arm
      python scripts/board/run_frame.py mixed identity 64 64 --no-program
      ```
8. **Frames through the ARM driver (step 4.2).** Do this after step 7 passes, with the UART terminal open. Build the ELF
   first if `results/hw/patrm_app.elf` is missing: `vitis -s sw/patrm_app/build_vitis.py`. The first command programs the
   board and starts the application. The others reuse the running application.
   ```
   python scripts/board/run_job.py mixed identity 64 64 --load
   python scripts/board/run_job.py mixed mirror_cols 64 64
   python scripts/board/run_job.py mixed rot15 128 96
   python scripts/board/run_job.py photo rot15 480 272
   python scripts/board/run_job.py photo rot37 480 272
   ```
   After `--load` the UART must show `PATRM test application`, then `BUILD_ID 0x00401001, init OK, global timer ... Hz`,
   then `READY`. Each job adds one `RESULT seq=...` line.

   **A pass** ends with `JOB PASS` and exit code 0. BYTES_RD and BYTES_WR are those of the table in step 7, and the checks
   are the same: `differing rows 0`, `differing bytes 0`, `LAST ROW (row H-1): MATCHES the model`, `0 of 4096 guard bytes
   changed`. In addition, `result code 0 (OK)` and `wait mode interrupt`.

   **Timing, N = 10.** Run the same five cases again:
   ```
   python scripts/board/run_job.py mixed identity 64 64 --n 10
   python scripts/board/run_job.py mixed mirror_cols 64 64 --n 10
   python scripts/board/run_job.py mixed rot15 128 96 --n 10
   python scripts/board/run_job.py photo rot15 480 272 --n 10
   python scripts/board/run_job.py photo rot37 480 272 --n 10
   ```
   Note the engine and end-to-end times (min, avg, max), Mpix/s and fps. Engine time runs from the START write to DONE
   being seen, so it should be close to `CYCLES` at 100 MHz. End-to-end time adds the cache work and register setup.

   **If the interrupt never arrives** (`result code 12 (NO_INTERRUPT)` or `11 (TIMEOUT)`), check in this order:
   1. **Is STATUS.DONE set?** `NO_INTERRUPT` means yes: the frame finished and only the interrupt is missing. `TIMEOUT`
      means no: the engine did not finish, so this is not an interrupt problem. Go back to the checks of step 7.
   2. **Is IRQ_EN set?** The UART line `NO INTERRUPT: STATUS=... CTRL=... IRQ_EN=...` must show `IRQ_EN=1`. CTRL bit 3 is
      this bit. `wait mode interrupt` in the run_job output confirms that the job asked for it.
   3. **GIC ID 61.** The same UART line shows the GIC state, read while DONE was still set. It must show `enabled=1` and
      `trigger=1` (level). `pending=0` means the signal never reached the GIC: check `IRQ_F2P[0]` in the block design and
      that the bitstream matches it. `pending=1` means the GIC has it but the ARM did not take it: check that ARM interrupts
      are enabled and the handler is connected.
   4. **Does polling work?** Run `python scripts/board/run_job.py mixed identity 64 64 --poll`. If that passes, the engine,
      DDR and caches are fine and the fault is limited to the interrupt path.

   **Other failures.**
   - `no result record`, with `READY` on the UART: the application runs but XSDB cannot read its record through the APU
     target. This access path could not be tested without a board.
   - `no result record`, with nothing on the UART: the application did not start. Check the `--load` output and step 3.
   - `no result for job N`: the application did not answer. The UART shows how far it got.
   - `still working on job N`: an earlier job has not finished. Use `--load` to start again.

## Step 4.4: ARM software baseline

`sw/patrm_sw/patrm_sw.c` is the same fixed-point warp in plain C (`patrm_sw_gray`), bit-exact with `model/patrm.py`.

1. **Laptop (no board).** `python -m model.test_patrm_sw` compiles it with the laptop gcc at -O2 and -O3 and compares
   every byte with the model (worked example, all transforms x images, board and paper sizes, 300 random transforms,
   identity and mirrors, D3 rejection). Last line `TEST PASS`.
2. **Build both ARM levels.** `PATRM_APP_OPT=O2` (default) and `O3`:
   ```
   PATRM_APP_OPT=O2 vitis -s sw/patrm_app/build_vitis.py      # results/hw/patrm_app.elf
   PATRM_APP_OPT=O3 vitis -s sw/patrm_app/build_vitis.py      # results/hw/patrm_app_o3.elf
   ```
   In PowerShell: `$env:PATRM_APP_OPT='O3'` before the command. With GCC 14.2 and `-mfpu=vfpv3`, `patrm_sw_gray` has
   the same instructions at -O2 and -O3 (only branch addresses differ); both are still measured.
3. **Board.** A job with flags bit 2 runs `patrm_sw_gray` on the ARM instead of the engine (spec/memory_map.md
   section 5). With the UART open, for each ELF:
   ```
   python scripts/board/run_all.py --rev d --sw                                   # -O2, all 33 cases
   python scripts/board/run_all.py --rev d --sw --elf results/hw/patrm_app_o3.elf # -O3
   ```
   A pass ends with `RUN_ALL PASS`: every output bit-exact with the model and the engine counters 0 (the application
   really took the software path). The software warp time and the end-to-end time (with cache work) come from the
   ARM global timer; the summary is in `results/board/run_all_rev<r>_sw_<elf>.txt`. Speedup = software time / engine
   time of the same case in `results/board/run_all_rev<r>.txt`.

   Measured on Rev D (2026-11-22): 33 of 33 bit-exact at -O2 and at -O3. 2448x2095 software warp 342.9 ms (identity,
   -O2) against 51.3 ms on the engine: 6.7x; rot15 6.0x, rot37 3.8x, rot90 3.3x. Over all cases 2.3-6.9x (engine time),
   2.2-5.5x end to end. -O3 measured 1.6-2.3 % slower than -O2.

## Step 5.1: Bayer Option A specification

`spec/interface.md` section 18 specifies MODE 1: one job runs four plane passes (R, Gr, Gb, B) through the same engine,
started by the new module `bayer_seq`; each pass reads mosaic row 2x + o_row, column 2y + o_col and writes its plane
into the interleaved output with WSTRB 8'h55 / 8'hAA (D19). `model/bayer_a.py` is that section as code, and
```
python -m model.test_bayer_a            # about 15 s; --quick skips 480x272
```
checks it bit-exact against `model/bayer.py` warp_bayer (sim sizes, 480x272, random and extreme-zoom transforms),
checks BYTES_RD / BYTES_WR against `model/memmodel.py`, and checks that every pixel's neighbours are inside its block's
fetched rows and columns with at most 64 words per buffer slot. Last line `TEST PASS`. No RTL yet (step 5.2).

## Step 5.2: Bayer Option A RTL (simulation)

New `rtl/bayer_seq.v` runs one pass (gray) or four plane passes (MODE 1) and gives every module the values of the pass;
block_planner, prefetch_ctrl, pixel_fetch, out_fifo and axi_wr_master take them (spec/interface.md sections 18.2,
18.3, as built 18.7). Gray mode is cycle-identical to step 3.7.

```
python scripts/gen_patrm_top_vectors.py                                   # cases.txt + cases_bayer_a.txt
python scripts/sim.py --top tb_bayer_seq -f tb/bayer_seq.f                # pass sequencer alone
python scripts/sim.py --top tb_patrm_top -f tb/patrm_top.f --incdir rtl --plusarg VEC_DIR=data/vectors
python scripts/sim.py --top tb_patrm_top -f tb/patrm_top.f --incdir rtl --define TB_BAYER_A --plusarg VEC_DIR=data/vectors
```
The last command is the Option A build of the engine (MODES 3): 134 MODE 1 jobs and 13 gray jobs, output mosaic
bit-exact with `model/bayer.py`, WSTRB 8'h55 / 8'hAA per pass, BYTES_WR = 2 x W x H. `scripts/regress.py` runs both builds
and three faults (`PATRM_FAULT_A_OCOL`, `PATRM_FAULT_A_WSTRB`, `PATRM_FAULT_A_ROWSTEP`) that must make it fail.

Option A implementation numbers (OOC, 100 MHz): run from `build/ooc/patrm_top_bayer_a`
```
vivado -mode batch -source ../../../vivado/ooc_patrm_top.tcl -tclargs variant=bayer_a     # results/ooc/patrm_top_bayer_a_*
```
(2,620 LUT, 3,612 FF, 8 RAMB36, 17 DSP48E1, WNS +1.238 ns). The board bitstream with Option A is step 5.3.

## Demo in the Vivado GUI

For the review: [docs/vivado-demo.md](docs/vivado-demo.md) shows the block design, implemented design and reports in the Vivado GUI, and a single-image transformation testbench in the Vivado simulator (`python scripts/demo/run_demo_sim.py`).

## Step 10.0: Ethernet feasibility (lwIP echo server builds)

Ethernet (GEM0 = ENET0, on-board RJ45 PHY) is enabled in the verified XSA, and AMD's lwIP 2.2 echo server builds for
the ARM from it. No board and no FPGA rebuild are needed for this step.
```
python scripts/eth/check_xsa_enet.py                 # ENET0 on MIO 16..27, MDIO, 1000 Mbps -> ENET CHECK PASS
vitis -s sw/patrm_eth/build_vitis.py                 # -> PATRM_ETH BUILD OK, results/hw/patrm_eth_echo.elf (not yet run on a board)
```
Vitis 2026.1 + GCC 14 needed three workarounds, all inside `sw/patrm_eth/build_vitis.py` (the install is not changed):
1. The installed `lwip220_v1_4/data/lwip220.yaml` starts with a byte order mark and two comment lines before `%YAML`,
   so the repository scan drops lwIP without a message and `set_lib('lwip220')` fails with "not valid for the given
   processor". The script copies the library to `build/esw_repo/`, fixes the header order and adds it as a LOCAL
   embedded SW repository.
2. AMD's raw-API lwIP options set `NO_SYS_NO_TIMERS 1`, but the library still compiles the Ethernet bridge
   (`netif/bridgeif*.c`), which calls `sys_timeout` -> GCC 14 error. Those two unused files are left out of the copy.
3. lopper writes the end marker of the generated `xtopology_g.c` as `{ NULL }` into an integer field -> GCC 14
   error. The BSP alone gets `-Wno-error=int-conversion` (a warning again, as before GCC 14); our sources keep -Werror.

If a `vitis -s` run fails, its Vitis server (java, `RigelApp`) can stay alive and lock the workspace ("already in
use" / `.lock` in use). Stop it in Task Manager (or `Stop-Process`) before the next run.

## Step 10.1: Ethernet echo on the board, speed next to JTAG

Laptop Ethernet: static 192.168.1.100 / 255.255.255.0, no gateway (Wi-Fi internet is not affected). Direct cable to
the ZedBoard RJ45. Board: `sw/patrm_eth/echo.c` (flow-controlled TCP echo on port 7; AMD's template echo drops data
when its send buffer is full).
```
vitis -s sw/patrm_eth/build_vitis.py                 # -> PATRM_ETH BUILD OK
python scripts/eth/echo_test.py --load               # program + load + test -> ECHO TEST PASS, results/eth/echo_<date>_<time>.*
```
`--load` programs the Rev D bitstream, loads the ELF halted, runs `scripts/eth/mdio_mio.tcl` and starts the core. The
board needs about 27 s to boot (PHY negotiation about 4 s, then the template's DHCP timeout about 12 s; there is no
DHCP server on a direct cable) and then answers ping at 192.168.1.10.

Two more problems found on the board:
1. **MDIO on EMIO.** The current XSA has `PCW_ENET0_GRP_MDIO_IO = EMIO`, so MIO 52/53 (wired to the Marvell PHY) are
   GPIO and lwIP cannot reach the PHY ("Auto negotiation timeout"). `scripts/eth/phy_regs.tcl` reads the PHY over
   MDIO from XSDB; `scripts/eth/mdio_mio.tcl` switches MIO 52/53 to MDIO at run time (SLCR MIO_PIN = 0x280) as an
   interim fix. Proper fix: `CONFIG.PCW_ENET0_GRP_MDIO_IO {MIO 52 .. 53}` in vivado/build.tcl at the next hardware
   build (needs approval; it changes the PS setup only).
2. **No tick timer.** xiltimer's `XILTIMER_tick_timer` defaults to None, so lwIP's timers never run and the DHCP
   wait never ends. The build script sets `ps7_scutimer_0`.

Measured 2026-11-23 (results/eth/echo_2026-11-23_104551.*), 10 runs per size, all identical:

| link | 1 MB | 5 MB |
|---|---|---|
| Ethernet echo, MB/s each direction (min / median / max) | 0.21 / 0.54 / 3.05 | 0.39 / 2.21 / 6.96 |
| JTAG PC -> DDR (put_image) | 0.371 MB/s (2.69 s/MB) | 0.376 MB/s (2.66 s/MB) |
| JTAG DDR -> PC (get_image) | 0.529 MB/s (1.89 s/MB) | 0.574 MB/s (1.74 s/MB) |

Ethernet is correct but not yet fast: GEM0 counted 906 receive overruns in those 20 runs (no FCS, symbol or resource
errors). Each lost frame costs a TCP retransmission timeout, hence runs of 4 to 13 s. Runs without a loss reach about
5 to 7 MB/s each way. `scripts/eth/gem_stats.tcl` reads the counters.

## Step 10.1b: speed per direction

The echo mixes both directions. The board also has a sink (port 5001, PC -> board) and a source (port 5002,
board -> PC); `python scripts/eth/echo_test.py` runs all three (`--tests sink,source` for one direction only).

Measured 2026-11-23 (results/eth/echo_2026-11-23_105757.*), 10 runs per size, all correct, MB/s min / median / max:

| test | 1 MB | 5 MB | GEM0 errors |
|---|---|---|---|
| sink, PC -> board | 104.4 / 107.2 / 109.0 | 97.3 / 109.1 / 109.4 | none |
| source, board -> PC | 93.2 / 97.2 / 98.6 | 97.4 / 98.8 / 99.3 | none |
| echo, both at once | 0.21 / 0.79 / 3.12 | 0.26 / 2.23 / 6.80 | 1023 rx_overruns |
| JTAG PC -> DDR | 0.381 | 0.394 | - |
| JTAG DDR -> PC | 0.525 | 0.574 | - |

Each direction alone runs near gigabit line rate, about 250x faster than JTAG. Receive overruns appear only when the
board receives and sends at full rate at the same time; a PATRM job (upload, run, download) never does that.

## Step 10.2: PATRM jobs over Ethernet

`sw/patrm_eth/eth_job.c` (TCP port 5003, protocol `sw/patrm_eth/patrm_eth.h`) carries the job descriptor and result
record of the JTAG path unchanged: request = 32-byte header + descriptor + source image, response = 32-byte header +
result record + output area. The job runs with the same code as over JTAG: `sw/patrm_job/patrm_jobrun.c`, moved out of
`sw/patrm_app/main.c` (the JTAG app now calls it too). Over Ethernet the engine is polled (lwIP owns the GIC); the ARM
writes the source (flag SRC_CPU, flushed before START).
```
vitis -s sw/patrm_eth/build_vitis.py                          # -> results/hw/patrm_eth.elf
python scripts/eth/eth_link.py --selftest                     # protocol constants against patrm_eth.h
python scripts/board/run_job.py mixed identity 64 64 --link eth --load --bit "results/hw/rev D/patrm_gray.bit" --init "results/hw/rev D/ps7_init.tcl"
python scripts/board/run_all.py --rev d --link eth            # the step 4.3 set -> results/board/run_all_revd_eth.*
```
Every check of the JTAG runner applies (model bit-exact, last row, 4096 guard bytes, BYTES_RD / BYTES_WR predictions,
BUILD_ID). Result 2026-11-23: 33 of 33 PASS, the whole set in 110 s (69 s of it board load and boot).

| size | board receives source | job on the board | download | PC round trip |
|---|---|---|---|---|
| 480x272 identity | 1.6 ms | 2.8 ms (engine 1.3 ms) | 1.5 ms | 18 ms |
| 800x480 identity | 4.5 ms | 7.5 ms (engine 3.8 ms) | 3.8 ms | 27 ms |
| 2448x2095 identity | 62 ms | 93 ms (engine 51 ms) | 47 ms | 215 ms |
| 2448x2095 rot90 | 61 ms | 177 ms (engine 135 ms) | 47 ms | 299 ms |

"Job on the board" includes the 0xA5 fill and cache maintenance of the test (5 MB each); a demo can leave the fill out.
Over JTAG the same 2448x2095 case takes about 25 s.

**Vitis 2026.1 BSP bug found here (affects every interrupt-driven program):** the CMake BSP never defines
`FPU_HARD_FLOAT_ABI_ENABLED`, so `asm_vectors.S` builds an IRQ entry that does not save the VFP registers. AMD's GEM
interrupt handler calls `memcpy` (in `XEmacPs_GetQxOffset`), which uses d0-d7; an interrupt in the middle of our
`memcpy` of a received image made it store 16 bytes of the handler's register-offset table into the image (found by
searching a RAM dump for those 16 bytes). Both build scripts now add `-DFPU_HARD_FLOAT_ABI_ENABLED=1` to the BSP and
check the linked `IRQHandler` for `vpush` (`scripts/amd_tools.py: irq_saves_vfp`). The JTAG app's engine interrupt
handler uses no VFP register, so the step 4.x results were not affected; it was rebuilt with the fix and the step 4.3
set passed again over JTAG (33 of 33, results/board/run_all_revd_jtag_rerun_2026-11-23.*).

CYCLES on the board are not exactly repeatable: the step 4.3 JTAG run (2026-11-21) and the JTAG rerun (2026-11-23)
agree in 4 of 33 cases (-0.25 % .. +0.01 %); Ethernet against them: 3 of 33 (-0.07 % .. +0.18 %). BYTES_RD and
BYTES_WR are identical in all 33 cases in every comparison.
Decided 2026-11-23: Step 10.2's CYCLES check is "within the JTAG run-to-run spread"; it passes. The spread is per-frame noise (no drift, no effect on the output); report speed as min / avg / max over N frames (`--n`).

## Step 10.3: video GUI (frames streamed through the engine over Ethernet)

![video GUI](docs/img/step10_3_video_gui.png)
```
python scripts/eth/make_burst.py                    # test burst: 100 frames 800x480 -> data/gen/burst_800x480/
python scripts/eth/video_gui.py                     # the GUI (Load board, Load frames, Play)
python scripts/eth/video_stream.py --size 640x480 --transform sweep:-30:30 --engine arm    # headless run
python scripts/eth/video_matrix.py                  # fps table, FPGA vs ARM -> results/eth/video_matrix_*.txt
```
Any folder of PNG/JPG frames works (`--frames` or Browse); frames are converted to grayscale and cover-cropped to
W x H before streaming. Transforms: `spin`, `sweep:A:B`, `zoom:S1:S2` or a name from model/transforms.json. Every
output frame is compared with the model in background processes; the GUI shows "model check k of N bit-exact".

Measured 2026-11-23 (results/eth/video_matrix_2026-11-23_132556.txt), 100 frames per run, 1200 of 1200 bit-exact,
stream fps = frames through the board one at a time:

| size | identity FPGA | identity ARM | spin FPGA | spin ARM | engine ms identity FPGA / ARM |
|---|---|---|---|---|---|
| 480x272 | 95.3 | 67.5 | 91.2 | 71.2 | 1.31 / 8.74 |
| 640x480 | 52.2 | 31.3 | 45.4 | 34.6 | 3.07 / 20.57 |
| 800x480 | 41.1 | 25.7 | 40.6 | 27.5 | 3.84 / 25.70 |

The engine is 3-7x faster than the ARM, but at these sizes the stream is limited by moving the frames (800x480: round
trip about 18 ms, of which the engine 4-7 ms). 60 fps at 800x480 would need the upload of the next frame to overlap the
engine run (not done yet).

## Step 10.5: Bayer video in the GUI

Mode "Bayer RGGB" mosaics each colour frame to RGGB on the PC, runs it through Bayer Option A on the board (Bayer A
bitstream + `results/hw/bayer_a/rev_d/patrm_eth.elf`) and checks every output raw against `model/bayer.warp_bayer`.
The colour pictures are a PC-side preview only (one RGB pixel per 2x2 cell). The Bayer A bitstream also runs gray.
```
python scripts/eth/make_burst.py --color                                   # colour test burst -> data/gen/burst_800x480_rgb
python scripts/eth/video_gui.py --mode bayer --frames data/gen/burst_800x480_rgb
    # Bitstream "Bayer A (gray + Bayer)" -> Load board -> Load frames -> Play
python scripts/eth/video_stream.py --mode bayer --load --frames data/gen/burst_800x480_rgb   # headless
```
Result 2026-11-23, 100 frames per run, every frame bit-exact: Bayer 800x480 spin about 40-43 fps (identity 49 fps),
640x480 58 fps, 480x272 103-119 fps; in the GUI about 48-53 fps with the warp alone at about 122 fps.

![Bayer video GUI](docs/img/step10_5_bayer_gui.png)

## Temporary Rev D board: verified build and 48-word DDR test

The matching Rev D bitstream, XSA, PS initialization and ARM bring-up ELF are
shared in [results/hw/rev D](results/hw/rev%20D/README.md), together with build
reports, checksums, reproduction instructions and hardware-test screenshots.
Use the explicit Rev D file paths in that README; the default build and load
configuration remains Rev C. The `results/hw/` parent reports retain the
team's original Vivado 2026.1 Rev C reference results. The temporary Rev D
Vivado 2025.2 reports are kept only in `results/hw/rev D/`.

On 19 November 2026, Rev D bring-up passed and ten successive JTAG DDR tests
each matched 48/48 words with fresh data in the same 192-byte region, without
a reset between rounds. After initialization, run the portable test with:

```powershell
xsdb scripts/board/repeat48.tcl 10
```

This checks debugger-to-DDR access, not full DDR coverage, reset recovery or
the accelerator's PL-to-DDR data path. The standalone PDF report is not in Git.

## Step 5.3: Option A on Rev D (board-verified 2026-11-23)

See [the step 5.3 instructions](docs/step-5.3-revd-offline.md) for builds, offline tests and
the later board checklist. `vivado/build.tcl -tclargs variant=bayer_a rev=d` selects
MODES=3 / BUILD_TYPE=1 and the Rev D DDR part; artifacts go to `results/hw/bayer_a/rev_d/`.
The no-argument gray/Rev C build remains unchanged. Set `PATRM_VARIANT=bayer_a` and
`PATRM_REV=d` when building the matching application with sw/patrm_app/build_vitis.py.
`run_job.py --mode bayer_a --rev d` and `run_all.py --mode bayer_a --rev d` select the
Bayer reference and bundle; `run_all.py --variant bayer_a --mode gray --rev d` checks gray
on the A build. Named Bayer inputs are `chart` or `photo` from generated `rggb_*.raw` files.
New offline checks: `python -m model.test_patrm_drv` and `python -m model.test_bayer_jobs`.
Board result 2026-11-23 (JTAG): Bayer set 66 of 66 and gray-on-A 33 of 33 RUN_ALL PASS, bit-exact; interrupt, polling,
repetition and mixed gray/Bayer jobs pass. Details: results/hw/bayer_a/rev_d/README.md.

## Step 10.4: Ethernet on the Bayer A bitstream

The Ethernet application (step 10.2) built from the Bayer A XSA runs gray and Bayer A jobs; its ELF sits with the A bundle.
The A XSA has the build.tcl MDIO fix, so the loader only checks MIO 52/53 (read-only, `mdio_mio.tcl --check`).
```
$env:PATRM_VARIANT='bayer_a'; $env:PATRM_REV='d'; vitis -s sw/patrm_eth/build_vitis.py   # -> results/hw/bayer_a/rev_d/patrm_eth.elf
python scripts/board/run_job.py chart rot15 128 96 --mode bayer_a --rev d --link eth --load
python scripts/board/run_all.py --mode bayer_a --rev d --images chart,photo --link eth
python scripts/board/run_all.py --variant bayer_a --mode gray --rev d --link eth
```
Result 2026-11-23: Bayer 66 of 66 (135 s for the set, against 689 s over JTAG) and gray-on-A 33 of 33 RUN_ALL PASS,
BYTES_RD / BYTES_WR identical to JTAG in all 99 cases; MIO 52/53 = 0x280 straight from ps7_init. CYCLES: Ethernet vs JTAG
within 0.25 % in 97 of 99 cases; 2448x2048 rot15 +0.34 %, inside that case's own JTAG spread of 0.37 % (5 board loads x
10 frames per link: each load lands at about 7.341 M, 7.353 M or 7.366 M cycles on either link; cause not investigated).
Logs: results/board/step10_4/.

## Step 7.1: PL clock against the global timer

```
python scripts/board/clock_check.py --dry-run        # prints the XSDB script and the five jobs, touches no board
python scripts/board/clock_check.py                  # board running an application (default --link eth, --rev d)
python scripts/board/clock_check.py --link jtag      # the same through the JTAG application
```
Three checks, each within 0.1 % (results/board/step7_1/clock_check_<date>_<time>.txt, last line `CLOCK CHECK PASS`):
1. **Configuration.** `scripts/board/clock_regs.tcl` reads the SLCR clock registers through core 1 (our programs never
   start it; core 0 keeps running): FCLK0 must be 100 MHz and the global timer frequency must equal the `timer_hz` the
   application converts with.
2. **Global timer against the PC clock.** The same script samples the 64-bit global timer 3 times, 30 s apart, with the
   PC time around each read; the slope is the timer frequency, measured independently of the board's crystal.
3. **PL clock against the global timer.** Identity jobs at five sizes, N = 10 each. Engine time (START to DONE, global
   timer) = CYCLES / f_PL + a fixed overhead; the line's slope gives f_PL without the overhead.

The ZedBoard preset runs the CPU at 650 MHz (ARM PLL 1300 MHz / 2), so the **global timer is 325 MHz**, not the
333 MHz of a 667 MHz CPU; the application already converts with 325,000,000 Hz. FCLK0 = IO PLL 1000 MHz / 5 / 2.

Result 2026-11-27 (Rev D, Bayer A bitstream, Ethernet application): FCLK0 configured 100.000000 MHz; global timer
325.0081 MHz against the PC clock (+0.0025 %, read-window bound +-0.012 %); PL clock 100.000025 MHz in global-timer
time (+0.00003 %) and 100.0025 MHz in PC time (+0.0025 %); fixed START/poll overhead 0.36 us, largest residual of the
five-point line 0.018 us. CLOCK CHECK PASS. So CYCLES / 100 MHz is the engine time to better than 0.01 %.
