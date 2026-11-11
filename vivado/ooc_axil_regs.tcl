# Out-of-context synthesis + implementation of rtl/axil_regs.v (step 3.1), part xc7z020clg484-1, 100 MHz.
#
# Run from build/ooc/axil_regs (keeps Vivado's .jou/.log out of the repo):
#   vivado -mode batch -source ../../../vivado/ooc_axil_regs.tcl
# Reports go to results/ooc/: axil_regs_utilization_{synth,route}.rpt, axil_regs_timing_route.rpt and
# axil_regs_summary.txt (LUT / FF / BRAM / DSP / latches / WNS / WHS, one line each).
# Timing covers register-to-register paths only (no I/O delays on module ports in an OOC run).

set script_dir [file dirname [file normalize [info script]]]
set repo       [file dirname $script_dir]
set top        axil_regs
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
set lutcells [n_cells {PRIMITIVE_GROUP == LUT}]
set bram  [n_cells {REF_NAME =~ RAMB*}]
set dsp   [n_cells {REF_NAME =~ DSP48*}]
set lutram [n_cells {PRIMITIVE_GROUP == DMEM}]
set setup [get_timing_paths -quiet -setup -max_paths 1]
set hold  [get_timing_paths -quiet -hold  -max_paths 1]
set wns   [expr {[llength $setup] ? [get_property SLACK $setup] : "n/a"}]
set whs   [expr {[llength $hold]  ? [get_property SLACK $hold]  : "n/a"}]

set f [open [file join $out ${top}_summary.txt] w]
puts $f "module        $top (OOC, $part, aclk 10.000 ns = 100 MHz, post-route)"
puts $f "vivado        [version -short]"
puts $f "LUT           $lut (Slice LUTs; $lutcells LUT cells before LUT combining)"
puts $f "LUTRAM        $lutram"
puts $f "FF            $ff"
puts $f "BRAM (RAMB*)  $bram"
puts $f "DSP48E1       $dsp"
puts $f "latches       synth $latches_synth, route [count_latches]"
puts $f "WNS (ns)      $wns"
puts $f "WHS (ns)      $whs"
close $f
puts "OOC SUMMARY [join [list LUT=$lut FF=$ff BRAM=$bram DSP=$dsp LATCHES=$latches_synth WNS=$wns WHS=$whs] { }]"
