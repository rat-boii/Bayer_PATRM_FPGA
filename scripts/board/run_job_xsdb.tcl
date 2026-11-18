# Give one job to the ARM test application over USB-JTAG and collect the result (step 4.2). Started by run_job.py.
#
#   xsdb scripts/board/run_job_xsdb.tcl [--dry-run] [--load] <job.tcl>
#
# <job.tcl> is written by run_job.py: files, addresses and the descriptor words, all from the model.
# --load: program the bitstream, ps7_init + ps7_post_config, clear both record areas, load and start the ELF.
# Without --load the application must already be running; it is left running in both cases, so later jobs do not reload
# anything.
#
# All DDR access goes through the APU (DAP) target with -force, while the ARM keeps running. This path does not go through
# the ARM caches, which is why the application invalidates the descriptor and flushes the result record.
# Protocol (spec/memory_map.md section 5): descriptor magic = 0, body, seq, then magic last; the result is complete when
# its seq equals the job's seq, because the application writes that word last.
#
# Output read by run_job.py: "VALUE <name> 0x<hex>" lines, then "run_job: DONE". xsdb can exit with code 0 after a
# failure, so only that last line counts as success. A failure prints "BOARD ERROR: ...".

source [file join [file dirname [file normalize [info script]]] common.tcl]

set load 0
set pos {}
foreach a $::argv {
    switch -- $a {
        --dry-run { set board::dry 1 }
        --load    { set load 1 }
        default   { lappend pos $a }
    }
}
if {[llength $pos] != 1} { board::fail "usage: run_job_xsdb.tcl \[--dry-run\] \[--load\] <job.tcl>" }
set jobfile [file normalize [lindex $pos 0]]
board::need_file $jobfile "job file"
source $jobfile
board::need_file $job(src_file) "source image"
if {$load} {
    board::need_file $job(bit) "bitstream"
    board::need_file $job(init) "ps7_init script"
    board::need_file $job(elf) "application ELF (build it: vitis -s sw/patrm_app/build_vitis.py)"
}

namespace eval runjob {}

proc runjob::rd {addr {note ""}} {
    if {$board::dry} {
        puts "WOULD RUN: mrd -force -value $addr[expr {$note eq "" ? "" : " ;# $note"}]"
        return 0
    }
    return [expr {[lindex [mrd -force -value $addr] 0] & 0xFFFFFFFF}]
}

proc runjob::rd_n {addr n note} {
    if {$board::dry} {
        puts "WOULD RUN: mrd -force -value $addr $n ;# $note"
        return [lrepeat $n 0]
    }
    set out {}
    foreach v [mrd -force -value $addr $n] { lappend out [expr {$v & 0xFFFFFFFF}] }
    return $out
}

proc runjob::wr {addr value note} {
    board::step "[list mwr -force $addr $value] ;# $note"
}

proc runjob::hex {value} { return [format 0x%08X $value] }

proc runjob::offset {addr bytes} { return [runjob::hex [expr {$addr + $bytes}]] }

proc runjob::show {name value} { puts [format "VALUE %s 0x%08X" $name $value] }

proc runjob::expect_word {what addr want} {
    set got [runjob::rd $addr "must be $want: $what"]
    if {!$board::dry && $got != $want} {
        board::fail [format "%s: read 0x%08X at %s, expected 0x%08X" $what $got $addr $want]
    }
}

proc runjob::load_system {} {
    global job
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
    # DDR keeps its content over a reset: nothing from an earlier session may look like a new record
    board::step "[list mwr -force $job(job_addr) 0 $job(job_words)] ;# clear the job descriptor"
    board::step "[list mwr -force $job(result_addr) 0 $job(result_words)] ;# clear the result record"
    board::step {targets -set -nocase -filter {name =~ "*A9*#0"}}
    board::step {rst -processor}
    board::step [list dow $job(elf)]
    board::step {configparams force-mem-access 0}
    board::step {con}
}

proc runjob::wait_ready {} {
    global job
    if {$board::dry} {
        puts "WOULD RUN: mrd -force -value $job(result_addr) ;# repeated until the result magic is $job(result_magic), timeout $job(app_wait_s) s"
        return
    }
    set deadline [expr {[clock milliseconds] + 1000 * $job(app_wait_s)}]
    while {[runjob::rd $job(result_addr)] != $job(result_magic)} {
        if {[clock milliseconds] > $deadline} {
            board::fail "no result record after $job(app_wait_s) s: the application is not running (use --load, and look at the UART)"
        }
        after 100
    }
}

