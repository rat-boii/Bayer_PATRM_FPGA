# Step 5.3: Option A integration for Rev D (laptop portion)

Status: LAPTOP PORTION VERIFIED (23 November 2026). This does not complete step 5.3: no Option A board test has been run.
The next board session must pass the checks below before a step-5.3 tag is made.

## Scope

- Reuse the step 5.2 RTL unchanged; build MODES=3, BUILD_TYPE=1 at 100 MHz.
- Explicit `rev=d` selects MT41K128M16 JT-125. The shared no-argument gray/Rev C build
  still selects MT41J128M16 HA-15E. Never substitute the ZC702 preset.
- Keep Option A outputs in `results/hw/bayer_a/rev_d/`; the verified gray bundle is untouched.
- ARM driver accepts MODE 1 only when the bitstream advertises it; MODE 2 remains rejected.
- D2 shifts use quantized integers, 64-bit intermediates and floor division by two. D4
  checks cover the full mosaic and all four planes. Register/job layouts are unchanged.
- Board runners use the Bayer reference for raw RGGB, predict all four pass reads and
  require BYTES_WR=2*W*H (bus bytes), correct last row and untouched guard bytes.
- `--variant bayer_a --mode gray` lets the full gray regression use the new A bitstream.

## Offline verification

Run from the repository root in PowerShell, with Python and the AMD tools available:

```powershell
python -m model.gen_images
python -m model.test_patrm_drv
python -m model.test_bayer_jobs
python scripts/regress.py
```

The driver test compiles the actual C driver at -O2/-O3 with host BSP mocks and compares
validation and every configuration write against model/job.py. It does not prove real
interrupt delivery, cache behavior, DDR access or hardware execution. The job test supplies
synthetic results and deliberately corrupts build IDs, byte counts, the final pixel and guard.

Build the board files (example for this laptop's installed 2025.2; teammates use their own
installed path, normally 2026.1). Build success requires the printed final check, not only
the process exit code:

```powershell
$vivado = 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat'
& $vivado -mode batch -source vivado/build.tcl -tclargs variant=bayer_a rev=d
# Require BUILD: all checks passed, WNS >= 0, WHS >= 0, correct DDR / MODES / BUILD_TYPE.

$env:XILINX_VIVADO = 'C:\AMDDesignTools\2025.2\Vivado'
$env:PATH = 'C:\ArmGNU\bin;' + $env:PATH
$env:PATRM_VARIANT = 'bayer_a'
$env:PATRM_REV = 'd'
& 'C:\AMDDesignTools\2025.2\Vitis\bin\vitis.bat' -s sw/patrm_app/build_vitis.py
# Require PATRM_APP BUILD OK and zero warnings from our application sources.
Remove-Item Env:PATRM_VARIANT, Env:PATRM_REV
```

The builder checks that the program stays below 0x0F000000. The Option A ELF is placed
alongside its XSA, not over the hardware-verified grayscale ELF. Build reports identify
the actual tool version; builds from different tool versions are not assumed identical.

## Board session when Rev D is available

Connect PROG and UART, select JTAG boot, power on and open the detected UART at 115200 8N1.
Use the Option A application, not the older bringup ELF that expects the gray BUILD_ID.

```powershell
python scripts/board/run_job.py chart identity 64 64 --mode bayer_a --rev d --load
python scripts/board/run_job.py chart rot15 128 96 --mode bayer_a --rev d --n 10
python scripts/board/run_job.py chart rot37 128 96 --mode bayer_a --rev d --poll
python scripts/board/run_all.py --mode bayer_a --rev d --images chart,photo
python scripts/board/run_all.py --variant bayer_a --mode gray --rev d
```

Require BUILD_ID 0x00403101 (version 1, build A, modes 3, block max 64), JOB PASS for
every job and RUN_ALL PASS for both sets. All output bytes must equal the reference,
BYTES_RD must match the four-pass model, BYTES_WR must be 2*W*H for A or W*H for gray,
and guard bytes must stay unchanged. Confirm interrupt and polling, repeated jobs,
and gray/Bayer jobs back to back without reloading between individual jobs.

Save UART logs, result CSVs and build reports. Only then mark 5.3 passed and tag it.
Simulation FPS and vectorless power remain simulation results and estimates respectively.

## Local results, 23 November 2026

Vivado/Vitis 2025.2: complete Rev D A build passed at 100 MHz (WNS +0.938 ns,
WHS +0.055 ns); 43-item full regression passed; application ELF 309,448 bytes
passed flag, warning and address-range checks. See results/hw/bayer_a/rev_d/README.md
and manifest.json for scope, resource counts, known vendor warnings and source/artifact hashes.
Vitis 2025.2 does not create the expected application build.log, so the builder now saves
the exact application build stream itself before applying the unchanged warning checks.
No changes to the RTL datapath, reference model, register layout or descriptor layout.
No hardware execution, real interrupt/cache validation or A performance measurements.
