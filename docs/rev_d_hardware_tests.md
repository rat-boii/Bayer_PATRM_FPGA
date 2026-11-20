# PATRM on the ZedBoard Rev D: hardware tests, commands and results

Date of the tests: 2026-11-20. Status: grayscale PATRM verified on a **temporary Rev D board**. The team's own board is
Rev C (D18); everything here has to be repeated on Rev C in a later session (checklist at the end). Nothing here changes
a plan step or a fixed decision.

## 1. What was tested

| Item | Value |
|---|---|
| Board | ZedBoard Rev D (borrowed), JTAG boot mode, PS_VERSION 3 (silicon 3.1, MCTRL 0x30800100) |
| Files | `results/hw/rev D/`: `patrm_gray.bit`, `ps7_init.tcl`, `bringup.elf` (DDR part MT41K128M16 JT-125, built with Vivado 2025.2) |
| Host tools | `xsdb` of Vivado 2026.1 (`C:\AMDDesignTools\2026.1\Vivado\bin`), Python 3.11, pyserial |
| Console | COM9 (Cypress bridge), 115200 8N1 |
| PL clock | 100 MHz (requested; not yet measured against the ARM timer, plan step 7.1) |
| Design | grayscale PATRM, no ILA; 2,670 LUT, 8 RAMB36, 17 DSP48E1, WNS +0.779 ns, WHS +0.024 ns (bundle reports) |
| Code state | repo `main` at b73b40d (pulled 2026-11-20) |

Everything runs from the command line. XSDB connects to `hw_server` over JTAG, resets the system, programs the bitstream
(`fpga -file`), runs `ps7_init`, then either loads and starts an ARM program (`dow`, `con`) or writes the PATRM registers
directly, starts the engine and polls STATUS. Nothing is written to flash; the design is gone at power-off.

## 2. Commands

Run from the repository root. `xsdb` must be on PATH (Git Bash: `export PATH="/c/AMDDesignTools/2026.1/Vivado/bin:$PATH"`).
For Rev D use the explicit file paths; the defaults point to the Rev C files in `results/hw/`.

```bash
BIT='results/hw/rev D/patrm_gray.bit'
INIT='results/hw/rev D/ps7_init.tcl'
```

**a) Is the board visible?** The JTAG chain must show APU (two Cortex-A9) and xc7z020:
```bash
echo 'connect; puts [targets]; exit' > t.tcl && xsdb t.tcl
```

**b) Bring-up** (program FPGA, init PS/DDR, run the bring-up ELF). Output must end with `load_run: DONE`; the UART must show
`BUILD_ID 0x00401001`, `STATUS 0x00000000`, `BRINGUP PASS`:
```bash
xsdb scripts/board/load_run.tcl --bit "$BIT" --init "$INIT" --elf 'results/hw/rev D/bringup.elf'
```
The UART text is printed right after `con`. To capture it, open COM9 first (PuTTY, or pyserial) and then run the command.

**c) DDR round trip over JTAG** (1 MB shown; repeat with 5242880 bytes). `cmp` must print nothing and `SAME` is printed:
```bash
mkdir -p build/board
python -c "import os; open('build/board/rt_1M.bin','wb').write(os.urandom(1048576))"
xsdb scripts/board/put_image.tcl build/board/rt_1M.bin 0x10000000
xsdb scripts/board/get_image.tcl 0x10000000 1048576 build/board/rt_1M.back
cmp build/board/rt_1M.bin build/board/rt_1M.back && echo SAME
```

**d) One frame through the PATRM engine** (no ARM program; compares with the Python model row by row):
```bash
python scripts/board/run_frame.py <image> <transform> <W> <H> --bit "$BIT" --init "$INIT"
python scripts/board/run_frame.py photo rot15 800 480 --bit "$BIT" --init "$INIT"
```
`<image>` is a name from `data/gen` (`mixed`, `photo`) or a raw GRAY8 file; `<transform>` is one of `identity, mirror_cols,
mirror_rows, rot5, rot15, rot37, scale0p8, scale1p25, combined, rot90, rot180`. A pass ends with `FRAME PASS` and shows
STATUS DONE with ERROR=0, 0 differing bytes, `LAST ROW ... MATCHES the model`, 0 guard bytes changed, and BYTES_RD /
BYTES_WR equal to the predictions. Results are kept in `build/board/frame_<image>_<transform>_<W>x<H>/`
(`source.raw`, `expected.raw`, `output.raw`, `xsdb.log`); that folder is not tracked by git.

