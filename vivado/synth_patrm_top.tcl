# Synthesis sanity check of the whole grayscale engine (step 3.7): out-of-context synthesis only, no implementation
# (that is step 3.8). Part xc7z020clg484-1, aclk 100 MHz.
#
# Run from build/synth/patrm_top (keeps Vivado's .jou/.log out of the repo):
#   vivado -mode batch -source ../../../vivado/synth_patrm_top.tcl
# Reports go to results/ooc/: patrm_top_utilization_synth.rpt, patrm_top_synth_summary.txt
# (LUT / FF / BRAM / DSP, latches, multi-driven nets by DRC MDRV-1 and by synthesis messages).

set script_dir [file dirname [file normalize [info script]]]
set repo       [file dirname $script_dir]
set part       xc7z020clg484-1
set out        [file join $repo results ooc]
file mkdir $out

set names {axil_regs ctrl_fsm bayer_seq block_planner coord_gen prefetch_ctrl axi_rd_master line_buf pixel_fetch
           bilinear_interp out_fifo axi_wr_master patrm_top}
set srcs {}
foreach n $names { lappend srcs [file join $repo rtl $n.v] }
read_verilog $srcs                                         ;# list: the repo path may contain spaces
read_xdc -mode out_of_context [list [file join $script_dir ooc_100mhz.xdc]]
synth_design -top patrm_top -part $part -mode out_of_context -include_dirs [list [file join $repo rtl]]

proc n_cells {flt} { return [llength [get_cells -quiet -hier -filter $flt]] }
proc util_row {txt name} {
    set re [string cat {\|\s*} $name {\s*\|\s*(\d+)}]
    if {[regexp $re $txt -> v]} { return $v } else { return "n/a" }
}

report_utilization -file [file join $out patrm_top_utilization_synth.rpt]
set util    [report_utilization -return_string]
set drc     [report_drc -checks {MDRV-1} -return_string]
set mdrv    [regexp -all {MDRV-1 #\d+} $drc]
set latches [n_cells {REF_NAME =~ LD*}]
set ramb36  [n_cells {REF_NAME =~ RAMB36*}]
set ramb18  [n_cells {REF_NAME =~ RAMB18*}]
set dsp     [n_cells {REF_NAME =~ DSP48*}]
set lut     [util_row $util {Slice LUTs\*?}]
set ff      [util_row $util {Slice Registers}]
set lutmem  [util_row $util {LUT as Memory}]

# synthesis messages: inferred latches (Synth 8-327) and multi-driven nets
set log_multi 0
set log_latch 0
set logf [open vivado.log r]
foreach line [split [read $logf] "\n"] {
    if {[regexp -nocase {multi-driven|multiple drivers|Synth 8-6858|Synth 8-6859|Synth 8-3352} $line]} { incr log_multi }
    if {[regexp {Synth 8-327} $line]} { incr log_latch }
}
close $logf

set f [open [file join $out patrm_top_synth_summary.txt] w]
puts $f "module        patrm_top (OOC synthesis only, $part, aclk 10.000 ns = 100 MHz; NSLOT 32, BLOCK_LEN_MAX 64, RD_OUTSTANDING 8)"
puts $f "vivado        [version -short]"
puts $f "LUT           $lut (of which LUT as memory: $lutmem)"
puts $f "FF            $ff"
puts $f "BRAM          $ramb36 RAMB36 + $ramb18 RAMB18 (= [expr {$ramb36 + $ramb18 / 2.0}] RAMB36 equivalent)"
puts $f "DSP48E1       $dsp"
puts $f "latches       $latches cells, $log_latch synthesis messages (Synth 8-327)"
puts $f "multi-driven  $mdrv DRC MDRV-1 violations, $log_multi synthesis messages"
puts $f "note          post-synthesis numbers, no placement or routing; timing is step 3.8"
close $f
puts "SYNTH SUMMARY patrm_top LUT=$lut FF=$ff RAMB36=$ramb36 RAMB18=$ramb18 DSP=$dsp LATCHES=$latches LATCH_MSG=$log_latch MDRV=$mdrv MULTI_MSG=$log_multi"
