# Simulation sources of the whole block design, with processing_system7_vip as the PS model (step 4.1b).
# The block design comes from vivado/build.tcl (sim=1: same settings, no ILA, own project build/vivado/patrm_gray_sim).
# This script only generates the xsim scripts; scripts/sim_system.py runs them. Normally started by that script.
# By hand, from build/vivado:  vivado -mode batch -source ../../vivado/sim_system.tcl
#
# D17: tb/tb_system.v and rtl/ are plain Verilog. Only AMD's own IP (the VIP) is SystemVerilog inside.

set here [file dirname [file normalize [info script]]]
set argv {sim 1}
set argc 2
source [file join $here build.tcl]

set bd_file [get_files system.bd]
generate_target simulation $bd_file
set wrapper [make_wrapper -files $bd_file -top]
add_files -norecurse [list $wrapper]
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

set simset [get_filesets sim_1]
set tb [file join $repo tb tb_system.v]
add_files -fileset $simset -norecurse [list $tb]
set tb_type [get_property FILE_TYPE [get_files -of_objects $simset $tb]]
if {$tb_type ne "Verilog"} { error "CHECK FAILED D17: tb_system.v has file type $tb_type" }
set_property include_dirs [list [file join $repo rtl]] $simset
set_property top tb_system $simset
set_property top_lib xil_defaultlib $simset
set_property target_simulator XSim [current_project]
set_property -name xsim.elaborate.debug_level -value off -objects $simset
update_compile_order -fileset sim_1

launch_simulation -simset sim_1 -mode behavioral -scripts_only
puts "SIM_SYSTEM_DIR [file normalize [file join $prj $name.sim sim_1 behav xsim]]"
puts "SIM_SYSTEM: scripts generated"
