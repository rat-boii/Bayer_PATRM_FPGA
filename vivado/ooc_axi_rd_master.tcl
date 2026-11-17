# Out-of-context synthesis + implementation of rtl/axi_rd_master.v (step 3.4), part xc7z020clg484-1, 100 MHz.
#
# Run from build/ooc/axi_rd_master (keeps Vivado's .jou/.log out of the repo):
#   vivado -mode batch -source ../../../vivado/ooc_axi_rd_master.tcl [-tclargs <RD_OUTSTANDING>]
# Reports go to results/ooc/: axi_rd_master_utilization_{synth,route}.rpt, axi_rd_master_timing_route.rpt and
# axi_rd_master_summary.txt (LUT / FF / BRAM / DSP / latches / WNS / WHS, the critical path).
# RD_OUTSTANDING defaults to 8 (the build value). Any other value (step 3.5 check: 14) writes the reports as
# axi_rd_master_ro<n>_*, so the RD_OUTSTANDING = 8 reports are never overwritten.
# Timing covers register-to-register paths only (no I/O delays on module ports in an OOC run). The "port to reg"
# and "port to port" lines are information only: how much of the 10 ns the path from an input port needs
# inside this module (cmd_* -> AR registers is the command bypass; m_axi_hp0_arready -> cmd_ready is
# combinational by design, spec section 10 / rtl header).

set script_dir [file dirname [file normalize [info script]]]
set repo       [file dirname $script_dir]
set top        axi_rd_master
set part       xc7z020clg484-1
set out        [file join $repo results ooc]
file mkdir $out
set ro         [expr {$argc >= 1 ? [lindex $argv 0] : 8}]
set tag        [expr {$ro == 8 ? $top : "${top}_ro${ro}"}]

read_verilog [file join $repo rtl $top.v]
read_xdc -mode out_of_context [file join $script_dir ooc_100mhz.xdc]
synth_design -top $top -part $part -mode out_of_context -generic RD_OUTSTANDING=$ro
report_utilization -file [file join $out ${tag}_utilization_synth.rpt]

proc count_latches {} { return [llength [get_cells -quiet -hier -filter {REF_NAME =~ LD*}]] }
set latches_synth [count_latches]

opt_design
place_design
route_design
report_utilization   -file [file join $out ${tag}_utilization_route.rpt]
report_timing_summary -max_paths 10 -file [file join $out ${tag}_timing_route.rpt]

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
set bram  [n_cells {REF_NAME =~ RAMB*}]
set dsp   [n_cells {REF_NAME =~ DSP48*}]
set setup [get_timing_paths -quiet -setup -max_paths 1]
set hold  [get_timing_paths -quiet -hold  -max_paths 1]
set wns   [expr {[llength $setup] ? [get_property SLACK $setup] : "n/a"}]
set whs   [expr {[llength $hold]  ? [get_property SLACK $hold]  : "n/a"}]

set f [open [file join $out ${tag}_summary.txt] w]
puts $f "module        $top (OOC, $part, aclk 10.000 ns = 100 MHz, post-route, RD_OUTSTANDING = $ro)"
puts $f "vivado        [version -short]"
puts $f "LUT           $lut (Slice LUTs: $lutlogic logic + $lutmem memory)"
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
# Information only (after every number above has been taken): input ports get an input delay of 0 ns, outputs
# an output delay of 0 ns, to see how much of the 10 ns period the port paths need inside this module.
set period [get_property PERIOD [get_clocks aclk]]
set_input_delay  -clock aclk 0.000 [get_ports {cmd_valid cmd_addr[*] cmd_words[*] cmd_slot[*] m_axi_hp0_arready m_axi_hp0_rvalid m_axi_hp0_rdata[*] m_axi_hp0_rresp[*]}]
set_output_delay -clock aclk 0.000 [get_ports {cmd_ready}]
foreach pat {cmd_valid cmd_addr[*] cmd_words[*] m_axi_hp0_arready m_axi_hp0_rvalid} {
    set p [get_timing_paths -quiet -setup -max_paths 1 -from [get_ports $pat]]
    if {[llength $p]} {
        puts $f "port path     $pat -> [get_property ENDPOINT_PIN $p]: needs [format %.3f [expr {$period - [get_property SLACK $p]}]] ns of the $period ns, [get_property LOGIC_LEVELS $p] logic levels (information only)"
    }
}
close $f
write_checkpoint -force ${tag}_route.dcp   ;# in the run folder (build/), for later inspection
puts "OOC SUMMARY [join [list LUT=$lut FF=$ff BRAM=$bram DSP=$dsp LATCHES=$latches_synth WNS=$wns WHS=$whs] { }]"
