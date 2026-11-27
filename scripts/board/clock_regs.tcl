# Step 7.1: read the PS clock configuration and sample the ARM global timer against the host clock.
#
#   xsdb scripts/board/clock_regs.tcl [--wait <seconds>] [--samples <n>]
#
# Works while our application runs on core 0: everything is read through core 1, which our programs never start (it
# waits in the boot ROM). The global timer (0xF8F00200) is a CPU-private register, not reachable through the memory
# port while a core runs, so core 1 is halted for the reads and resumed at the end. Core 0 is never touched.
# Output lines for scripts/board/clock_check.py:
#   REG <name> 0x<value>                     SLCR clock registers
#   GT <host_us_before> <host_us_after> <count>   global timer count, host clock (Tcl clock microseconds) around the read
#   CLOCK_REGS DONE / BOARD ERROR: <reason>
# The host clock is the PC's; the board's clocks come from its own 33.333 MHz crystal, so the GT samples measure the
# global timer frequency independently of the board.

set wait_s 30
set samples 3
for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    switch -- $a {
        --wait    { incr i; set wait_s [lindex $argv $i] }
        --samples { incr i; set samples [lindex $argv $i] }
        default   { puts "BOARD ERROR: unknown argument $a"; exit 1 }
    }
}
if {![string is double -strict $wait_s] || $wait_s < 1} { puts "BOARD ERROR: --wait must be >= 1 s"; exit 1 }
if {![string is integer -strict $samples] || $samples < 2} { puts "BOARD ERROR: --samples must be >= 2"; exit 1 }

if {[catch {connect} e]} { puts "BOARD ERROR: connect failed: $e"; exit 1 }
after 500
if {[catch {targets -set -nocase -filter {name =~ "*Cortex-A9*#1*"}} e]} {
    puts "BOARD ERROR: core 1 not found: $e"; exit 1
}
set st [state]
set was_running [expr {[string match -nocase "*Running*" $st] ? 1 : 0}]
if {$was_running} { if {[catch {stop} e]} { puts "BOARD ERROR: cannot halt core 1: $e"; exit 1 } }
after 100

# SLCR clock registers (Zynq-7000 TRM UG585, appendix B.28)
foreach {name addr} {
    ARM_PLL_CTRL   0xF8000100
    DDR_PLL_CTRL   0xF8000104
    IO_PLL_CTRL    0xF8000108
    ARM_CLK_CTRL   0xF8000120
    FPGA0_CLK_CTRL 0xF8000170
    CLK_621_TRUE   0xF80001C4
    GT_CONTROL     0xF8F00208
} {
    if {[catch {mrd -value $addr} v]} { puts "BOARD ERROR: read $name ($addr): $v"; exit 1 }
    puts [format "REG %s 0x%08X" $name $v]
}

# one 64-bit global timer read: high, low, high again (retry if the low word wrapped in between)
proc gt_read {} {
    for {set k 0} {$k < 5} {incr k} {
        set t0 [clock microseconds]
        set hi1 [mrd -value 0xF8F00204]
        set lo  [mrd -value 0xF8F00200]
        set hi2 [mrd -value 0xF8F00204]
        set t1 [clock microseconds]
        if {$hi1 == $hi2} { return [list $t0 $t1 [expr {(wide($hi1) << 32) | wide($lo)}]] }
    }
    error "global timer high word kept changing"
}

for {set s 0} {$s < $samples} {incr s} {
    if {$s > 0} {
        # resume core 1 while waiting, so it stays in its normal state; halt it again for the read
        if {$was_running} { con }
        after [expr {int($wait_s * 1000)}]
        if {$was_running} { stop; after 50 }
    }
    if {[catch {gt_read} r]} { puts "BOARD ERROR: $r"; exit 1 }
    puts "GT [lindex $r 0] [lindex $r 1] [lindex $r 2]"
}

if {$was_running} { con }
puts "CLOCK_REGS DONE"
