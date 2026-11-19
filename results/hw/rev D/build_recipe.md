# Reproducing this temporary Rev D build

The source revision for this bundle was `cad9405`; the later documentation-only
commit `aebb9f0` does not change the RTL or software. No PATRM RTL was changed.
The default `vivado/build.tcl` remains configured for the team's Rev C board.

1. Use a short staging directory outside Windows/System32, with no spaces, for
   example `C:\work\patrm_revd`. Copy `rtl/`, `vivado/` and `sw/` into it.
   Optionally copy `results/ooc/patrm_top_summary.txt` for the report comparison.
2. In the **staged copy only**, change the DDR part near the top of
   `vivado/build.tcl`:

   ```tcl
   set ddr_part "MT41K128M16 JT-125" ;# temporary ZedBoard Rev D
   ```

3. Use Vivado/Vitis 2025.2 with Digilent ZedBoard 1.3 board files and device
   `xc7z020clg484-1`. In the staged `build/vivado` directory, run:

   ```powershell
   vivado -mode batch -source ../../vivado/build.tcl
   ```

   Require `BUILD: all checks passed` and verify the DDR part in `summary.txt`.
4. Set `XILINX_VIVADO` to the Vivado installation and add the Arm GNU
   `arm-none-eabi` compiler's `bin` directory to PATH. From the staging root:

   ```powershell
   vitis -s sw/bringup/build_vitis.py
   ```

   Require `BRINGUP BUILD OK`, not only a zero Vitis exit code. Both
   `a9_linux/qemu` and `a9_standalone/qemu` directories under
   `<install>/Vitis/data/emulation/platforms/zynq/sw/` had to be created on the
   test laptop before Vitis platform creation worked.
5. Collect the matching `.bit`, `.xsa`, `ps7_init.tcl`, `bringup.elf` and reports
   from the staging `results/hw/`. Keep them in a separate Rev D output folder.
   Recompute the manifest if regenerating this bundle; do not mix artifacts
   from different builds or board configurations.

The original local workspace was `build/rd`. Build/runtime directories remain
ignored by Git. The committed bundle is sufficient for loading the board;
rebuilding is optional. A 32-bit compiler cannot reliably access a project
under Windows/System32 because of Windows filesystem redirection.
