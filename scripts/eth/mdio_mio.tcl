# Step 10.1 interim fix: route GEM0's MDC/MDIO to MIO 52/53 (the pins wired to the ZedBoard's Marvell PHY).
#
#   xsdb scripts/eth/mdio_mio.tcl [--con]
#
# Why: the current XSA (results/hw/rev D/patrm_gray.xsa) has PCW_ENET0_GRP_MDIO_IO = EMIO, so ps7_init leaves MIO 52/53
# as GPIO (MIO_PIN_52/53 = 0x200) and the MDIO bus reaches no PHY. 0x280 = L3_SEL 4 (MDIO0), LVCMOS 1.8 V, as the
# ZedBoard needs (Zynq TRM UG585, MIO_PIN_xx registers, SLCR 0xF80007D0 / 0xF80007D4). The proper fix is
# CONFIG.PCW_ENET0_GRP_MDIO_IO {MIO 52 .. 53} in vivado/build.tcl at the next hardware build.
# Run after ps7_init (load_run.tcl --no-run). With --con, core 0 is started afterwards.
# Step 10.4: --check writes nothing and fails unless ps7_init already set MIO 52/53 to MDIO (0x280): used with builds
# whose XSA has the vivado/build.tcl fix (e.g. results/hw/bayer_a/rev_d), so the fix itself is tested on the board.

set con 0
set check 0
foreach a $::argv {
    if {$a eq "--con"} { set con 1 } elseif {$a eq "--check"} { set check 1 } else { puts "BOARD ERROR: unknown argument $a"; exit 1 }
}
connect
targets -set -nocase -filter {name =~ "APU*"}
proc rd {a} { return [lindex [mrd -force -value $a] 0] }
puts [format "before: MIO_PIN_52 0x%08X MIO_PIN_53 0x%08X" [rd 0xF80007D0] [rd 0xF80007D4]]
if {!$check} {
    mwr -force 0xF8000008 0xDF0D      ;# SLCR unlock
    mwr -force 0xF80007D0 0x00000280
    mwr -force 0xF80007D4 0x00000280
    mwr -force 0xF8000004 0x767B      ;# SLCR lock
}
set p52 [rd 0xF80007D0]
set p53 [rd 0xF80007D4]
puts [format "[expr {$check ? {check: } : {after: }}] MIO_PIN_52 0x%08X MIO_PIN_53 0x%08X" $p52 $p53]
if {($p52 & 0x3FFF) != 0x280 || ($p53 & 0x3FFF) != 0x280} { puts "BOARD ERROR: MIO 52/53 not MDIO (0x280)"; exit 1 }
if {$con} {
    targets -set -nocase -filter {name =~ "*A9*#0"}
    con
    puts "mdio_mio: core 0 started"
}
disconnect
puts "mdio_mio: DONE"
exit 0
