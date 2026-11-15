# Out-of-context synthesis + implementation of rtl/bilinear_interp.v (step 3.3), part xc7z020clg484-1, 100 MHz.
#
# Run from build/ooc/bilinear_interp (keeps Vivado's .jou/.log out of the repo):
#   vivado -mode batch -source ../../../vivado/ooc_bilinear_interp.tcl
# Reports go to results/ooc/: bilinear_interp_utilization_{synth,route}.rpt,
# bilinear_interp_timing_route.rpt and bilinear_interp_summary.txt (LUT / FF / BRAM / DSP / latches / WNS / WHS, the critical path, the DSP48E1 list).
# Timing covers register-to-register paths only (no I/O delays on module ports in an OOC run). The extra
# "port to reg" lines are information only: how much of the 10 ns the path from an input port to the first
# register needs inside this module (the rest belongs to the sender, the F3 register of pixel_fetch), and the
# path op_ready -> clock enables (the rest belongs to out_fifo).

set script_dir [file dirname [file normalize [info script]]]
set repo       [file dirname $script_dir]
set top        bilinear_interp
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
# Vivado packs almost every register of the module into the DSP48E1 blocks, so the stages are located by DSP pins.
# Pixel DSPs = the four whose B input comes from an ip_r* port (r1..r4 are delayed in the B registers).
set pixdsps {}
foreach c $dsps {
    set bp [get_ports -quiet -of [get_nets -quiet -of [get_pins -quiet $c/B[0]]]]
    if {[string match "ip_r*" $bp]} { lappend pixdsps $c }
}
proc path_line {f label p} {
    if {[llength $p]} {
        puts $f "stage         $label: slack [get_property SLACK $p] ns, data path [get_property DATAPATH_DELAY $p] ns, [get_property LOGIC_LEVELS $p] levels, [get_property STARTPOINT_PIN $p] -> [get_property ENDPOINT_PIN $p]"
    } else {
        puts $f "stage         $label: no timed register-to-register path"
    }
}
puts $f "stage         1 (p2, p3, p4 = P registers of the weight DSPs): data comes from the ip_xf / ip_yf ports (see port to reg); the only register-to-register path is the clock enable:"
stage_line $f "1 clock enable" [get_cells -quiet -hier -regexp {.*p[234]_reg.*}]
set apins {}
foreach c $pixdsps { lappend apins [get_pins -quiet $c/A[*]] }
path_line $f "2 (w1..w4 = A registers of the pixel DSPs)" [get_timing_paths -quiet -setup -max_paths 1 -to [join $apins]]
puts $f "stage         3 (q1..q4): multiply between the A/B registers and the M (or P) register inside each pixel DSP48E1, no fabric path"
set cpins {}
foreach c $pixdsps { lappend cpins [get_pins -quiet $c/PCIN[*]] }
path_line $f "4 (sum of q1..q4 -> op_d, DSP post-adders over PCOUT/PCIN)" [get_timing_paths -quiet -setup -max_paths 1 -through [join $cpins]]
# each DSP48E1 and the product it implements
array set wprod {
    p2 "p2 = (65536 - xf) * yf  (17 x 16, weight; w2 = p2 >> 16)"
    p3 "p3 = xf * (65536 - yf)  (16 x 17, weight; w3 = p3 >> 16)"
    p4 "p4 = xf * yf  (16 x 16, weight; w4 = p4 >> 16)"
}
puts $f "DSP48E1 cells (product; AREG BREG CREG MREG PREG; USE_MULT):"
foreach c $dsps {
    set what "?"
    if {[lsearch -exact $pixdsps $c] >= 0} {
        set bp [get_ports -quiet -of [get_nets -quiet -of [get_pins -quiet $c/B[0]]]]
        regexp {ip_r(\d)} $bp -> n
        set what "q$n = w$n * r$n  ([expr {$n == 1 ? 17 : 16}] x 8, pixel)"
        set drv [get_cells -quiet -of [get_pins -quiet -leaf -filter {DIRECTION == OUT} -of [get_nets -quiet -of [get_pins -quiet $c/PCIN[0]]]]]
        if {[llength $drv] && [get_property REF_NAME $drv] eq "DSP48E1"} {
            append what " + running sum from $drv (post-adder, PCIN)"
        }
        if {[get_property PREG $c] == 1 && [get_property MREG $c] == 1} { append what "; P register = op_d" }
    } else {
        foreach k [array names wprod] { if {[string match "${k}_reg*" $c]} { set what $wprod($k) } }
    }
    puts $f "  $c  $what;  [get_property AREG $c] [get_property BREG $c] [get_property CREG $c] [get_property MREG $c] [get_property PREG $c];  [get_property USE_MULT $c]"
}
puts $f "fabric cells  FF: [lsort [get_cells -quiet -hier -filter {REF_NAME =~ FD*}]]; SRL: [lsort [get_cells -quiet -hier -filter {REF_NAME =~ SRL*}]]"
# Information only (after every number above has been taken): give the input ports an input delay of 0 ns
# to see how much of the 10 ns period the path port -> first register needs inside this module.
set period [get_property PERIOD [get_clocks aclk]]
set_input_delay -clock aclk 0.000 [get_ports {ip_xf[*] ip_yf[*] ip_r1[*] ip_valid op_ready}]
foreach pat {ip_xf[*] ip_yf[*] ip_r1[*] ip_valid op_ready} {
    set p [get_timing_paths -quiet -setup -max_paths 1 -from [get_ports $pat]]
    if {[llength $p]} {
        puts $f "port to reg   $pat -> [get_property ENDPOINT_PIN $p]: needs [format %.3f [expr {$period - [get_property SLACK $p]}]] ns of the $period ns (information only; module ports are not constrained in the OOC run)"
    }
}
close $f
write_checkpoint -force ${top}_route.dcp   ;# in the run folder (build/), for later inspection
puts "OOC SUMMARY [join [list LUT=$lut FF=$ff BRAM=$bram DSP=$dsp LATCHES=$latches_synth WNS=$wns WHS=$whs] { }]"
