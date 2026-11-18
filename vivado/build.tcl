# Block design, bitstream and XSA of the grayscale engine on the ZedBoard (step 4.1; also step 0.2a).
# Batch and reproducible: the project is created from nothing under build/vivado/<name>, nothing is edited by hand.
#
# Run from build/vivado (keeps Vivado's .jou/.log out of the repo):
#   vivado -mode batch -source ../../vivado/build.tcl                      normal build, name patrm_gray
#   vivado -mode batch -source ../../vivado/build.tcl -tclargs ila=1       debug build with a 5-probe native ILA, patrm_gray_ila
#   vivado -mode batch -source ../../vivado/build.tcl -tclargs bd_only=1   stop after validate_bd_design
#
# Output in results/hw/ (the .xsa, .bit and .ltx files are not tracked by git):
#   <name>.xsa, <name>.bit, ps7_init.tcl, address_map.txt, summary.txt, timing_summary.rpt, clock_interaction.rpt,
#   worst10_paths.rpt, utilization.rpt, utilization_hier.rpt, power.rpt, methodology.rpt, drc.rpt
# The ILA build writes only <name>.xsa / .bit / .ltx and <name>_summary.txt: all reported numbers come from the build
# without the ILA (D9). The script stops with an error if a check fails; every check is named in the error.

set script_dir [file dirname [file normalize [info script]]]
set repo       [file dirname $script_dir]
set part       xc7z020clg484-1
set board_part digilentinc.com:zedboard:part0:1.1          ;# Digilent zedboard 1.3 board files (CLAUDE.md, D18)
set ddr_part   "MT41J128M16 HA-15E"                        ;# D18, ZedBoard Rev C
set fclk_mhz   100                                         ;# D8
set engine_base 0x43C00000
set engine_range 0x10000
set src_base   0x10000000                                  ;# spec/memory_map.md section 1, 16 MB each
set dst_base   0x18000000
set buf_size   0x01000000
set rtl_names  {axil_regs ctrl_fsm block_planner coord_gen prefetch_ctrl axi_rd_master line_buf pixel_fetch
                bilinear_interp out_fifo axi_wr_master patrm_top}

array set opt {ila 0 bd_only 0}
# vivado.bat on Windows splits "ila=1" at the "=", so the script receives "ila" "1"; both forms are accepted
set args_text [regsub -all {=} [join $argv " "] " "]
foreach {k v} $args_text {
    if {![info exists opt($k)] || ($v ne "0" && $v ne "1")} { error "unknown argument '$k $v' (use ila=0|1, bd_only=0|1)" }
    set opt($k) $v
}
set name   [expr {$opt(ila) ? "patrm_gray_ila" : "patrm_gray"}]
set prj    [file join $repo build vivado $name]
set out    [file join $repo results hw]
file mkdir $out
proc note {s} { puts "BUILD: $s" }
proc hex32 {v} { return [format 0x%08X [expr {$v & 0xFFFFFFFF}]] }
proc n_msg {sev} { return [get_msg_config -count -severity $sev] }

# ---------------- 1. board files ----------------
set found [get_board_parts -quiet *zed*]
note "board parts matching *zed*: $found"
if {[lsearch -exact $found $board_part] < 0} {
    error "CHECK FAILED board part: $board_part is not installed. Install the Digilent ZedBoard board files: README.md, New laptop setup, step 5."
}
note "CHECK OK board part $board_part"

create_project -force $name $prj -part $part
set_property board_part $board_part [current_project]
set_property target_language Verilog [current_project]

set srcs {}
foreach n $rtl_names { lappend srcs [file join $repo rtl $n.v] }
add_files -norecurse $srcs
set vh [file join $repo rtl patrm_regs.vh]
add_files -norecurse [list $vh]
set_property file_type {Verilog Header} [get_files $vh]
set_property include_dirs [list [file join $repo rtl]] [current_fileset]
foreach n $rtl_names {                                     ;# D17: plain Verilog
    set t [get_property FILE_TYPE [get_files [file join $repo rtl $n.v]]]
    if {$t ne "Verilog"} { error "CHECK FAILED D17: $n.v has file type $t" }
}
set eng_module patrm_top
if {$opt(ila)} {                                           ;# debug only (D9): engine + probe outputs, generated under build/
    source [file join $script_dir ila_map.tcl]
    source [file join $script_dir ila_wrapper.tcl]
    set eng_module patrm_ila_top
    set ila_v [file join $repo build vivado $eng_module.v]
    ila_make_wrapper [file join $repo rtl patrm_top.v] $ila_v
    add_files -norecurse [list $ila_v]
}
update_compile_order -fileset sources_1

