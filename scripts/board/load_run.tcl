# Program the bitstream, initialise the PS and DDR, download an ELF and run it, over USB-JTAG (steps 0.2 and 4.1).
#
#   xsdb scripts/board/load_run.tcl [--dry-run] [--bit <file>] [--init <ps7_init.tcl>] [--elf <file>] [--no-run]
#
# Defaults: results/hw/patrm_gray.bit, results/hw/ps7_init.tcl, results/hw/bringup.elf. With --no-run the ELF is loaded
# and core 0 stays halted. --dry-run checks the files and prints every step without touching the board.
# Open the UART first (USB-UART connector, 115200 8N1): the program prints there.

source [file join [file dirname [file normalize [info script]]] common.tcl]

set hw   [file join $board::repo results hw]
set bit  [file join $hw patrm_gray.bit]
set init [file join $hw ps7_init.tcl]
set elf  [file join $hw bringup.elf]
set run  1
set i 0
while {$i < [llength $::argv]} {
    set a [lindex $::argv $i]
    switch -- $a {
        --dry-run { set board::dry 1 }
        --no-run  { set run 0 }
        --bit     { set bit  [file normalize [lindex $::argv [incr i]]] }
        --init    { set init [file normalize [lindex $::argv [incr i]]] }
        --elf     { set elf  [file normalize [lindex $::argv [incr i]]] }
        default   { board::fail "unknown argument $a (use --dry-run --bit --init --elf --no-run)" }
    }
    incr i
}
board::need_file $bit  "bitstream"
board::need_file $init "ps7_init script"
board::need_file $elf  "ELF"
puts "load_run: bit  $bit ([file size $bit] bytes)"
puts "load_run: init $init"
puts "load_run: elf  $elf ([file size $elf] bytes)"

if {[catch {
    board::step {connect}
    board::step {targets}
    board::step {targets -set -nocase -filter {name =~ "APU*"}}
    board::step {rst -system}
    board::step {after 3000}
    board::step {targets -set -nocase -filter {name =~ "xc7z020*"}}
    board::step [list fpga -file $bit]
    board::step {targets -set -nocase -filter {name =~ "APU*"}}
    board::step {configparams force-mem-access 1}
    board::step [list source $init]
    board::step {ps7_init}
    board::step {ps7_post_config}
    # PS silicon version
    if {$board::dry} {
        puts "WOULD RUN: mrd -force -value 0xF8007080 (print PS_VERSION)"
    } else {
        set mctrl [lindex [mrd -force -value 0xF8007080] 0]
        puts [format "PS_VERSION %d (MCTRL 0x%08X; 0 = silicon 1.0, 1 = 2.0, 2 = 3.0, 3 = 3.1)" [expr {($mctrl >> 28) & 0xF}] $mctrl]
    }
    board::step {targets -set -nocase -filter {name =~ "*A9*#0"}}
    board::step {rst -processor}
    board::step [list dow $elf]
    board::step {configparams force-mem-access 0}
    if {$run} { board::step {con} } else { puts "load_run: --no-run, core 0 stays halted at the ELF entry" }
    board::step {disconnect}
} msg]} { board::fail $msg }

puts [expr {$board::dry ? "load_run: DRY RUN OK, nothing was done" : "load_run: DONE"}]
exit 0
