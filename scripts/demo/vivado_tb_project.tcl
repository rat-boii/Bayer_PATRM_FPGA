# Single-image testbench as an ordinary Vivado project, for the review demo (Vivado IDE, not the scripted xsim run).
#
#   python scripts/demo/make_demo_case.py [--transform rot37]      once: the test case in data/vectors_demo/
#   cd build/vivado
#   vivado -mode gui -source ../../scripts/demo/vivado_tb_project.tcl
#
# Creates build/vivado/patrm_tb_demo/patrm_tb_demo.xpr (rebuilt each time; build/ is not in git): the engine RTL (rtl/)
# as design sources with top patrm_top, tb/tb_patrm_top.v + tb/axi_mem.v as simulation sources with top tb_patrm_top,
# the +VEC_DIR and +SINGLE_CASE plusargs in the simulation settings, then Run Behavioral Simulation, the five wave
# groups of scripts/demo/demo_wave.tcl and run all. The Tcl console ends with TEST PASS; the wave window then shows the
# whole frame (Zoom Fit). Afterwards the project can be reopened and simulated from the Flow Navigator as usual.
# Same RTL, testbench and checks as python scripts/demo/run_demo_sim.py; Verilog-2001 only (D17).

set repo [file normalize [file join [file dirname [file normalize [info script]]] .. ..]]
set prj  [file join $repo build vivado patrm_tb_demo]
set vec  [file join $repo data vectors_demo]
if {![file exists [file join $vec patrm_top cases.txt]]} {
    error "no demo case: run python scripts/demo/make_demo_case.py first"
}

create_project patrm_tb_demo $prj -part xc7z020clg484-1 -force

# design sources: the engine, top patrm_top (same list as tb/patrm_top.f)
set rtl {axil_regs ctrl_fsm bayer_seq block_planner coord_gen prefetch_ctrl axi_rd_master line_buf pixel_fetch
         bilinear_interp out_fifo axi_wr_master bayer_geometry bayer_store bayer_merge bayer_lanes patrm_top}
set srcs {}
foreach n $rtl { lappend srcs [file join $repo rtl $n.v] }
add_files -norecurse $srcs
add_files -norecurse [list [file join $repo rtl patrm_regs.vh]]
set_property include_dirs [list [file join $repo rtl]] [get_filesets sources_1]
set_property top patrm_top [get_filesets sources_1]

# simulation sources: the self-checking testbench and its AXI memory model
add_files -fileset sim_1 -norecurse [list [file join $repo tb axi_mem.v] [file join $repo tb tb_patrm_top.v]]
set_property include_dirs [list [file join $repo rtl]] [get_filesets sim_1]
set_property top tb_patrm_top [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property -name {xsim.simulate.xsim.more_options} \
    -value "-testplusarg VEC_DIR=$vec -testplusarg SINGLE_CASE=1" -objects [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {0ns} -objects [get_filesets sim_1]
set_property -name {xsim.simulate.log_all_signals} -value {true} -objects [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

launch_simulation -simset sim_1 -mode behavioral
source [file join $repo scripts demo demo_wave.tcl]
