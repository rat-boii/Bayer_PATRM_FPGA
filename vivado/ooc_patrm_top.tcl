# Out-of-context synthesis + implementation of the whole grayscale engine (step 3.8).
# Part xc7z020clg484-1, aclk 100 MHz (D8), build parameters BLOCK_LEN_MAX 64, NSLOT 32, RD_OUTSTANDING 8.
#
# Run from build/ooc/patrm_top (keeps Vivado's .jou/.log out of the repo):
#   vivado -mode batch -source ../../../vivado/ooc_patrm_top.tcl
#   vivado -mode batch -source ../../../vivado/ooc_patrm_top.tcl -tclargs variant=bayer_a      (step 5.2)
#   ... -tclargs out=<folder>          reports into another folder (e.g. a re-check that must not replace results/ooc)
# Step 6.3 uses variant=bayer_b (all three modes), or variant=bayer_b_rect for the rectangular-only control.
# variant=gray (default): MODES 1, BUILD_TYPE 0, reports patrm_top_*; variant=bayer_a: MODES 3, BUILD_TYPE 1, reports
# patrm_top_bayer_a_*. The per-module standalone numbers are always read from results/ooc/<module>_summary.txt.
#
# Reports go to results/ooc/, all named patrm_top_*:
#   utilization_synth.rpt, utilization_route.rpt   flat utilization
#   utilization_hier_route.rpt                     hierarchical utilization (all levels)
#   timing_route.rpt                               timing summary
#   worst10_paths_route.rpt                        the 10 worst setup paths, full detail
#   methodology_route.rpt, drc_route.rpt           report_methodology, report_drc
#   power_route.rpt                                report_power, default settings (vectorless ESTIMATE)
#   summary.txt                                    all key numbers and the per-module table
#
# WNS / WHS / TNS cover register-to-register paths only: there are no I/O delays in an OOC run. The "port path" lines
# at the end of the summary are information only (input / output delay 0 ns, added after all reports are written);
# the real port timing is known from the block design of step 4.1.

set script_dir [file dirname [file normalize [info script]]]
set repo       [file dirname $script_dir]
set part       xc7z020clg484-1
set period     10.000
set out        [file join $repo results ooc]
set sa_dir     $out                                        ;# standalone module summaries
set variant    gray
# vivado.bat on Windows splits "variant=bayer_a" at the "=", so the script receives "variant" "bayer_a" (as build.tcl)
foreach {k v} [regsub -all {=} [join $argv " "] " "] {
    if {$k eq "variant" && $v in {gray bayer_a bayer_b bayer_b_rect}} { set variant $v } \
    elseif {$k eq "out" && $v ne ""}                           { set out [file normalize $v] } \
    else { error "unknown argument '$k $v' (use variant=gray|bayer_a|bayer_b|bayer_b_rect, out=<folder>)" }
}
if {$variant in {bayer_b bayer_b_rect}} {
    set modes 7; set build_type 2; set prefix patrm_top_$variant
} elseif {$variant eq "bayer_a"} {
    set modes 3; set build_type 1; set prefix patrm_top_bayer_a
} else {
    set modes 1; set build_type 0; set prefix patrm_top
}
puts "OOC variant $variant: MODES $modes, BUILD_TYPE $build_type, reports $out/${prefix}_*"
file mkdir $out
proc rpt {name} { global out prefix; return [file join $out ${prefix}_$name] }

# instance, module (= name of the standalone results/ooc/<module>_summary.txt; ctrl_fsm has no standalone run)
set instances {
    u_regs axil_regs  u_ctrl ctrl_fsm  u_seq bayer_seq  u_planner block_planner  u_coord coord_gen  u_prefetch prefetch_ctrl
    u_rd axi_rd_master  u_buf line_buf  u_fetch pixel_fetch  u_interp bilinear_interp  u_ofifo out_fifo
    u_wr axi_wr_master
}