**e) View a raw frame as PNG:**
```bash
python -m model.raw2png "build/board/<run folder>/output.raw" --w 800 --h 480 --out build/view/out.png
```

**f) Your own PNG and your own parameters** (runs steps d and e in one command; writes the PNG only if the board output is
bit-exact with the model):
```bash
python scripts/board/png_transform.py in.png out.png --rot 20 --sx 0.9 --sy 0.9 --shift 10 -5 --rev d
python scripts/board/png_transform.py in.png out.png --mirror-cols --rev d      # left-right flip (HUD mirror)
python scripts/board/png_transform.py in.png out.png --rot 20 --model-only      # preview, no board
```
Options: `--rot DEG` (+ = counter-clockwise), `--sx`, `--sy`, `--shift ROWS COLS`, `--mirror-cols` (left-right),
`--mirror-rows` (top-bottom), `--size WxH`, `--rev c|d`, `--bit`, `--init`, `--timeout`, `--model-only`, `--dry-run`.
The width is reduced to a multiple of 8 by resizing if needed (D3); maximum 4096 x 4096 (D11).

## 3. Results (Rev D board, 2026-11-20)

| Test | Result |
|---|---|
| JTAG chain | APU (2 x Cortex-A9) and xc7z020 visible |
| Bring-up | `BUILD_ID 0x00401001 (expected 0x00401001)`, `STATUS 0x00000000`, `BRINGUP PASS` |
| DDR round trip, 1 MB | SAME; write 2.75 s/MB, read 2.02 s/MB |
| DDR round trip, 5 MB | SAME; write 2.81 s/MB, read 2.00 s/MB |
| Frames | 15 of 15 runs `FRAME PASS`, 0 differing bytes, last row matches, 0 guard bytes changed, BYTES_RD and BYTES_WR equal the predictions, WR_STALL 0 |

Per-frame counters. fps = 100e6 / CYCLES (PL compute only, assuming 100 MHz); Mpix/s = output pixels / time.

| Size (W x H) | Transform | CYCLES | ms | fps | Mpix/s | BYTES_RD | BYTES_WR | RD_STALL | RD stall % |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 64x64 | identity | 4,252 | 0.043 | 23,518 | 96.3 | 4,096 | 4,096 | 48 | 1.1 |
| 64x64 | mirror_cols | 4,252 | 0.043 | 23,518 | 96.3 | 4,096 | 4,096 | 48 | 1.1 |
| 128x96 | rot15 | 13,311 | 0.133 | 7,513 | 92.3 | 54,376 | 12,288 | 907 | 6.8 |
| 480x272 | rot15 | 138,245 | 1.382 | 723.4 | 94.4 | 568,496 | 130,560 | 7,572 | 5.5 |
| 480x272 | rot37 | 220,038 | 2.200 | 454.5 | 59.3 | 730,056 | 130,560 | 88,374 | 40.2 |
| 640x480 | rot15 | 326,459 | 3.265 | 306.3 | 94.1 | 1,364,688 | 307,200 | 19,141 | 5.9 |
| 640x480 | rot37 | 542,260 | 5.423 | 184.4 | 56.7 | 1,834,992 | 307,200 | 233,820 | 43.1 |
| 800x480 | rot15 | 410,242 | 4.102 | 243.8 | 93.6 | 1,681,784 | 384,000 | 26,139 | 6.4 |
| 800x480 | rot37 | 665,021 | 6.650 | 150.4 | 57.7 | 2,187,056 | 384,000 | 279,468 | 42.0 |
| 800x480 | mirror_cols | 384,164 | 3.842 | 260.3 | 100.0 | 859,264 | 384,000 | 61 | 0.0 |
| 800x480 | mirror_rows | 384,162 | 3.842 | 260.3 | 100.0 | 859,264 | 384,000 | 59 | 0.0 |
| 1920x1080 | rot15 | 2,278,903 | 22.789 | 43.9 | 91.0 | 9,035,032 | 2,073,600 | 205,185 | 9.0 |
| 1920x1080 | rot37 | 3,687,189 | 36.872 | 27.1 | 56.2 | 11,578,264 | 2,073,600 | 1,610,384 | 43.7 |
| 2448x2095 | rot15 | 5,686,687 | 56.867 | 17.6 | 90.2 | 22,900,352 | 5,128,560 | 558,011 | 9.8 |
| 2448x2095 | rot37 | 9,613,512 | 96.135 | 10.4 | 53.3 | 31,128,912 | 5,128,560 | 4,481,932 | 46.6 |

