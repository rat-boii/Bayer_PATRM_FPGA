# Step 10.1 debug: read (and so clear) the GEM0 statistics counters over JTAG while the ARM program keeps running.
#
#   xsdb scripts/eth/gem_stats.tcl
#
# Offsets: Zynq TRM UG585, GEM register summary (counters clear on read). Core 0 is not stopped (memory access with
# -force through the debug AP), so the echo server stays up.

proc rd {a} { return [lindex [mrd -force -value $a] 0] }
connect
targets -set -nocase -filter {name =~ "APU*"}
set GEM 0xE000B000
foreach {off name} {
    0x108 frames_tx 0x134 tx_underruns 0x138 single_collisions 0x158 frames_rx 0x184 undersize_rx 0x188 oversize_rx
    0x18C jabbers_rx 0x190 fcs_errors 0x194 length_field_errors 0x198 rx_symbol_errors 0x19C alignment_errors
    0x1A0 rx_resource_errors 0x1A4 rx_overruns 0x1A8 ip_csum_errors 0x1AC tcp_csum_errors 0x1B0 udp_csum_errors
} {
    puts [format "%-20s %10u" $name [rd [expr {$GEM + $off}]]]
}
puts [format "net_cfg 0x%08X  rx_status 0x%08X  tx_status 0x%08X  dma_cfg 0x%08X" \
    [rd [expr {$GEM + 0x4}]] [rd [expr {$GEM + 0x20}]] [rd [expr {$GEM + 0x14}]] [rd [expr {$GEM + 0x10}]]]
disconnect
puts "gem_stats: DONE"
exit 0