set srcs {}
foreach {inst mod} $instances { lappend srcs [file join $repo rtl $mod.v] }
foreach mod {bayer_geometry bayer_store bayer_merge bayer_lanes patrm_top} { lappend srcs [file join $repo rtl $mod.v] }
if {$variant eq "bayer_b_rect"} { set_property verilog_define TB_RECT_ONLY [current_fileset] }
read_verilog $srcs                                         ;# list: the repo path may contain spaces
read_xdc -mode out_of_context [list [file join $script_dir ooc_100mhz.xdc]]
synth_design -top patrm_top -part $part -mode out_of_context -include_dirs [list [file join $repo rtl]] \
    -generic BLOCK_LEN_MAX=64 -generic NSLOT=32 -generic RD_OUTSTANDING=8 -generic MODES=$modes -generic BUILD_TYPE=$build_type

proc n_cells {flt} { return [llength [get_cells -quiet -hier -filter $flt]] }
proc count_latches {} { return [n_cells {REF_NAME =~ LD*}] }

# "| name | used | ... | available | util% |" -> {used available percent}
proc util_row {txt name} {
    foreach line [split $txt "\n"] {
        if {![regexp [string cat {^\|\s*} $name {\s*\|}] $line]} continue
        set c {}
        foreach x [lrange [split $line |] 1 end-1] { lappend c [string trim $x] }
        return [list [lindex $c 1] [lindex $c end-1] [lindex $c end]]
    }
    return {n/a n/a n/a}
}
proc pct_text {row} { lassign $row u a p; return "$u of $a ($p %)" }

# one standalone number from a results/ooc/<module>_summary.txt text
proc sa_field {txt re} { if {[regexp -line $re $txt -> v] && $v ne ""} { return $v } else { return "-" } }

report_utilization -file [rpt utilization_synth.rpt]
set latches_synth [count_latches]

opt_design
place_design
route_design
write_checkpoint -force ${prefix}_route.dcp                ;# in the run folder (build/), for later inspection

# ---------------- reports ----------------
report_utilization -file [rpt utilization_route.rpt]
report_utilization -hierarchical -file [rpt utilization_hier_route.rpt]
report_timing_summary -max_paths 10 -file [rpt timing_route.rpt]
report_timing -delay_type max -max_paths 10 -nworst 1 -input_pins -file [rpt worst10_paths_route.rpt]
set meth [report_methodology -return_string]
set fm [open [rpt methodology_route.rpt] w]; puts $fm $meth; close $fm
set drc  [report_drc -return_string]
set fd [open [rpt drc_route.rpt] w]; puts $fd $drc; close $fd
set pwr  [report_power -return_string]
set fp [open [rpt power_route.rpt] w]; puts $fp $pwr; close $fp