proc runjob::wait_result {seq} {
    global job
    set addr [runjob::offset $job(result_addr) 4]
    if {$board::dry} {
        puts "WOULD RUN: mrd -force -value $addr ;# result seq, repeated until it equals the job's seq, timeout $job(timeout_s) s"
        return
    }
    set deadline [expr {[clock milliseconds] + 1000 * $job(timeout_s)}]
    set polls 0
    while {1} {
        set got [runjob::rd $addr]
        incr polls
        if {$got == $seq} { puts "run_job: result seen after $polls reads"; return }
        if {[clock milliseconds] > $deadline} {
            runjob::show RESULT_SEQ $got
            board::fail [format "no result for job %d after %d s (result seq is %d): look at the UART" $seq $job(timeout_s) $got]
        }
        after 50
    }
}

puts "run_job: job $jobfile"
puts "run_job: $job(w) x $job(h), N = $job(repeat), source $job(src_file), output $job(out_file)"

if {[catch {
    board::step {connect}
    board::step {targets}
    if {$load} { runjob::load_system }
    board::step {targets -set -nocase -filter {name =~ "APU*"}}

    runjob::wait_ready
    lassign [runjob::rd_n $job(result_addr) 4 "result record: magic, seq, layout, rc"] magic prev_seq layout rc
    lassign [runjob::rd_n $job(job_addr) 2 "job descriptor: magic, seq"] job_magic job_seq
    if {!$board::dry} {
        if {$layout != $job(layout)} { board::fail "the application uses record layout $layout, this script $job(layout): rebuild the ELF" }
        if {$prev_seq == 0 && $rc != 0} { board::fail "the application failed to start, result code $rc: look at the UART" }
        if {$job_magic == $job(job_magic) && $job_seq != $prev_seq} {
            board::fail "the application is still working on job $job_seq (last result is for job $prev_seq)"
        }
    }
    set seq [expr {($prev_seq + 1) & 0xFFFFFFFF}]
    if {$seq == 0} { set seq 1 }
    runjob::show SEQ $seq

    board::step "[list mwr -force -bin -file $job(src_file) $job(src_addr) $job(src_words)] ;# source image"
    runjob::expect_word "first source word in DDR" $job(src_addr) $job(src_first)
    runjob::expect_word "last source word in DDR" $job(src_last_addr) $job(src_last)

    # output area and guard bytes: anything the engine does not write keeps this pattern
    board::step "[list mwr -force $job(dst_addr) $job(fill_word) $job(out_words)] ;# fill the output area"
    runjob::expect_word "first word of the filled output area" $job(dst_addr) $job(fill_word)
    runjob::expect_word "last word of the filled output area" $job(out_last_addr) $job(fill_word)

    # the descriptor: magic = 0 first, so the application cannot see a half-written one; magic again last
    set body [lrange $job(desc_words) 2 end]
    set body_addr [runjob::offset $job(job_addr) 8]
    set seq_addr [runjob::offset $job(job_addr) 4]
    runjob::wr $job(job_addr) 0 "descriptor magic = 0"
    board::step "[list mwr -force $body_addr $body] ;# descriptor body"
    runjob::wr $seq_addr [runjob::hex $seq] "descriptor seq"
    set back [runjob::rd_n $body_addr [llength $body] "descriptor body, read back"]
    if {!$board::dry} {
        foreach g $back w $body {
            if {$g != $w} { board::fail [format "descriptor read back 0x%08X, wrote 0x%08X" $g $w] }
        }
    }
    runjob::wr $job(job_addr) $job(job_magic) "descriptor magic: the job starts now"

    runjob::wait_result $seq
    board::step [list mrd -force -bin -file $job(result_file) $job(result_addr) $job(result_words)]
    board::step [list mrd -force -bin -file $job(out_file) $job(dst_addr) $job(out_words)]
    if {!$board::dry} {
        foreach {path words} [list $job(result_file) $job(result_words) $job(out_file) $job(out_words)] {
            if {[file size $path] != 4 * $words} {
                board::fail "$path has [file size $path] bytes, expected [expr {4 * $words}]"
            }
        }
    }
    board::step {disconnect}
} msg]} { board::fail $msg }

puts [expr {$board::dry ? "run_job: DRY RUN OK, nothing was done" : "run_job: DONE"}]
exit 0
