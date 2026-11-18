# Read DDR into a raw file over USB-JTAG (steps 0.3 and 4.1).
#
#   xsdb scripts/board/get_image.tcl [--dry-run] <address> <bytes> <file>
#
# The PS and DDR must already be initialised (run load_run.tcl first). Core 0 is halted during the transfer and resumed
# if it was running. Prints the time per MB. --dry-run checks the arguments and prints every step.

source [file join [file dirname [file normalize [info script]]] common.tcl]

set pos {}
foreach a $::argv {
    if {$a eq "--dry-run"} { set board::dry 1 } else { lappend pos $a }
}
if {[llength $pos] != 3} { board::fail "usage: get_image.tcl \[--dry-run\] <address> <bytes> <file>" }
set addr [board::address [lindex $pos 0]]
set size [board::address [lindex $pos 1]]
set file [file normalize [lindex $pos 2]]
board::check_range $addr $size
if {![file isdirectory [file dirname $file]]} { board::fail "output folder does not exist: [file dirname $file]" }
puts [format "get_image: DDR 0x%08X (%d bytes) -> %s" $addr $size $file]

# whole words when possible (faster), single bytes otherwise
if {($addr % 4) == 0 && ($size % 4) == 0} {
    set cmd [list mrd -force -bin -file $file [format 0x%08X $addr] [expr {$size / 4}]]
} else {
    set cmd [list mrd -force -size b -bin -file $file [format 0x%08X $addr] $size]
}

if {[catch {
    set was_running [board::attach_core]
    set t0 [clock milliseconds]
    board::step $cmd
    set dt [expr {([clock milliseconds] - $t0) / 1000.0}]
    board::detach_core $was_running
} msg]} { board::fail $msg }

if {$board::dry} {
    puts "get_image: DRY RUN OK, nothing was done"
} else {
    if {[file size $file] != $size} { board::fail "file has [file size $file] bytes, expected $size" }
    puts "get_image: DONE, $size bytes in $dt s, [board::mb_per_s $size $dt]"
}
exit 0
