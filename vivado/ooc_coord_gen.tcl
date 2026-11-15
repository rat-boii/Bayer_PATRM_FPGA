# Out-of-context synthesis + implementation of rtl/coord_gen.v (step 3.2), part xc7z020clg484-1, 100 MHz.
#
# Run from build/ooc/coord_gen (keeps Vivado's .jou/.log out of the repo):
#   vivado -mode batch -source ../../../vivado/ooc_coord_gen.tcl
# Reports go to results/ooc/: coord_gen_utilization_{synth,route}.rpt, coord_gen_timing_route.rpt and
# coord_gen_summary.txt (LUT / FF / BRAM / DSP / latches / WNS / WHS, the critical path, the DSP48E1 list).
# Timing covers register-to-register paths only (no I/O delays on module ports in an OOC run). The extra
# "port to reg" lines are information only: how much of the 10 ns the path from a descriptor port to the first
# register needs inside this module (the rest belongs to the sender, the DESC FIFO of block_planner).

set script_dir [file dirname [file normalize [info script]]]
set repo       [file dirname $script_dir]
set top        coord_gen
set part       xc7z020clg484-1
set out        [file join $repo results ooc]
file mkdir $out

read_verilog [file join $repo rtl $top.v]
read_xdc -mode out_of_context [file join $script_dir ooc_100mhz.xdc]
synth_design -top $top -part $part -mode out_of_context -include_dirs [list [file join $repo rtl]]
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
# LUT / FF as in the utilization report (LUT combining packs two small LUT cells into one LUT6 site)
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
set dsps  [lsort [get_cells -quiet -hier -filter {REF_NAME =~ DSP48*}]]
set dsp   [llength $dsps]
set setup [get_timing_paths -quiet -setup -max_paths 1]
set hold  [get_timing_paths -quiet -hold  -max_paths 1]
set wns   [expr {[llength $setup] ? [get_property SLACK $setup] : "n/a"}]
set whs   [expr {[llength $hold]  ? [get_property SLACK $hold]  : "n/a"}]

set f [open [file join $out ${top}_summary.txt] w]
puts $f "module        $top (OOC, $part, aclk 10.000 ns = 100 MHz, post-route)"
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
# worst register-to-register path into each pipeline stage (by endpoint cell)
proc stage_line {f label cells} {
    if {[llength $cells] == 0} { puts $f "stage         $label: no cells found"; return }
    set p [get_timing_paths -quiet -setup -max_paths 1 -to $cells]
    if {[llength $p]} {
        puts $f "stage         $label: slack [get_property SLACK $p] ns, data path [get_property DATAPATH_DELAY $p] ns, [get_property LOGIC_LEVELS $p] levels, [get_property STARTPOINT_PIN $p] -> [get_property ENDPOINT_PIN $p]"
    } else {
        puts $f "stage         $label: no timed register-to-register path"
    }
}
puts $f "stage         S1 (DSP48E1 product registers): no register-to-register path outside the DSP48E1 (operand k comes from the desc_u / desc_v0 ports, see port to reg; operand b sits in the A register of the same DSP48E1)"
stage_line $f "S2 (p11..p22)" [get_cells -quiet -hier -regexp {.*p[12][12]_reg\[\d+\]}]
stage_line $f "S3 (start FIFO write)" [get_cells -quiet -hier -filter {NAME =~ *start_mem_reg*}]
stage_line $f "stepper (x_r, y_r)" [get_cells -quiet -hier -regexp {.*[xy]_r_reg\[\d+\]}]
puts $f "DSP48E1 cells (AREG BREG CREG MREG PREG; USE_MULT):"
foreach c $dsps {
    puts $f "  $c  [get_property AREG $c] [get_property BREG $c] [get_property CREG $c] [get_property MREG $c] [get_property PREG $c]  [get_property USE_MULT $c]"
}
# Information only (after every number above has been taken): give the descriptor ports an input delay of 0 ns
# to see how much of the 10 ns period the path port -> first register needs inside this module.
set period [get_property PERIOD [get_clocks aclk]]
set_input_delay -clock aclk 0.000 [get_ports {desc_u[*] desc_v0[*] desc_valid}]
foreach pat {desc_u[*] desc_v0[*] desc_valid} {
    set p [get_timing_paths -quiet -setup -max_paths 1 -from [get_ports $pat]]
    if {[llength $p]} {
        puts $f "port to reg   $pat -> [get_property ENDPOINT_PIN $p]: needs [format %.3f [expr {$period - [get_property SLACK $p]}]] ns of the $period ns (information only; module ports are not constrained in the OOC run)"
    }
}
close $f
write_checkpoint -force ${top}_route.dcp   ;# in the run folder (build/), for later inspection
puts "OOC SUMMARY [join [list LUT=$lut FF=$ff BRAM=$bram DSP=$dsp LATCHES=$latches_synth WNS=$wns WHS=$whs] { }]"
