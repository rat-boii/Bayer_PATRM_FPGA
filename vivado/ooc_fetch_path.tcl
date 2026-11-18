# Out-of-context synthesis + implementation for step 3.6b, part xc7z020clg484-1, 100 MHz:
#   prefetch_ctrl, line_buf, pixel_fetch (each alone) and fetch_path = vivado/ooc_fetch_path_wrap.v
#   (prefetch_ctrl -> line_buf -> pixel_fetch joined: times line_buf -> byte muxes -> F3, invisible in a
#   pixel_fetch-only run because the RAM data are module inputs there).
#
# Run from build/ooc/fetch_path (keeps Vivado's .jou/.log out of the repo):
#   vivado -mode batch -source ../../../vivado/ooc_fetch_path.tcl [-tclargs <run> ...]
# <run> = prefetch_ctrl | line_buf | pixel_fetch | fetch_path (default: all four).
# Reports go to results/ooc/: <run>_utilization_{synth,route}.rpt, <run>_timing_route.rpt, <run>_summary.txt
# (LUT / FF / BRAM / DSP / latches / WNS / WHS, the critical path, the worst path into named register groups).
# Build parameters as patrm_top (spec section 0): NSLOT 32, SLOT_WORDS 64 (the module defaults). Timing covers
# register-to-register paths only (no I/O delays on module ports in an OOC run).

set script_dir [file dirname [file normalize [info script]]]
set repo       [file dirname $script_dir]
set part       xc7z020clg484-1
set out        [file join $repo results ooc]
file mkdir $out

set runs [expr {[llength $argv] ? $argv : {prefetch_ctrl line_buf pixel_fetch fetch_path}}]

proc count_latches {} { return [llength [get_cells -quiet -hier -filter {REF_NAME =~ LD*}]] }
proc n_cells {flt} { return [llength [get_cells -quiet -hier -filter $flt]] }
proc util_row {txt name} {
    set re [string cat {\|\s*} $name {\s*\|\s*(\d+)}]
    if {[regexp $re $txt -> v]} { return $v } else { return "n/a" }
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
proc cells_re {re} { return [get_cells -quiet -hier -regexp $re] }

foreach run $runs {
    switch -- $run {
        prefetch_ctrl { set top prefetch_ctrl;       set srcs [list [file join $repo rtl prefetch_ctrl.v]] }
        line_buf      { set top line_buf;            set srcs [list [file join $repo rtl line_buf.v]] }
        pixel_fetch   { set top pixel_fetch;         set srcs [list [file join $repo rtl pixel_fetch.v]] }
        fetch_path    { set top ooc_fetch_path_wrap
                        set srcs [list [file join $repo rtl prefetch_ctrl.v] [file join $repo rtl line_buf.v] \
                                       [file join $repo rtl pixel_fetch.v] [file join $script_dir ooc_fetch_path_wrap.v]] }
        default       { error "unknown run $run (prefetch_ctrl | line_buf | pixel_fetch | fetch_path)" }
    }
    read_verilog $srcs                                     ;# list: the repo path may contain spaces
    read_xdc -mode out_of_context [list [file join $script_dir ooc_100mhz.xdc]]
    synth_design -top $top -part $part -mode out_of_context
    report_utilization -file [file join $out ${run}_utilization_synth.rpt]
    set latches_synth [count_latches]

    opt_design
    place_design
    route_design
    report_utilization    -file [file join $out ${run}_utilization_route.rpt]
    report_timing_summary -max_paths 10 -file [file join $out ${run}_timing_route.rpt]

    set util     [report_utilization -return_string]
    set lut      [util_row $util {Slice LUTs}]
    set ff       [util_row $util {Slice Registers}]
    set lutlogic [util_row $util {LUT as Logic}]
    set lutmem   [util_row $util {LUT as Memory}]
    set ramb36   [n_cells {REF_NAME =~ RAMB36*}]
    set ramb18   [n_cells {REF_NAME =~ RAMB18*}]
    set dsp      [n_cells {REF_NAME =~ DSP48*}]
    set setup    [get_timing_paths -quiet -setup -max_paths 1]
    set hold     [get_timing_paths -quiet -hold  -max_paths 1]
    set wns      [expr {[llength $setup] ? [get_property SLACK $setup] : "n/a"}]
    set whs      [expr {[llength $hold]  ? [get_property SLACK $hold]  : "n/a"}]

    set f [open [file join $out ${run}_summary.txt] w]
    puts $f "module        $run (top $top; OOC, $part, aclk 10.000 ns = 100 MHz, post-route; NSLOT 32, SLOT_WORDS 64)"
    puts $f "vivado        [version -short]"
    puts $f "LUT           $lut (Slice LUTs: $lutlogic logic + $lutmem memory)"
    puts $f "FF            $ff"
    puts $f "BRAM          $ramb36 RAMB36 + $ramb18 RAMB18 (= [expr {$ramb36 + $ramb18 / 2.0}] RAMB36 equivalent)"
    puts $f "DSP48E1       $dsp"
    puts $f "latches       synth $latches_synth, route [count_latches]"
    puts $f "WNS (ns)      $wns"
    puts $f "WHS (ns)      $whs"
    if {[llength $setup]} {
        puts $f "critical path [get_property STARTPOINT_PIN $setup] -> [get_property ENDPOINT_PIN $setup]"
        puts $f "              data path [get_property DATAPATH_DELAY $setup] ns, [get_property LOGIC_LEVELS $setup] logic levels"
    }
    if {$run eq "prefetch_ctrl" || $run eq "fetch_path"} {
        stage_line $f "prefetch P1-P3 (p1_*, p2_*, p3_*)" [cells_re {.*u?_?pc?/?p[123]_[a-z]+_reg.*|^p[123]_[a-z]+_reg.*}]
        stage_line $f "prefetch IS (is_*)" [cells_re {.*is_[a-z]+_reg.*}]
        stage_line $f "prefetch busy / last_user / counters" [cells_re {.*(busy|last_user|blk_idx|blocks_done|blocks_ready|cdone|rq_[a-z]+)_reg.*}]
        stage_line $f "prefetch line_buf write registers (buf_*)" [cells_re {.*buf_(we|wbank|waddr|wdata)_reg.*}]
    }
    if {$run eq "pixel_fetch" || $run eq "fetch_path"} {
        stage_line $f "pixel_fetch F1 (f1_*, k)" [cells_re {.*(f1_[A-Za-z]+|/k|^k)_reg.*}]
        stage_line $f "pixel_fetch F2 (f2_*)" [cells_re {.*f2_[a-z0-9]+_reg.*}]
        stage_line $f "pixel_fetch F3 (ip_*)" [cells_re {.*ip_[a-z0-9]+_reg.*}]
    }
    if {$run eq "line_buf" || $run eq "fetch_path"} {
        stage_line $f "line_buf RAMs (mem_*)" [get_cells -quiet -hier -filter {REF_NAME =~ RAMB*}]
    }
    close $f
    write_checkpoint -force ${run}_route.dcp              ;# in the run folder (build/), for later inspection
    puts "OOC SUMMARY $run [join [list LUT=$lut FF=$ff RAMB36=$ramb36 RAMB18=$ramb18 DSP=$dsp LATCHES=$latches_synth WNS=$wns WHS=$whs] { }]"
    close_design
}
