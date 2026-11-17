# Out-of-context synthesis + implementation of the output path (step 3.5): rtl/out_fifo.v and rtl/axi_wr_master.v,
# each as its own OOC run (the spec has no wrapper module), part xc7z020clg484-1, 100 MHz.
#
# Run from build/ooc/axi_wr_master (keeps Vivado's .jou/.log out of the repo):
#   vivado -mode batch -source ../../../vivado/ooc_axi_wr_master.tcl
# Reports go to results/ooc/, per module <m> = out_fifo, axi_wr_master: <m>_utilization_{synth,route}.rpt,
# <m>_timing_route.rpt and <m>_summary.txt (LUT / FF / BRAM / DSP / latches / WNS / WHS, the critical path).
# Timing covers register-to-register paths only (no I/O delays on module ports in an OOC run). The "port path"
# lines are information only: how much of the 10 ns a path from an input port needs inside the module (with an
# input delay of 0 ns and, for outputs, an output delay of 0 ns).

set script_dir [file dirname [file normalize [info script]]]
set repo       [file dirname $script_dir]
set part       xc7z020clg484-1
set out        [file join $repo results ooc]
file mkdir $out

proc count_latches {} { return [llength [get_cells -quiet -hier -filter {REF_NAME =~ LD*}]] }
proc n_cells {flt} { return [llength [get_cells -quiet -hier -filter $flt]] }
proc util_row {txt name} {
    set re [string cat {\|\s*} $name {\s*\|\s*(\d+)}]
    if {[regexp $re $txt -> v]} { return $v } else { return "n/a" }
}

# top: module; params: list of "NAME=VALUE" for the summary line; inports / outports: port patterns for the
# information-only port path lines
proc ooc_run {repo script_dir part out top params inports outports} {
    read_verilog [file join $repo rtl $top.v]
    read_xdc -mode out_of_context [file join $script_dir ooc_100mhz.xdc]
    synth_design -top $top -part $part -mode out_of_context
    report_utilization -file [file join $out ${top}_utilization_synth.rpt]
    set latches_synth [count_latches]
    opt_design
    place_design
    route_design
    report_utilization    -file [file join $out ${top}_utilization_route.rpt]
    report_timing_summary -max_paths 10 -file [file join $out ${top}_timing_route.rpt]

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

    set f [open [file join $out ${top}_summary.txt] w]
    puts $f "module        $top (OOC, $part, aclk 10.000 ns = 100 MHz, post-route, [join $params {, }])"
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
    # information only (after every number above has been taken)
    set period [get_property PERIOD [get_clocks aclk]]
    foreach pat $inports { set_input_delay -clock aclk 0.000 [get_ports $pat] }
    foreach pat $outports { set_output_delay -clock aclk 0.000 [get_ports $pat] }
    foreach pat $inports {
        set p [get_timing_paths -quiet -setup -max_paths 1 -from [get_ports $pat]]
        if {[llength $p]} {
            puts $f "port path     $pat -> [get_property ENDPOINT_PIN $p]: needs [format %.3f [expr {$period - [get_property SLACK $p]}]] ns of the $period ns, [get_property LOGIC_LEVELS $p] logic levels (information only)"
        }
    }
    foreach pat $outports {
        set p [get_timing_paths -quiet -setup -max_paths 1 -to [get_ports $pat]]
        if {[llength $p]} {
            puts $f "port path     [get_property STARTPOINT_PIN $p] -> $pat: needs [format %.3f [expr {$period - [get_property SLACK $p]}]] ns of the $period ns, [get_property LOGIC_LEVELS $p] logic levels (information only)"
        }
    }
    close $f
    write_checkpoint -force ${top}_route.dcp   ;# in the run folder (build/), for later inspection
    puts "OOC SUMMARY $top [join [list LUT=$lut FF=$ff BRAM=$bram DSP=$dsp LATCHES=$latches_synth WNS=$wns WHS=$whs] { }]"
    close_design
}

ooc_run $repo $script_dir $part $out out_fifo {OUT_DEPTH=64} \
    {op_valid op_d[*] wq_ready frame_start} {op_ready wq_valid wq_data[*] wq_count[*]}
ooc_run $repo $script_dir $part $out axi_wr_master {WR_OUTSTANDING=8} \
    {wq_count[*] wq_valid wq_data[*] m_axi_hp1_awready m_axi_hp1_wready m_axi_hp1_bvalid frame_start} {wq_ready}