# ---------------- 2. block design ----------------
create_bd_design system
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 processing_system7_0]
note "processing_system7 version [get_property VLNV $ps]"
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} $ps
note "DDR part from the board preset: [get_property CONFIG.PCW_UIPARAM_DDR_PARTNO $ps]"

# D18: right after the preset, then read back
proc check_ddr {ps want where} {
    set got [get_property CONFIG.PCW_UIPARAM_DDR_PARTNO $ps]
    if {$got ne $want} { error "CHECK FAILED D18 ($where): PCW_UIPARAM_DDR_PARTNO = '$got', expected '$want'" }
    note "CHECK OK D18 ($where): PCW_UIPARAM_DDR_PARTNO = $got"
}
set_property CONFIG.PCW_UIPARAM_DDR_PARTNO $ddr_part $ps
check_ddr $ps $ddr_part "after set_property"

set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 1 \
    CONFIG.PCW_USE_S_AXI_HP0 1  CONFIG.PCW_S_AXI_HP0_DATA_WIDTH 64 \
    CONFIG.PCW_USE_S_AXI_HP1 1  CONFIG.PCW_S_AXI_HP1_DATA_WIDTH 64 \
    CONFIG.PCW_USE_FABRIC_INTERRUPT 1  CONFIG.PCW_IRQ_F2P_INTR 1 \
    CONFIG.PCW_EN_CLK0_PORT 1  CONFIG.PCW_EN_RST0_PORT 1 \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ $fclk_mhz] $ps

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset proc_sys_reset_0]
set ic  [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi_gp0]
set_property CONFIG.NUM_MI 1 $ic
set eng [create_bd_cell -type module -reference $eng_module patrm_0]

# one clock: FCLK_CLK0
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
    [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK] [get_bd_pins processing_system7_0/S_AXI_HP0_ACLK] \
    [get_bd_pins processing_system7_0/S_AXI_HP1_ACLK] [get_bd_pins proc_sys_reset_0/slowest_sync_clk] \
    [get_bd_pins axi_gp0/ACLK] [get_bd_pins axi_gp0/S00_ACLK] [get_bd_pins axi_gp0/M00_ACLK] [get_bd_pins patrm_0/aclk]
# reset
connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins proc_sys_reset_0/ext_reset_in]
connect_bd_net [get_bd_pins proc_sys_reset_0/interconnect_aresetn] [get_bd_pins axi_gp0/ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins axi_gp0/S00_ARESETN] [get_bd_pins axi_gp0/M00_ARESETN] [get_bd_pins patrm_0/aresetn]
# AXI
connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] [get_bd_intf_pins axi_gp0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_gp0/M00_AXI] [get_bd_intf_pins patrm_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins patrm_0/m_axi_hp0] [get_bd_intf_pins processing_system7_0/S_AXI_HP0]
connect_bd_intf_net [get_bd_intf_pins patrm_0/m_axi_hp1] [get_bd_intf_pins processing_system7_0/S_AXI_HP1]
# interrupt -> IRQ_F2P[0]
connect_bd_net [get_bd_pins patrm_0/interrupt] [get_bd_pins processing_system7_0/IRQ_F2P]

if {$opt(ila)} {                                           ;# debug option only (D9)
    set clk_port [create_bd_port -dir O -type clk ila_clk]  ;# to the native ILA in the top level (ila_wrapper.tcl)
    set_property CONFIG.FREQ_HZ [expr {$fclk_mhz * 1000000}] $clk_port
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] $clk_port
    foreach entry $::ila_probes {
        lassign $entry probe text fields
        set port [create_bd_port -dir O -from [expr {[ila_probe_width $fields] - 1}] -to 0 $probe]
        connect_bd_net [get_bd_pins patrm_0/$probe] $port
    }
}

