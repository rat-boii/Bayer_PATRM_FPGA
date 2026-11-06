# Step 0.1: confirm Vivado sees the ZedBoard part and list ZedBoard board files.
# Run from build/ so .jou/.log files stay out of the repo root:
#   cd build
#   vivado -mode batch -source ../vivado/check_part.tcl

set PART xc7z020clg484-1

puts "VIVADO VERSION: [version -short]"

set parts [get_parts -quiet $PART]
if {[llength $parts] == 0} {
    puts "PART FAIL: $PART not found (Zynq-7000 device support not installed?)"
    exit 1
}
set p [lindex $parts 0]
puts "PART PASS: $p (family [get_property FAMILY $p], package [get_property PACKAGE $p], speed [get_property SPEED $p])"

set boards [get_board_parts -quiet *zed*]
if {[llength $boards] == 0} {
    puts "BOARD INFO: no board parts matching *zed* are installed"
} else {
    foreach b $boards {
        puts "BOARD FOUND: $b"
    }
}
puts "BOARD REPO PATHS: [get_param board.repoPaths]"
exit 0
