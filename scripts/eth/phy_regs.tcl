# Step 10.1 debug: read the Ethernet PHY registers over MDIO through GEM0, from XSDB (no ARM program needed, but the
# PS must be initialised: run after load_run.tcl). Clause 22 reads via the GEM0 PHY maintenance register.
#
#   xsdb scripts/eth/phy_regs.tcl            scan MDIO addresses 0..31 (ID registers), then dump the PHY found
#
# GEM0 (Zynq TRM UG585, ch. 16): net_ctrl 0xE000B000 (bit 4 = MDIO enable), net_cfg 0xE000B004 (bits 20:18 = MDC
# divisor), net_status 0xE000B008 (bit 2 = PHY management idle), phy_maint 0xE000B034.

set GEM 0xE000B000
proc rd {a} { return [lindex [mrd -force -value $a] 0] }

proc mdio_read {phy reg} {
    global GEM
    # wait idle
    for {set i 0} {$i < 1000} {incr i} { if {[rd [expr {$GEM + 0x8}]] & 0x4} break }
    set cmd [expr {(1 << 30) | (2 << 28) | (($phy & 0x1F) << 23) | (($reg & 0x1F) << 18) | (2 << 16)}]
    mwr -force [expr {$GEM + 0x34}] $cmd
    for {set i 0} {$i < 1000} {incr i} { if {[rd [expr {$GEM + 0x8}]] & 0x4} break }
    return [expr {[rd [expr {$GEM + 0x34}]] & 0xFFFF}]
}

connect
targets -set -nocase -filter {name =~ "APU*"}
set ctrl [rd $GEM]
set cfg  [rd [expr {$GEM + 4}]]
puts [format "GEM0 net_ctrl 0x%08X (MDIO enable %d), net_cfg 0x%08X (MDC div %d)" $ctrl [expr {($ctrl >> 4) & 1}] $cfg [expr {($cfg >> 18) & 7}]]
if {!(($ctrl >> 4) & 1)} {
    puts "MDIO was disabled; enabling it for this read"
    mwr -force $GEM [expr {$ctrl | 0x10}]
}
set found {}
for {set a 0} {$a < 32} {incr a} {
    set id1 [mdio_read $a 2]
    set id2 [mdio_read $a 3]
    if {$id1 != 0xFFFF && $id1 != 0} {
        puts [format "MDIO addr %2d: ID1 0x%04X ID2 0x%04X" $a $id1 $id2]
        lappend found $a
    }
}
puts "PHY addresses answering: $found"
foreach a $found {
    mdio_read $a 22   ;# current page
    puts [format "addr %d page reg22 = 0x%04X" $a [mdio_read $a 22]]
    foreach {reg name} {0 control 1 status 4 an_adv 5 an_partner 9 gig_ctrl 10 gig_status 16 copper_ctrl1 17 copper_status1} {
        set v [mdio_read $a $reg]
        puts [format "addr %d reg %2d %-15s 0x%04X" $a $reg $name $v]
    }
    set st [mdio_read $a 1]
    puts [format "  status: link %d, autoneg complete %d, autoneg ability %d" [expr {($st >> 2) & 1}] [expr {($st >> 5) & 1}] [expr {($st >> 3) & 1}]]
    set cs [mdio_read $a 17]
    puts [format "  copper status: resolved %d, link %d, speed code %d (2 = 1000), duplex %d" [expr {($cs >> 11) & 1}] [expr {($cs >> 10) & 1}] [expr {($cs >> 14) & 3}] [expr {($cs >> 13) & 1}]]
}
disconnect
puts "phy_regs: DONE"
exit 0
