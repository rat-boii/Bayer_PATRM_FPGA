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