# ---------------- 3. addresses ----------------
set reg_seg [get_bd_addr_segs -quiet patrm_0/s_axi/*]
if {[llength $reg_seg] != 1} { error "CHECK FAILED address map: engine register segment not found ($reg_seg)" }
assign_bd_address -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
    -offset $engine_base -range $engine_range $reg_seg -force
assign_bd_address

set map {}
foreach sp [get_bd_addr_spaces] {
    foreach s [get_bd_addr_segs -quiet -of_objects $sp] {
        if {[catch {set off [get_property OFFSET $s]; set rng [get_property RANGE $s]}]} continue
        if {$off eq "" || $rng eq ""} continue
        lappend map [list [get_property PATH $sp] [get_property NAME $s] [expr {$off + 0}] [expr {$rng + 0}]]
    }
}
set engine_seen 0
foreach port {hp0 hp1} { set reach($port) 0 }
foreach m $map {
    lassign $m sp seg off rng
    if {[string match *processing_system7_0/Data $sp] && [string match *patrm_0* $seg]} {
        set engine_seen 1
        set actual_base $off; set actual_range $rng
    }
    foreach port {hp0 hp1} {
        if {[string match "*patrm_0/m_axi_$port" $sp] && [string match *DDR* $seg] &&
            $off <= $src_base && $off + $rng >= $src_base + $buf_size &&
            $off <= $dst_base && $off + $rng >= $dst_base + $buf_size} { set reach($port) 1 }
    }
}
if {!$engine_seen} { error "CHECK FAILED address map: no engine segment in the GP0 address space" }
note "engine registers at [hex32 $actual_base], range [hex32 $actual_range] (wanted [hex32 $engine_base], [hex32 $engine_range])"
if {$actual_base != $engine_base || $actual_range != $engine_range} {
    error "CHECK FAILED address map: the tool assigned another engine address; update spec/memory_map.md and the software"
}
foreach port {hp0 hp1} {
    if {!$reach($port)} { error "CHECK FAILED address map: m_axi_$port cannot reach [hex32 $src_base] and [hex32 $dst_base] (16 MB each) in DDR" }
    note "CHECK OK m_axi_$port reaches [hex32 $src_base] and [hex32 $dst_base] (16 MB each) in DDR"
}

# ---------------- 4. validate ----------------
regenerate_bd_layout
# Known exception, accepted by the team on 2026-11-18: the Digilent zedboard 1.3 preset itself sets negative DQS-to-clock
# board delays, and validate reports each as a critical warning (PSU-1..4), also for the preset alone. Only exactly these
# four, and only with exactly the preset's values, are accepted: during validate they are logged as INFO so that the
# critical-warning count below contains everything else. Any other critical warning stops the build.
array set psu_known {0 -0.073 1 -0.034 2 -0.03 3 -0.082}
set v_known 0
foreach k {0 1 2 3} {
    set got [get_property CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_$k $ps]
    if {$got != $psu_known($k)} { error "CHECK FAILED validate_bd_design: DQS_TO_CLK_DELAY_$k = $got, preset value is $psu_known($k)" }
    set_msg_config -id PSU-[expr {$k + 1}] -new_severity INFO
    incr v_known
}
set c0 [n_msg {CRITICAL WARNING}]; set w0 [n_msg WARNING]; set e0 [n_msg ERROR]
puts "=== VALIDATE START"
validate_bd_design
puts "=== VALIDATE END"
set v_other [expr {[n_msg {CRITICAL WARNING}] - $c0}]; set v_warn [expr {[n_msg WARNING] - $w0}]; set v_err [expr {[n_msg ERROR] - $e0}]
foreach k {1 2 3 4} { reset_msg_config -quiet -id PSU-$k -default_severity }
note "validate_bd_design: $v_err errors, $v_other other critical warnings, $v_known known preset critical warnings (PSU-1..4), $v_warn warnings"
if {$v_err || $v_other} { error "CHECK FAILED validate_bd_design: $v_err errors, $v_other critical warnings besides PSU-1..4" }
check_ddr $ps $ddr_part "after validate_bd_design"
save_bd_design

set p_names {PCW_UIPARAM_DDR_PARTNO PCW_UIPARAM_DDR_MEMORY_TYPE PCW_UIPARAM_DDR_FREQ_MHZ PCW_UIPARAM_ACT_DDR_FREQ_MHZ
             PCW_UIPARAM_DDR_BUS_WIDTH PCW_UIPARAM_DDR_CL PCW_UIPARAM_DDR_CWL PCW_UIPARAM_DDR_T_RCD PCW_UIPARAM_DDR_T_RP
             PCW_CRYSTAL_PERIPHERAL_FREQMHZ PCW_APU_PERIPHERAL_FREQMHZ PCW_ACT_APU_PERIPHERAL_FREQMHZ
             PCW_FPGA0_PERIPHERAL_FREQMHZ PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ PCW_FCLK0_PERIPHERAL_DIVISOR0
             PCW_FCLK0_PERIPHERAL_DIVISOR1 PCW_FCLK_CLK0_BUF PCW_USE_M_AXI_GP0 PCW_USE_S_AXI_HP0 PCW_S_AXI_HP0_DATA_WIDTH
             PCW_USE_S_AXI_HP1 PCW_S_AXI_HP1_DATA_WIDTH PCW_USE_FABRIC_INTERRUPT PCW_IRQ_F2P_INTR PCW_UART1_PERIPHERAL_ENABLE
             PCW_UART1_BAUD_RATE PCW_UART1_UART1_IO}
set ps_lines {}
foreach p $p_names {
    if {[catch {set v [get_property CONFIG.$p $ps]}]} { set v "(no such property)" }
    lappend ps_lines [format "  %-34s %s" $p $v]
}
foreach l $ps_lines { note "PS7 $l" }
set act [get_property CONFIG.PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ $ps]
if {![string is double -strict $act] || abs($act - $fclk_mhz) > 0.5} {
    error "CHECK FAILED FCLK_CLK0: the PS7 settings give $act MHz, wanted $fclk_mhz MHz"
}

if {!$opt(ila)} {
    set f [open [file join $out address_map.txt] w]
    puts $f "address map of the block design (step 4.1, build $name); master address space, segment, base, last address, size"
    foreach m [lsort -index 0 $map] {
        lassign $m sp seg off rng
        puts $f [format "%-34s %-44s %s  %s  %d KB" $sp $seg [hex32 $off] [hex32 [expr {$off + $rng - 1}]] [expr {$rng / 1024}]]
    }
    close $f
}
if {$opt(bd_only)} { note "bd_only: stopping after validate_bd_design"; return }

# ---------------- 5. synthesis, implementation, bitstream ----------------
set bd_file [get_files system.bd]
generate_target all $bd_file
set wrapper [make_wrapper -files $bd_file -top]
if {$opt(ila)} {
    set cfg [list CONFIG.C_NUM_OF_PROBES [llength $::ila_probes] CONFIG.C_DATA_DEPTH $::ila_depth CONFIG.C_INPUT_PIPE_STAGES 1]
    foreach entry $::ila_probes {
        lassign $entry probe text fields
        lappend cfg CONFIG.C_[string toupper $probe]_WIDTH [ila_probe_width $fields]
    }
    create_ip -name ila -vendor xilinx.com -library ip -module_name ila_0
    set_property -dict $cfg [get_ips ila_0]
    generate_target all [get_ips ila_0]
    create_ip_run [get_ips ila_0]
    set ila_top [file join $repo build vivado system_wrapper_ila.v]
    ila_make_top $wrapper $ila_top
    set wrapper $ila_top
}
add_files -norecurse [list $wrapper]
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

set jobs 4
if {[info exists ::env(NUMBER_OF_PROCESSORS)]} { set jobs [expr {max(2, $::env(NUMBER_OF_PROCESSORS) - 1)}] }
proc run_ok {r} {
    if {[get_property PROGRESS [get_runs $r]] ne "100%" || [string match *ERROR* [get_property STATUS [get_runs $r]]]} {
        error "CHECK FAILED run $r: [get_property STATUS [get_runs $r]]; see [get_property DIRECTORY [get_runs $r]]/runme.log"
    }
    note "run $r: [get_property STATUS [get_runs $r]]"
}
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
run_ok synth_1
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
run_ok impl_1
open_run impl_1

# ---------------- 6. outputs ----------------
set run_dir [get_property DIRECTORY [get_runs impl_1]]
set bit [file join $run_dir system_wrapper.bit]
if {![file exists $bit]} { error "CHECK FAILED bitstream: $bit not found" }
file copy -force $bit [file join $out $name.bit]
set ltx [file join $run_dir system_wrapper.ltx]
if {[file exists $ltx]} {
    file copy -force $ltx [file join $out $name.ltx]
} elseif {$opt(ila)} {
    error "CHECK FAILED ILA: probes file $ltx not found"
}
write_hw_platform -fixed -include_bit -force -file [file join $out $name.xsa]
if {!$opt(ila)} {
    set init [glob -nocomplain [file join $prj $name.gen sources_1 bd system ip *processing_system7* ps7_init.tcl]]
    if {[llength $init] != 1} { error "CHECK FAILED ps7_init.tcl: found '$init'" }
    file copy -force [lindex $init 0] [file join $out ps7_init.tcl]
}

proc rname {base} { global out opt name; return [file join $out [expr {$opt(ila) ? "${name}_$base" : $base}]] }
proc util_row {txt nm} {
    foreach line [split $txt "\n"] {
        if {![regexp [string cat {^\|\s*} $nm {\s*\|}] $line]} continue
        set c {}
        foreach x [lrange [split $line |] 1 end-1] { lappend c [string trim $x] }
        return [list [lindex $c 1] [lindex $c end-1] [lindex $c end]]
    }
    return {n/a n/a n/a}
}
proc pct_text {r} { lassign $r u a p; return "$u of $a ($p %)" }
proc path_line {p} {
    return "slack [format %.3f [get_property SLACK $p]] ns, data path [format %.3f [get_property DATAPATH_DELAY $p]] ns, [get_property LOGIC_LEVELS $p] levels, [get_property STARTPOINT_PIN $p] -> [get_property ENDPOINT_PIN $p]"
}

set ts [report_timing_summary -max_paths 10 -return_string]
lassign {n/a n/a n/a n/a n/a n/a n/a n/a} wns tns tnsf tnst whs ths thsf thst
regexp {WNS\(ns\)[^\n]*\n[\s-]*\n\s*([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)} $ts \
    -> wns tns tnsf tnst whs ths thsf thst
set hier [report_utilization -hierarchical -hierarchical_depth 2 -return_string]
set util [report_utilization -return_string]
set ci   [report_clock_interaction -return_string]
set pwr  [report_power -return_string]

if {!$opt(ila)} {
    foreach {b t} [list timing_summary.rpt $ts clock_interaction.rpt $ci utilization.rpt $util power.rpt $pwr] {
        set h [open [file join $out $b] w]; puts $h $t; close $h
    }
    report_utilization -hierarchical -file [file join $out utilization_hier.rpt]
    report_timing -delay_type max -max_paths 10 -nworst 1 -input_pins -file [file join $out worst10_paths.rpt]
    report_methodology -file [file join $out methodology.rpt]
    report_drc -file [file join $out drc.rpt]
}

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
    if {![info exists H([lindex $c 0])]} { set H([lindex $c 0]) $row }
}
proc hrow {inst} {
    upvar H H
    foreach k [array names H] { if {[string match "${inst}*" $k]} { return $H($k) } }
    return {}
}
proc hval {r k} { if {[dict exists $r $k]} { return [dict get $r $k] } else { return "-" } }
# Vivado leaves some instances out of the hierarchical table: count those from their leaf cells (before LUT combining)
proc ncell {base pat} { return [llength [get_cells -quiet -hier -filter "NAME =~ $base/* && REF_NAME =~ $pat"]] }
proc row_from_cells {inst} {
    set b system_i/$inst
    set srl [ncell $b SRL*]
    set ram [expr {[ncell $b RAMD*] + [ncell $b RAMS*]}]
    return [dict create {Total LUTs} [expr {[ncell $b LUT*] + $srl + $ram}] LUTRAMs $ram SRLs $srl FFs [ncell $b FD*] \
                RAMB36 [ncell $b RAMB36*] RAMB18 [ncell $b RAMB18*] {DSP Blocks} [ncell $b DSP48*]]
}

set f [open [rname summary.txt] w]
puts $f "build         $name (block design + PS7, $part, Vivado [version -short], post-route)"
puts $f "board part    $board_part"
puts $f "D18 DDR part  [get_property CONFIG.PCW_UIPARAM_DDR_PARTNO [get_bd_cells -quiet processing_system7_0]] (read back after set_property and after validate_bd_design)"
puts $f "validate      $v_err errors, $v_other other critical warnings (tool warning counter +$v_warn); NOT fully clean: $v_known known critical warnings PSU-1..4 (negative DQS_TO_CLK_DELAY_0..3 from the Digilent preset, accepted 2026-11-18)"
foreach r {synth_1 impl_1} {
    array unset cw
    set rl [file join [get_property DIRECTORY [get_runs $r]] runme.log]
    if {[file exists $rl]} {
        set h [open $rl r]
        foreach line [split [read $h] "\n"] {
            if {[regexp {^CRITICAL WARNING: \[([^\]]+)\]} $line -> id]} { if {[info exists cw($id)]} { incr cw($id) } else { set cw($id) 1 } }
        }
        close $h
    }
    set s {}
    foreach k [lsort [array names cw]] { lappend s "$k x$cw($k)" }
    puts $f "run $r critical warnings: [expr {[llength $s] ? [join $s {, }] : {none}}]"
}
puts $f "FCLK_CLK0     requested $fclk_mhz MHz, PS7 settings give [get_property CONFIG.PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ [get_bd_cells -quiet processing_system7_0]] MHz"
foreach c [get_clocks] { puts $f "clock         [get_property NAME $c]: period [get_property PERIOD $c] ns, source [get_property SOURCE_PINS $c]" }
puts $f ""
puts $f "WNS (ns)      $wns"
puts $f "TNS (ns)      $tns ($tnsf failing of $tnst endpoints)"
puts $f "WHS (ns)      $whs"
puts $f "THS (ns)      $ths ($thsf failing of $thst endpoints)"
set sp [get_timing_paths -quiet -setup -max_paths 1]
set hp [get_timing_paths -quiet -hold  -max_paths 1]
if {[llength $sp]} { puts $f "worst setup   [path_line $sp]" }
if {[llength $hp]} { puts $f "worst hold    [path_line $hp]" }

# reset into the engine (it needed 8.197 ns of 10 in the OOC run, with no source register)
set rpin [get_pins -quiet -hier -filter {NAME =~ *patrm_0/aresetn}]
set r_ok 1
if {[llength $rpin] == 0} {
    puts $f "aresetn       engine reset pin not found in the netlist"; set r_ok 0
} else {
    set rs [get_timing_paths -quiet -setup -max_paths 1 -through [lindex $rpin 0]]
    set rh [get_timing_paths -quiet -hold  -max_paths 1 -through [lindex $rpin 0]]
    if {[llength $rs]} {
        set sc [get_cells -quiet -of_objects [get_property STARTPOINT_PIN $rs]]
        puts $f "aresetn setup [path_line $rs]"
        puts $f "aresetn start cell type [get_property REF_NAME $sc]"
        if {![string match FD* [get_property REF_NAME $sc]]} { set r_ok 0 }
        if {[get_property SLACK $rs] < 0} { set r_ok 0 }
    } else { puts $f "aresetn setup no timed path"; set r_ok 0 }
    if {[llength $rh]} { puts $f "aresetn hold  [path_line $rh]" }
}
puts $f ""
puts $f "clock interaction (report_clock_interaction):"
set nci 0; set n_inter 0
foreach line [split $ci "\n"] {
    if {[regexp {^\s*(\S+)\s+(\S+)\s+(rise|fall) - (rise|fall)\s} $line -> c_from c_to]} {
        puts $f "  [regsub -all {\s+} [string trim $line] { }]"; incr nci
        if {$c_from ne $c_to} { incr n_inter }
    }
}
if {$nci == 0} { puts $f "  no entries parsed; see clock_interaction.rpt" }
puts $f "  clock pairs: $nci, of which between different clocks: $n_inter"
puts $f ""
puts $f "whole design (PS7 block, interconnect, reset, engine), post-route:"
puts $f "  LUT         [pct_text [util_row $util {Slice LUTs}]]"
puts $f "  LUT memory  [pct_text [util_row $util {LUT as Memory}]]"
puts $f "  FF          [pct_text [util_row $util {Slice Registers}]]"
puts $f "  BRAM        [pct_text [util_row $util {Block RAM Tile}]]"
puts $f "  DSP48E1     [pct_text [util_row $util {DSPs}]]"
puts $f "  Slices      [pct_text [util_row $util {Slice}]]"
puts $f "  latches     [llength [get_cells -quiet -hier -filter {REF_NAME =~ LD*}]]"
puts $f "by block:"
puts $f [format "  %-26s %7s %8s %7s %7s %7s %5s" block LUT LUTRAM SRL FF RAMB36 DSP]
foreach b {patrm_0 axi_gp0 proc_sys_reset_0 processing_system7_0} {
    if {[llength [get_cells -quiet system_i/$b]] == 0} continue
    set r [hrow $b]; set tag $b
    if {[llength $r] == 0} { set r [row_from_cells $b]; set tag "$b*" }
    set dsp [hval $r {DSP Blocks}]; if {$dsp eq "-"} { set dsp [hval $r {DSP48 Blocks}] }
    puts $f [format "  %-26s %7s %8s %7s %7s %7s %5s" $tag [hval $r {Total LUTs}] [hval $r LUTRAMs] [hval $r SRLs] [hval $r FFs] [hval $r RAMB36] $dsp]
}
puts $f "  * = no row in Vivado's hierarchical report, counted from leaf cells. The PS7 hard block itself uses no fabric LUT or FF."
if {$opt(ila)} {
    set w {}
    foreach entry $::ila_probes { lappend w "[lindex $entry 0]=[ila_probe_width [lindex $entry 2]]" }
    puts $f "debug ILA     native, depth $::ila_depth, clock FCLK_CLK0, probe widths: [join $w {, }]"
    foreach b {u_ila_0 dbg_hub} {
        set srl [ncell $b SRL*]
        puts $f "debug $b  RAMB36 [ncell $b RAMB36*], RAMB18 [ncell $b RAMB18*], LUT [expr {[ncell $b LUT*] + $srl}] (leaf cells), FF [ncell $b FD*] (debug build only, D9)"
    }
}
set oocf [file join $repo results ooc patrm_top_summary.txt]
if {[file exists $oocf]} {
    set h [open $oocf r]; set t [read $h]; close $h
    regexp -line {^LUT\s+(\d+)} $t -> ol; regexp -line {^FF\s+(\d+)} $t -> of
    regexp -line {^BRAM\s+(\d+)} $t -> ob; regexp -line {^DSP48E1\s+(\d+)} $t -> od
    puts $f "  step 3.8 OOC engine alone  LUT $ol, FF $of, RAMB36 $ob, DSP $od"
}
puts $f ""
puts $f "power         ESTIMATE: report_power, default settings, vectorless; whole device including the PS"
foreach key {{Total On-Chip Power \(W\)} {Dynamic \(W\)} {Device Static \(W\)} {Confidence Level}} {
    if {[regexp [string cat {\|\s*(} $key {)\s*\|\s*([^|]*?)\s*\|}] $pwr -> k v]} { puts $f "  [format %-26s $k] $v" }
}
foreach key {PS7 Clocks {Slice Logic} Signals {Block RAM} DSPs} {
    if {[regexp -line [string cat {^\|\s*} $key {\s*\|\s*([\d.<]+)\s*\|}] $pwr -> v]} { puts $f "  [format %-26s "$key (W)"] $v" }
}
puts $f ""
puts $f "PS7 settings:"
foreach l $ps_lines { puts $f $l }
close $f

note "OUTPUT xsa [file join $out $name.xsa]"
note "OUTPUT bit [file join $out $name.bit]"
puts "BUILD SUMMARY $name WNS=$wns TNS=$tns WHS=$whs ARESETN_OK=$r_ok"
if {![string is double -strict $wns] || $wns < 0} { error "CHECK FAILED timing: WNS = $wns" }
if {![string is double -strict $whs] || $whs < 0} { error "CHECK FAILED timing: WHS = $whs" }
if {!$r_ok} { error "CHECK FAILED aresetn path into the engine: see [rname summary.txt]" }
note "all checks passed"
