# Write a raw file into DDR over USB-JTAG (steps 0.3 and 4.1).
#
#   xsdb scripts/board/put_image.tcl [--dry-run] <file> <address>
#
# The PS and DDR must already be initialised (run load_run.tcl first). Core 0 is halted during the transfer and resumed
# if it was running. Prints the time per MB. --dry-run checks the arguments and prints every step.

source [file join [file dirname [file normalize [info script]]] common.tcl]

set pos {}
foreach a $::argv {
    if {$a eq "--dry-run"} { set board::dry 1 } else { lappend pos $a }
}
if {[llength $pos] != 2} { board::fail "usage: put_image.tcl \[--dry-run\] <file> <address>" }
set file [file normalize [lindex $pos 0]]
board::need_file $file "input file"
set addr [board::address [lindex $pos 1]]
set size [file size $file]
board::check_range $addr $size
puts [format "put_image: %s (%d bytes) -> DDR 0x%08X" $file $size $addr]

if {[catch {
    set was_running [board::attach_core]
    set t0 [clock milliseconds]
    board::step [list dow -data $file [format 0x%08X $addr]]
    set dt [expr {([clock milliseconds] - $t0) / 1000.0}]
    board::detach_core $was_running
} msg]} { board::fail $msg }

if {$board::dry} {
    puts "put_image: DRY RUN OK, nothing was done"
} else {
    puts "put_image: DONE, $size bytes in $dt s, [board::mb_per_s $size $dt]"
}
exit 0
