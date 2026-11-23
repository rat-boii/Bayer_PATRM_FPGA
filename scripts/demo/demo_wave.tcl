# Waveforms for the single-image demo in the Vivado simulator (xsim GUI). Used by scripts/demo/run_demo_sim.py:
#   python scripts/sim.py --top tb_patrm_top -f tb/patrm_top.f --incdir rtl --plusarg VEC_DIR=data/vectors_demo \
#                         --gui --tclbatch scripts/demo/demo_wave.tcl
# Groups, top to bottom: 1 control (start, busy, done, interrupt), 2 coordinates from coord_gen (Q15.16 source row and
# column per output pixel), 3 the four neighbours into the bilinear interpolator and its output pixel, 4 AXI HP0 reads
# and HP1 writes to DDR, 5 the performance counters.

set top /tb_patrm_top/dut

set g [add_wave_group "1 Control"]
add_wave -into $g $top/aclk
add_wave -into $g $top/start_accept
add_wave -into $g $top/busy
add_wave -into $g $top/done_set
add_wave -into $g $top/interrupt

set g [add_wave_group "2 Coordinates (coord_gen, Q15.16)"]
add_wave -into $g $top/u_coord/pix_valid
add_wave -into $g -radix dec $top/u_coord/pix_X
add_wave -into $g -radix dec $top/u_coord/pix_Y
add_wave -into $g $top/u_coord/pix_last

set g [add_wave_group "3 Bilinear interpolation"]
add_wave -into $g $top/u_interp/ip_valid
add_wave -into $g -radix unsigned $top/u_interp/ip_xf
add_wave -into $g -radix unsigned $top/u_interp/ip_yf
add_wave -into $g -radix unsigned $top/u_interp/ip_r1
add_wave -into $g -radix unsigned $top/u_interp/ip_r2
add_wave -into $g -radix unsigned $top/u_interp/ip_r3
add_wave -into $g -radix unsigned $top/u_interp/ip_r4
add_wave -into $g $top/u_interp/op_valid
add_wave -into $g -radix unsigned $top/u_interp/op_d

set g [add_wave_group "4 AXI to DDR (HP0 read, HP1 write)"]
add_wave -into $g $top/m_axi_hp0_arvalid
add_wave -into $g $top/m_axi_hp0_arready
add_wave -into $g -radix hex $top/m_axi_hp0_araddr
add_wave -into $g -radix unsigned $top/m_axi_hp0_arlen
add_wave -into $g $top/m_axi_hp0_rvalid
add_wave -into $g $top/m_axi_hp1_awvalid
add_wave -into $g -radix hex $top/m_axi_hp1_awaddr
add_wave -into $g $top/m_axi_hp1_wvalid
add_wave -into $g $top/m_axi_hp1_wready
add_wave -into $g -radix hex $top/m_axi_hp1_wdata

set g [add_wave_group "5 Counters"]
add_wave -into $g -radix unsigned $top/cnt_cycles
add_wave -into $g -radix unsigned $top/cnt_bytes_rd
add_wave -into $g -radix unsigned $top/cnt_bytes_wr

run all
puts "DEMO: simulation finished; see the Tcl console for TEST PASS. In the wave window use Zoom Fit, then zoom in on a block."
