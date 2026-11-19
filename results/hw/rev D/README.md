# Temporary ZedBoard Rev D build and DDR test

This folder contains the matching files for the temporary **ZedBoard Rev D**
used on 19 November 2026. The shared build script still defaults to the team's
Rev C DDR part. Use this folder's files together when working with Rev D.

## Configuration and files

- DDR part: **MT41K128M16 JT-125**, matching the Digilent Rev D schematic and
  ZedBoard 1.3 preset. Confirm the physical board before using this configuration.
- Vivado / Vitis / XSDB: **2025.2**. Arm GNU Toolchain: **15.3.Rel2**.
- Grayscale PATRM, 100 MHz PL clock, without ILA.
- `patrm_gray.bit`: FPGA configuration.
- `patrm_gray.xsa`: exported hardware, containing the same bitstream.
- `ps7_init.tcl`: matching PS and DDR initialization.
- `bringup.elf`: ARM Cortex-A9 bring-up application built from this XSA.
- `summary.txt`, reports, and build logs: implementation/build evidence.
- `manifest.json`: file sizes, SHA-256 checksums, and observed validation scope.
- `build_recipe.md`: how to reproduce the isolated Rev D build.

Vivado passed its build checks: WNS +0.779 ns, WHS +0.024 ns at 100 MHz.
The four existing PSU-1..4 board-preset critical warnings remain recorded in
the reports; no new warning exemptions were introduced. Vitis printed
`BRINGUP BUILD OK`; its default linker script produced an RWX-segment warning,
recorded in `software_build.log`.

## Load the board

Run from the project root in PowerShell, with the correct Rev D board powered
on in JTAG boot mode. Open USB-UART in PuTTY at 115200, 8N1, no flow control
(COM3 was assigned on the test laptop; check yours).

```powershell
$xsdb = 'C:\AMDDesignTools\2025.2\Vivado\bin\xsdb.bat'
& $xsdb scripts/board/load_run.tcl --bit 'results/hw/rev D/patrm_gray.bit' --init 'results/hw/rev D/ps7_init.tcl' --elf 'results/hw/rev D/bringup.elf'
```

This command resets the system, programs the FPGA, initializes DDR, and starts
the ARM program. It printed `load_run: DONE`. UART showed:

```text
BUILD_ID    0x00401001 (expected 0x00401001)
STATUS      0x00000000 (expected 0x00000000)
BRINGUP PASS
```

To check file paths without accessing hardware, add `--dry-run` to the load
command. Use the explicit Rev D paths; the default loader paths select the
parent folder's Rev C files.

## Repeat the 48-word DDR test without resets

After initialization, keep the board powered on and run:

```powershell
& $xsdb scripts/board/repeat48.tcl 10
```

The portable test script writes 48 new pseudorandom 32-bit words (192 bytes)
to `0x10000000` each round, reads the same 48 words, and compares every value.
Word starts run through `0x100000BC`; the final byte is `0x100000BF`.
Each round overwrites the previous data in the same region.

The script halts ARM core 0 once for debugger memory access, performs all
rounds without resetting or reprogramming, then resumes the core if it was
previously running and disconnects. It stops on an access error, a short read,
or a mismatch and reports the mismatched addresses/values. Its initial seed
comes from the host clock; the observed run did not record the seed/data.

**Observed result on 19 November 2026:**

```text
Round 1: 48 / 48 words matched
Round 2: 48 / 48 words matched
Round 3: 48 / 48 words matched
Round 4: 48 / 48 words matched
Round 5: 48 / 48 words matched
Round 6: 48 / 48 words matched
Round 7: 48 / 48 words matched
Round 8: 48 / 48 words matched
Round 9: 48 / 48 words matched
Round 10: 48 / 48 words matched
DDR TEST PASS: 10 / 10 rounds passed; no reset between rounds
```

This is 480 word comparisons with zero mismatches in 192 distinct bytes.
See the operator-supplied screenshots in `evidence/`. The script's comparator
was also tested offline: injecting one corrupted word produced 47/48 matches
and failure, with ARM-resume cleanup verified using debugger stubs.

## Scope

This validates repeated **JTAG/debugger-to-DDR** access in the tested region
and initial ARM/UART/AXI-Lite bring-up. It does not establish full-DDR coverage,
soft-reset recovery, retention, bandwidth, or PATRM's PL-to-DDR AXI/image path.
The earlier reset/initialization was before the loop, not between rounds.

The standalone PDF report remains outside the repository by request.

## References

- [Digilent Rev D.2 schematic, change history: DDR parts IC25/IC26](https://digilent.com/reference/_media/zedboard:zedboard_sch.pdf)
- [Digilent ZedBoard 1.3 preset](https://github.com/Digilent/vivado-boards/blob/master/new/board_files/zedboard/1.3/preset.xml)
