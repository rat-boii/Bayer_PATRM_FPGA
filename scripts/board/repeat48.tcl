# Repeat a 48-word JTAG DDR test on an already initialized ZedBoard.
# No system reset, FPGA programming, or DDR initialization is performed.
# Usage: xsdb repeat48.tcl [rounds]   (default: 10)
source [file join [file dirname [file normalize [info script]]] common.tcl]

set rounds 10
if {[llength $argv] > 1} { board::fail "usage: repeat48.tcl \[rounds\]" }
if {[llength $argv] == 1} { set rounds [lindex $argv 0] }
if {![string is integer -strict $rounds] || $rounds < 1 || $rounds > 10000} {
    board::fail "rounds must be an integer from 1 to 10000"
}

set address 0x10000000
set count 48
set seed [expr {[clock microseconds] & 0xFFFFFFFF}]
set attached 0
set was_running 0
set passed 0
puts "DDR repeat test: $rounds rounds, 48 x 32-bit words (192 bytes) at 0x10000000"
puts "The board must already be initialized. No reset or reprogramming."
puts "ARM core 0 is temporarily halted for memory access and resumed afterward if it was running."

proc match_words {expected actual} {
    if {[llength $actual] != [llength $expected]} {
        error "expected [llength $expected] words, received [llength $actual]"
    }
    set matched 0
    foreach e $expected a $actual {
        if {([expr {wide($e) & 0xFFFFFFFF}]) == ([expr {wide($a) & 0xFFFFFFFF}])} {
            incr matched
        }
    }
    return $matched
}

set failed [catch {
    set was_running [board::attach_core]
    set attached 1
    for {set round 1} {$round <= $rounds} {incr round} {
        set expected {}
        for {set i 0} {$i < $count} {incr i} {
            set seed [expr {(1664525 * $seed + 1013904223) & 0xFFFFFFFF}]
            lappend expected [format 0x%08X $seed]
        }
        # One list of 48 words; default mwr count is the length of that list.
        mwr -size w $address $expected
        set actual [mrd -force -size w -value $address $count]
        set matched [match_words $expected $actual]
        puts [format "Round %d: %d / 48 words matched" $round $matched]
        if {$matched != $count} {
            for {set i 0} {$i < $count} {incr i} {
                set e [expr {wide([lindex $expected $i]) & 0xFFFFFFFF}]
                set a [expr {wide([lindex $actual $i]) & 0xFFFFFFFF}]
                if {$e != $a} {
                    puts [format "  Word %d @ 0x%08X: expected 0x%08X, read 0x%08X" $i [expr {$address + 4*$i}] $e $a]
                }
            }
            error "comparison failed in round $round"
        }
        incr passed
    }
} reason]

if {$attached} {
    if {[catch {board::detach_core $was_running} cleanup]} {
        puts "BOARD ERROR: cleanup failed: $cleanup"
        exit 1
    }
} else {
    catch {disconnect}
}
if {$failed} {
    puts "DDR TEST FAIL: $reason ($passed / $rounds rounds passed)"
    exit 1
}
puts "DDR TEST PASS: $passed / $rounds rounds passed; no reset between rounds"
exit 0
