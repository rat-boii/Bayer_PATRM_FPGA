# Out-of-context synthesis + implementation of rtl/block_planner.v (step 3.6a), part xc7z020clg484-1, 100 MHz.
#
# Run from build/ooc/block_planner (keeps Vivado's .jou/.log out of the repo):
#   vivado -mode batch -source ../../../vivado/ooc_block_planner.tcl
# Reports go to results/ooc/: block_planner_utilization_{synth,route}.rpt, block_planner_timing_route.rpt and
# block_planner_summary.txt (LUT / FF / BRAM / DSP / latches / WNS / WHS, the critical path, the worst path into
# each pipeline stage). Build parameters as patrm_top (spec section 0): SPAN_MAX 512, DESC_DEPTH 16,
# FETCH_DEPTH 16 (the module defaults). Timing covers register-to-register paths only (no I/O delays on module
# ports in an OOC run).

set script_dir [file dirname [file normalize [info script]]]
set repo       [file dirname $script_dir]
set top        block_planner
set part       xc7z020clg484-1
set out        [file join $repo results ooc]
file mkdir $out

read_verilog [list [file join $repo rtl $top.v]]          ;# list: the repo path may contain spaces
read_xdc -mode out_of_context [list [file join $script_dir ooc_100mhz.xdc]]
synth_design -top $top -part $part -mode out_of_context
report_utilization -file [file join $out ${top}_utilization_synth.rpt]

# latch check: inferred latches are LDCE / LDPE primitives
proc count_latches {} { return [llength [get_cells -quiet -hier -filter {REF_NAME =~ LD*}]] }
set latches_synth [count_latches]

opt_design
place_design
route_design
report_utilization   -file [file join $out ${top}_utilization_route.rpt]
report_timing_summary -max_paths 10 -file [file join $out ${top}_timing_route.rpt]

proc n_cells {flt} { return [llength [get_cells -quiet -hier -filter $flt]] }
proc util_row {txt name} {
    set re [string cat {\|\s*} $name {\s*\|\s*(\d+)}]
    if {[regexp $re $txt -> v]} { return $v } else { return "n/a" }
}
set util  [report_utilization -return_string]
set lut   [util_row $util {Slice LUTs}]
set ff    [util_row $util {Slice Registers}]
set lutlogic [util_row $util {LUT as Logic}]
set lutmem   [util_row $util {LUT as Memory}]
set lutcells [n_cells {PRIMITIVE_GROUP == LUT}]
set bram  [n_cells {REF_NAME =~ RAMB*}]
set dsp   [n_cells {REF_NAME =~ DSP48*}]
set setup [get_timing_paths -quiet -setup -max_paths 1]
set hold  [get_timing_paths -quiet -hold  -max_paths 1]
set wns   [expr {[llength $setup] ? [get_property SLACK $setup] : "n/a"}]
set whs   [expr {[llength $hold]  ? [get_property SLACK $hold]  : "n/a"}]

set f [open [file join $out ${top}_summary.txt] w]
puts $f "module        $top (OOC, $part, aclk 10.000 ns = 100 MHz, post-route; SPAN_MAX 512, DESC_DEPTH 16, FETCH_DEPTH 16)"
puts $f "vivado        [version -short]"
puts $f "LUT           $lut (Slice LUTs: $lutlogic logic + $lutmem memory; $lutcells LUT cells before LUT combining)"
puts $f "FF            $ff"
puts $f "BRAM (RAMB*)  $bram"
puts $f "DSP48E1       $dsp"
puts $f "latches       synth $latches_synth, route [count_latches]"
puts $f "WNS (ns)      $wns"
puts $f "WHS (ns)      $whs"
if {[llength $setup]} {
    puts $f "critical path [get_property STARTPOINT_PIN $setup] -> [get_property ENDPOINT_PIN $setup]"
    puts $f "              data path [get_property DATAPATH_DELAY $setup] ns, [get_property LOGIC_LEVELS $setup] logic levels"
}
proc stage_line {f label cells} {
    if {[llength $cells] == 0} { puts $f "stage         $label: no cells found"; return }
    set p [get_timing_paths -quiet -setup -max_paths 1 -to $cells]
    if {[llength $p]} {
        puts $f "stage         $label: slack [get_property SLACK $p] ns, data path [get_property DATAPATH_DELAY $p] ns, [get_property LOGIC_LEVELS $p] levels, [get_property STARTPOINT_PIN $p] -> [get_property ENDPOINT_PIN $p]"
    } else {
        puts $f "stage         $label: no timed register-to-register path"
    }
}
stage_line $f "A scan (a_X, a_Y, a_rX, a_rY, a_u, a_v)" [get_cells -quiet -hier -regexp {.*a_(X|Y|rX|rY|u|v)_reg\[\d+\]}]
stage_line $f "B (c_*: D1 valid, x0, word columns)" [get_cells -quiet -hier -regexp {.*c_(pv|x0last|wlo|whi|x0)_reg.*}]
stage_line $f "C rule decision (blk_*, row_*, d_*)" [get_cells -quiet -hier -regexp {.*(blk|row|d)_[a-z0-9]+_reg.*}]
stage_line $f "D reuse / slots (pv_*, ptr)" [get_cells -quiet -hier -regexp {.*(pv_[a-z]+|ptr)_reg.*}]
stage_line $f "FIFO memories (d_mem, f_mem)" [get_cells -quiet -hier -regexp {.*[df]_mem_reg.*}]
stage_line $f "FIFO pointers / counts" [get_cells -quiet -hier -regexp {.*[df]_(wp|rp|cnt)_reg.*}]
close $f
write_checkpoint -force ${top}_route.dcp   ;# in the run folder (build/), for later inspection
puts "OOC SUMMARY [join [list LUT=$lut FF=$ff BRAM=$bram DSP=$dsp LATCHES=$latches_synth WNS=$wns WHS=$whs] { }]"