set util [report_utilization -return_string]
set hier [report_utilization -hierarchical -hierarchical_depth 1 -return_string]
set ts   [report_timing_summary -return_string]
lassign {n/a n/a n/a n/a n/a n/a n/a n/a} wns tns tnsf tnst whs ths thsf thst
regexp {WNS\(ns\)[^\n]*\n[\s-]*\n\s*([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)} $ts \
    -> wns tns tnsf tnst whs ths thsf thst

set setup [get_timing_paths -quiet -setup -max_paths 1]
set hold  [get_timing_paths -quiet -hold  -max_paths 1]
set worst [get_timing_paths -quiet -setup -max_paths 10 -nworst 1]

proc path_prop {p name} { if {[catch {set v [get_property $name $p]}]} { return "n/a" } else { return $v } }
proc path_line {p} {
    return "slack [format %.3f [get_property SLACK $p]] ns, data path [format %.3f [get_property DATAPATH_DELAY $p]] ns, [get_property LOGIC_LEVELS $p] levels, [get_property STARTPOINT_PIN $p] -> [get_property ENDPOINT_PIN $p]"
}
proc endpoint_cells {inst} {
    return [get_cells -quiet -hier -filter "NAME =~ $inst/* && (REF_NAME =~ FD* || REF_NAME =~ RAMB* || REF_NAME =~ RAMD* || REF_NAME =~ RAMS* || REF_NAME =~ SRL* || REF_NAME =~ DSP48*)"]
}

# ---------------- hierarchical table: one row per instance ----------------
set hdr {}
array set H {}
foreach line [split $hier "\n"] {
    if {![string match "|*" $line]} continue
    set c {}
    foreach x [lrange [split $line |] 1 end-1] { lappend c [string trim $x] }
    if {[lindex $c 0] eq "Instance"} { set hdr $c; continue }
    if {[llength $hdr] == 0 || [llength $c] != [llength $hdr]} continue
    set row {}
    foreach k $hdr v $c { dict set row $k $v }
    set H([lindex $c 0]) $row
}
proc hget {row key} { if {[dict exists $row $key]} { return [dict get $row $key] } else { return 0 } }

# Vivado 2026.1 leaves some instances out of the hierarchical table (here u_interp, although its cells exist). Such a
# row is rebuilt from the leaf cells of the instance: LUT = LUT + SRL + distributed-RAM cells, before LUT combining.
proc row_from_cells {inst} {
    set n [expr {"NAME =~ $inst/*"}]
    proc nc {base pat} { return [llength [get_cells -quiet -hier -filter "$base && REF_NAME =~ $pat"]] }
    set lut [nc $n LUT*]
    set srl [nc $n SRL*]
    set ram [expr {[nc $n RAMD*] + [nc $n RAMS*]}]
    return [dict create {Total LUTs} [expr {$lut + $srl + $ram}] LUTRAMs $ram SRLs $srl \
                FFs [nc $n FD*] RAMB36 [nc $n RAMB36*] RAMB18 [nc $n RAMB18*] {DSP Blocks} [nc $n DSP48*]]
}

# ---------------- summary ----------------
set f [open [rpt summary.txt] w]
puts $f "module        patrm_top (OOC, $part, aclk $period ns = 100 MHz, post-route; BLOCK_LEN_MAX 64, NSLOT 32, RD_OUTSTANDING 8)"
puts $f "vivado        [version -short]"
puts $f "scope         register-to-register timing; no I/O delays; no AXI interconnect, PS or reset IP (block design: step 4.1)"
puts $f ""
puts $f "LUT           [pct_text [util_row $util {Slice LUTs}]]"
puts $f "  logic       [pct_text [util_row $util {LUT as Logic}]]"
puts $f "  memory      [pct_text [util_row $util {LUT as Memory}]] = [lindex [util_row $util {LUT as Distributed RAM}] 0] LUTRAM + [lindex [util_row $util {LUT as Shift Register}] 0] SRL"
puts $f "FF            [pct_text [util_row $util {Slice Registers}]]"
puts $f "BRAM          [pct_text [util_row $util {Block RAM Tile}]] ([n_cells {REF_NAME =~ RAMB36*}] RAMB36 + [n_cells {REF_NAME =~ RAMB18*}] RAMB18 cells)"
puts $f "DSP48E1       [pct_text [util_row $util {DSPs}]]"
puts $f "Slices        [pct_text [util_row $util {Slice}]]"
puts $f "latches       synth $latches_synth, route [count_latches]"
puts $f ""
puts $f "WNS (ns)      $wns"
puts $f "TNS (ns)      $tns ($tnsf failing of $tnst endpoints)"
puts $f "WHS (ns)      $whs"
puts $f "THS (ns)      $ths ($thsf failing of $thst endpoints)"
if {[string is double -strict $wns] && $wns < $period} {
    puts $f "Fmax (MHz)    [format %.1f [expr {1000.0 / ($period - $wns)}]] ESTIMATE = 1000 / (10 ns - WNS); implementation was driven by a 100 MHz constraint, this is not a run at that clock"
}
if {[llength $setup]} {
    puts $f "critical path [get_property STARTPOINT_PIN $setup] -> [get_property ENDPOINT_PIN $setup]"
    puts $f "              data path [format %.3f [get_property DATAPATH_DELAY $setup]] ns = logic [path_prop $setup DATAPATH_LOGIC_DELAY] + net [path_prop $setup DATAPATH_NET_DELAY] ns, [get_property LOGIC_LEVELS $setup] logic levels, skew [path_prop $setup SKEW] ns"
}
if {[llength $hold]} { puts $f "worst hold    [path_line $hold]" }
puts $f ""
puts $f "10 worst setup paths (one per endpoint):"
foreach p $worst { puts $f "  [path_line $p]" }
puts $f ""

puts $f "per module: whole engine (post-route) vs standalone OOC run of steps 3.1-3.6c (sa*)"
puts $f "LUTmem = LUTRAM + SRL. slack = worst setup path ending in that module, whole engine; saWNS = standalone WNS."
puts $f "* = no row in Vivado's hierarchical report, counted from the instance's leaf cells (before LUT combining)."
puts $f [format "%-12s %-16s | %5s %6s %5s %4s %4s | %5s %6s %5s %4s %4s | %8s %8s" instance module LUT LUTmem FF BRAM DSP saLUT saMem saFF saBR saDSP "slack" saWNS]
set sum_lut 0; set sum_ff 0; set sum_dsp 0; set sum_sa_lut 0; set sum_sa_ff 0
if {$build_type == 2} { lappend instances option_b.engine bayer_lanes }
foreach {inst mod} $instances {
    if {[info exists H($inst)]} { set r $H($inst); set tag $inst } else { set r [row_from_cells $inst]; set tag "$inst*" }
    set lut  [hget $r {Total LUTs}]
    set mem  [expr {[hget $r LUTRAMs] + [hget $r SRLs]}]
    set ffs  [hget $r FFs]
    set br   [expr {[hget $r RAMB36] + [hget $r RAMB18] / 2.0}]
    set dsp  [expr {[hget $r {DSP Blocks}] + [hget $r {DSP48 Blocks}]}]
    incr sum_lut $lut; incr sum_ff $ffs; incr sum_dsp $dsp
    lassign {- - - - - -} slut smem sff sbr sdsp swns
    set sf [file join $sa_dir ${mod}_summary.txt]
    if {[file exists $sf]} {
        set h [open $sf r]; set t [read $h]; close $h
        set slut [sa_field $t {^LUT\s+(\d+)}]
        set smem [sa_field $t {^LUT\s+.*\+ (\d+) memory}]
        if {$smem eq "-"} { set smem [sa_field $t {^LUTRAM\s+(\d+)}] }
        set sff  [sa_field $t {^FF\s+(\d+)}]
        set sbr  [sa_field $t {^BRAM\s+(\d+) RAMB36}]
        if {$sbr eq "-"} { set sbr [sa_field $t {^BRAM \(RAMB\*\)\s+(\d+)}] }
        set sdsp [sa_field $t {^DSP48E1\s+(\d+)}]
        set swns [sa_field $t {^WNS \(ns\)[ \t]+([-\d.]+)}]
        if {$slut ne "-"} { incr sum_sa_lut $slut }
        if {$sff ne "-"}  { incr sum_sa_ff $sff }
    }
    set slack "-"
    set ec [endpoint_cells $inst]
    if {[llength $ec]} {
        set p [get_timing_paths -quiet -setup -max_paths 1 -to $ec]
        if {[llength $p]} { set slack [format %.3f [get_property SLACK $p]] }
    }
    puts $f [format "%-12s %-16s | %5s %6s %5s %4s %4s | %5s %6s %5s %4s %4s | %8s %8s" $tag $mod $lut $mem $ffs $br $dsp $slut $smem $sff $sbr $sdsp $slack $swns]
}
puts $f "sum of the rows: LUT $sum_lut, FF $sum_ff, DSP $sum_dsp. Sum of the standalone runs (no ctrl_fsm run exists): LUT $sum_sa_lut, FF $sum_sa_ff."
puts $f "The LUT sum can exceed the total: Vivado counts a LUT shared by two instances (LUT combining) in both rows."
puts $f "Rows differ from the standalone runs because synthesis optimises across module boundaries (flatten_hierarchy rebuilt)"
puts $f "and names moved logic after either side, and because constant or unused module ports are removed."
puts $f ""

puts $f "power         ESTIMATE: report_power, default settings, vectorless (no switching activity from simulation); engine only, PS not included"
foreach key {{Total On-Chip Power \(W\)} {Dynamic \(W\)} {Device Static \(W\)} {Confidence Level}} {
    if {[regexp [string cat {\|\s*(} $key {)\s*\|\s*([^|]*?)\s*\|}] $pwr -> k v]} { puts $f "  [format %-26s $k] $v" }
}
foreach key {Clocks {Slice Logic} Signals {Block RAM} DSPs} {
    if {[regexp -line [string cat {^\|\s*} $key {\s*\|\s*([\d.<]+)\s*\|}] $pwr -> v]} { puts $f "  [format %-26s "$key (W)"] $v" }
}
puts $f ""

puts $f "methodology (report_methodology): rule, severity, count"
set nmeth 0
foreach line [split $meth "\n"] {
    if {[regexp {^\|\s*([A-Z0-9]+-\d+)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*(\d+)\s*\|} $line -> id sev desc cnt]} {
        puts $f "  $id  $sev  x$cnt  $desc"; incr nmeth
    }
}
if {$nmeth == 0} { puts $f "  no violations" }
puts $f "DRC (report_drc): rule, severity, count"
set ndrc 0
set mdrv 0
foreach line [split $drc "\n"] {
    if {[regexp {^\|\s*([A-Z0-9]+-\d+)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*(\d+)\s*\|} $line -> id sev desc cnt]} {
        puts $f "  $id  $sev  x$cnt  $desc"; incr ndrc
        if {$id eq "MDRV-1"} { set mdrv $cnt }
    }
}
if {$ndrc == 0} { puts $f "  no violations" }
puts $f "multi-driven  $mdrv (DRC MDRV-1)"
puts $f ""

# ---------------- information only: how much of the 10 ns the ports need ----------------
set ins {}
foreach p [all_inputs] { if {[get_property NAME $p] ne "aclk"} { lappend ins $p } }
set_input_delay  -clock aclk 0 $ins
set_output_delay -clock aclk 0 [all_outputs]
puts $f "port paths (information only, input / output delay 0 ns; real values come with the block design, step 4.1)"
foreach pat {s_axi_* m_axi_hp0_* m_axi_hp1_* aresetn} {
    set pi [get_timing_paths -quiet -setup -max_paths 1 -from [get_ports -quiet -filter {DIRECTION == IN} $pat]]
    if {[llength $pi]} {
        puts $f "  in   $pat: needs [format %.3f [expr {$period - [get_property SLACK $pi]}]] ns, [get_property LOGIC_LEVELS $pi] levels, [get_property STARTPOINT_PIN $pi] -> [get_property ENDPOINT_PIN $pi]"
    }
    set po [get_timing_paths -quiet -setup -max_paths 1 -to [get_ports -quiet -filter {DIRECTION == OUT} $pat]]
    if {[llength $po]} {
        puts $f "  out  $pat: needs [format %.3f [expr {$period - [get_property SLACK $po]}]] ns, [get_property LOGIC_LEVELS $po] levels, [get_property STARTPOINT_PIN $po] -> [get_property ENDPOINT_PIN $po]"
    }
}
close $f

puts "OOC SUMMARY patrm_top LUT=[lindex [util_row $util {Slice LUTs}] 0] FF=[lindex [util_row $util {Slice Registers}] 0] LATCHES=$latches_synth/[count_latches] WNS=$wns TNS=$tns WHS=$whs MDRV=$mdrv"

# Step 6.3 sign-off follows report generation so a failed route keeps its evidence.
if {$build_type == 2} {
    foreach value [list $wns $whs] {
        if {![string is double -strict $value]} { error "STEP 6.3 FAIL: missing numeric timing slack" }
    }
    if {$wns < 0 || $whs < 0 || $latches_synth || [count_latches] || $mdrv} {
        error "STEP 6.3 FAIL: WNS=$wns WHS=$whs latches=$latches_synth/[count_latches] MDRV=$mdrv"
    }
    puts "STEP 6.3 PASS: setup and hold met at 100 MHz"
}
