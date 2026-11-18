# Shared helpers of the XSDB board scripts (load_run.tcl, put_image.tcl, get_image.tcl). Sourced, not run directly.

namespace eval board {
    variable dry 0
    variable repo [file dirname [file dirname [file dirname [file normalize [info script]]]]]
    # DDR usable for images: above the first 1 MB, below the end of the 512 MB (spec/memory_map.md section 1)
    variable ddr_low  0x00100000
    variable ddr_end  0x20000000
}

# say what happens; in a dry run nothing else happens
proc board::step {cmd} {
    variable dry
    if {$dry} { puts "WOULD RUN: $cmd"; return "" }
    puts "RUN: $cmd"
    return [uplevel #0 $cmd]
}

proc board::fail {msg} { puts "BOARD ERROR: $msg"; exit 1 }

proc board::need_file {path what} {
    if {![file isfile $path]} { board::fail "$what not found: $path" }
}

proc board::address {text} {
    if {![string is wideinteger -strict $text]} { board::fail "not an address: $text" }
    return [expr {wide($text)}]
}

# the whole range must lie in DDR
proc board::check_range {addr size} {
    variable ddr_low; variable ddr_end
    if {$size <= 0} { board::fail "size must be positive: $size" }
    if {$addr < $ddr_low || $addr + $size > $ddr_end} {
        board::fail [format "range 0x%08X + %d bytes is outside DDR 0x%08X - 0x%08X" $addr $size $ddr_low [expr {$ddr_end - 1}]]
    }
}

# debugger on, core 0 selected and halted; returns 1 if the core was running
proc board::attach_core {} {
    variable dry
    board::step {connect}
    board::step {targets -set -nocase -filter {name =~ "*A9*#0"}}
    board::step {configparams force-mem-access 1}
    if {$dry} { puts "WOULD RUN: stop (only if core 0 is running)"; return 0 }
    set running [string match -nocase *running* [state]]
    if {$running} { board::step {stop} }
    return $running
}

proc board::detach_core {was_running} {
    variable dry
    board::step {configparams force-mem-access 0}
    if {$dry} { puts "WOULD RUN: con (only if core 0 was running before)" } elseif {$was_running} { board::step {con} }
    board::step {disconnect}
}

proc board::mb_per_s {bytes seconds} {
    if {$seconds <= 0.0} { return "n/a" }
    return [format "%.3f s/MB" [expr {$seconds / ($bytes / 1048576.0)}]]
}