64x64 and 128x96 use the synthetic `mixed` image; the others use the test photo scaled to the size (2448x2095 is the
paper's W x H, D7). Also run with `png_transform.py`: 800x480, rot 20, scale 0.9, shift (10, -5): 501,979 cycles (5.02 ms),
bit-exact, and its PNG is pixel-identical to the `--model-only` PNG.

### Observations

- All frames are bit-exact with the Python model, including the last row. The simulation (step 4.1b) could not show that
  the last write burst reaches DDR; the hardware does.
- Mirror and identity run at about 1 pixel per cycle (800x480 mirror: 384,000 pixels in 384,164 cycles, about 260 fps
  PL-only) with almost no read stalls.
- rot15 sustains 90 to 94 Mpix/s. At the paper size it takes 56.9 ms (17.6 fps); at 1920x1080 it is 43.9 fps.
- rot37 sustains only 53 to 59 Mpix/s: read stalls are about 40 to 47 % of the cycles at 480x272 and above, so the
  DDR-to-BRAM prefetch does not hide the latency for steep rotations. The cause has not been analysed.
- The paper reports 25 fps (about 128 Mpix/s) at 2448x2095. The engine writes at most 1 pixel per cycle, so at 100 MHz
  the ceiling is 100 Mpix/s (about 19.5 fps at that size). Our rot15 is below the paper's rate. This is a design limit, not
  a bug, and has to be stated in the paper comparison. No speedup is claimed: the ARM baseline (step 4.4) is not measured.
- An 800x480 mirror moves about 0.86 MB in and 0.38 MB out per frame: roughly 320 MB/s at 260 fps (ESTIMATE; the HP port
  limit has not been checked).

## 4. Limits of these results

- **Rev D board, Vivado 2025.2 bundle.** Not the Rev C reference. The DDR part differs (D18), so stall counts may differ.
  The Rev C lab notes of 2026-11-19 (`results/lab/2026-11-19/`, untracked) record a different outcome on the Rev C board
  with the Rev C build: the PS reported silicon revision 0 (MCTRL 0x0), and a 48-word DDR check failed. The Rev D board
  reports PS_VERSION 3 and passes. Whether the difference comes from the silicon revision, the DDR part or the
  initialisation is not known; do not assume Rev C will behave like Rev D.
- fps values are PL compute time from the CYCLES counter at an assumed 100 MHz. They exclude loading and reading images
  (JTAG: 2 to 3 s per MB, so a PC cannot feed a frame stream).
- Not measured: continuous back-to-back frames (needs the ARM job-loop app, step 4.2 on hardware), the interrupt and
  cache path of the driver, the PL clock against the ARM timer (step 7.1), the ARM baseline (step 4.4), and anything Bayer.

## 5. To repeat on the Rev C board (on your mark)

1. `python scripts/check_setup.py`, then confirm boot jumpers (JP7 to JP11 on GND), SW8 off/on as in the README, USB on PROG (J17) and UART (J14).
2. Rebuild or use the Rev C files in `results/hw/` (they are not in git; see README step 4.1). Use no `--rev d`.
3. Bring-up (2b) with default paths: `xsdb scripts/board/load_run.tcl`, expect `BRINGUP PASS`. If DDR fails as on 2026-11-19, stop and diagnose DDR first (README "If a run fails", `results/lab/2026-11-19/notes_ddr_experiments.md`).
4. DDR round trips, 1 MB and 5 MB (2c), both `SAME`.
5. The five README frames (identity, mirror_cols 64x64; rot15 128x96; photo rot15 and rot37 480x272), then 640x480, 800x480, 1920x1080, 2448x2095 with rot15 and rot37 and the two mirrors, using the commands in 2d.
6. Compare CYCLES / RD_STALL with the table in section 3 and label the Rev C numbers as the reference.
7. Then the step 4.2 job app (`run_job.py`, N = 200 back-to-back frames) for the continuous frame rate and the interrupt path.
