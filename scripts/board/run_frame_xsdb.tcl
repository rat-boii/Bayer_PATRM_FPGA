# Run one grayscale frame on the board over USB-JTAG, with no ARM program (step 4.2a). Started by run_frame.py.
#
#   xsdb scripts/board/run_frame_xsdb.tcl [--dry-run] [--no-program] <job.tcl>
#
# <job.tcl> is written by run_frame.py: files, addresses, register values and STATUS bit masks, all from the model.
# Sequence: program the bitstream, ps7_init + ps7_post_config, core 0 reset and halted (MMU and caches off), check
# BUILD_ID, load the source, fill the output area, write the registers, START, poll STATUS, read the counters, dump the
# output, clear DONE. --no-program keeps the loaded bitstream and PS setup (for example with an ILA already armed).
# --dry-run prints every XSDB command and touches no board.
#
# Output read by run_frame.py: "VALUE <name> 0x<hex>" lines, then "run_frame: DONE". xsdb can exit with code 0 after a
# failure, so only that last line counts as success. A failure prints "BOARD ERROR: ...".

source [file join [file dirname [file normalize [info script]]] common.tcl]

set no_program 0
set pos {}
foreach a $::argv {
    switch -- $a {
        --dry-run    { set board::dry 1 }
        --no-program { set no_program 1 }
        default      { lappend pos $a }
    }
}
if {[llength $pos] != 1} { board::fail "usage: run_frame_xsdb.tcl \[--dry-run\] \[--no-program\] <job.tcl>" }
set jobfile [file normalize [lindex $pos 0]]
board::need_file $jobfile "job file"
source $jobfile
board::need_file $job(src_file) "source image"
if {!$no_program} {
    board::need_file $job(bit) "bitstream"
    board::need_file $job(init) "ps7_init script"
}

namespace eval frame {}

proc frame::rd {addr {note ""}} {
    if {$board::dry} {
        puts "WOULD RUN: mrd -force -value $addr[expr {$note eq "" ? "" : " ;# $note"}]"
        return 0
    }
    return [expr {[lindex [mrd -force -value $addr] 0] & 0xFFFFFFFF}]
}

proc frame::wr {addr value note} {
    board::step "[list mwr -force $addr $value] ;# $note"
}

proc frame::show {name value} { puts [format "VALUE %s 0x%08X" $name $value] }

proc frame::expect_word {what addr want} {
    set got [frame::rd $addr "must be $want: $what"]
    if {!$board::dry && $got != $want} {
        board::fail [format "%s: read 0x%08X at %s, expected 0x%08X" $what $got $addr $want]
    }
    return $got
}

proc frame::counters {} {
    foreach {name addr} $::job(counters) { frame::show $name [frame::rd $addr $name] }
}

# STATUS until DONE. Stops on a rejected start, on an idle engine and on the timeout, with STATUS and the counters.
proc frame::wait_done {} {
    set addr $::job(reg_status)
    if {$board::dry} {
        puts "WOULD RUN: mrd -force -value $addr ;# STATUS, repeated until DONE = 1, timeout $::job(timeout_s) s"
        return $::job(done_mask)
    }
    set deadline [expr {[clock milliseconds] + 1000 * $::job(timeout_s)}]
    set polls 0
    while {1} {
        set s [frame::rd $addr]
        incr polls
        if {$s & $::job(done_mask)} { puts "run_frame: DONE bit seen after $polls STATUS reads"; return $s }
        set problem ""
        if {$s & $::job(error_mask)} {
            set problem "the engine rejected the job"
        } elseif {!($s & $::job(busy_mask))} {
            set problem "the engine is idle: START was not accepted"
        } elseif {[clock milliseconds] > $deadline} {
            set problem "timeout after $::job(timeout_s) s, DONE not set"
        }
        if {$problem ne ""} {
            frame::show STATUS_AT_FAILURE $s
            frame::counters
            board::fail [format "%s (STATUS 0x%08X)" $problem $s]
        }
    }
}

puts "run_frame: job $jobfile"
puts "run_frame: $job(w) x $job(h), source $job(src_file), output $job(out_file)"

if {[catch {
    board::step {connect}
    board::step {targets}
    if {!$no_program} {
        board::step {targets -set -nocase -filter {name =~ "APU*"}}
        board::step {rst -system}
        board::step {after 3000}
        board::step {targets -set -nocase -filter {name =~ "xc7z020*"}}
        board::step [list fpga -file $job(bit)]
        board::step {targets -set -nocase -filter {name =~ "APU*"}}
        board::step {configparams force-mem-access 1}
        board::step [list source $job(init)]
        board::step {ps7_init}
        board::step {ps7_post_config}
    }
    # core 0 halted straight out of reset: MMU and caches are off, so every access below goes to DDR or the PL
    board::step {targets -set -nocase -filter {name =~ "*A9*#0"}}
    board::step {configparams force-mem-access 1}
    board::step {rst -processor}
    if {$board::dry} {
        puts "WOULD RUN: stop (only if core 0 is running)"
    } elseif {[string match -nocase *running* [state]]} {
        board::step {stop}
    }

    set id [frame::expect_word BUILD_ID $job(reg_build_id) $job(build_id)]
    frame::show BUILD_ID [expr {$board::dry ? $job(build_id) : $id}]
    set s [frame::rd $job(reg_status) "STATUS before the job"]
    frame::show STATUS_BEFORE $s
    if {$s & $job(busy_mask)} { board::fail [format "engine is busy before the job (STATUS 0x%08X)" $s] }

    board::step [list dow -data $job(src_file) $job(src_addr)]
    frame::expect_word "first source word in DDR" $job(src_addr) $job(src_first)
    frame::expect_word "last source word in DDR" $job(src_last_addr) $job(src_last)

    # output area and guard bytes: anything the engine does not write keeps this pattern
    board::step "[list mwr -force $job(dst_addr) $job(fill_word) $job(out_words)] ;# fill the output area"
    frame::expect_word "first word of the filled output area" $job(dst_addr) $job(fill_word)
    frame::expect_word "last word of the filled output area" $job(out_last_addr) $job(fill_word)

    frame::wr $job(reg_status) $job(clear_mask) "STATUS: clear DONE and ERROR (W1C)"
    foreach r $job(regs) {
        lassign $r addr value name
        frame::wr $addr $value $name
    }
    frame::wr $job(reg_ctrl) $job(start_value) "CTRL: START, IRQ_EN = 0"

    set s [frame::wait_done]
    frame::show STATUS_AT_DONE [expr {$board::dry ? $job(done_mask) : $s}]
    frame::counters

    board::step [list mrd -force -bin -file $job(out_file) $job(dst_addr) $job(out_words)]
    if {!$board::dry && [file size $job(out_file)] != 4 * $job(out_words)} {
        board::fail "output file has [file size $job(out_file)] bytes, expected [expr {4 * $job(out_words)}]"
    }

    set clear [expr {$s & $job(clear_mask)}]
    if {$board::dry} { set clear $job(done_mask) }
    frame::wr $job(reg_status) [format 0x%08X $clear] "STATUS: clear what was set (W1C)"
    frame::show STATUS_AFTER_CLEAR [frame::rd $job(reg_status) "STATUS after the W1C"]

    board::step {configparams force-mem-access 0}
    board::step {disconnect}
} msg]} { board::fail $msg }

puts [expr {$board::dry ? "run_frame: DRY RUN OK, nothing was done" : "run_frame: DONE"}]
exit 0
