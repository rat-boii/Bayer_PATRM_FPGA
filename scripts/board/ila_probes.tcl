# Splits the five ILA bus probes of the debug build back into named signals (user-defined probes).
#
# Vivado hardware manager, Tcl console, after programming patrm_gray_ila.bit with patrm_gray_ila.ltx:
#   source scripts/board/ila_probes.tcl
# With no ILA connected (for example in batch mode) it only prints the commands it would run.
# Bit fields: vivado/ila_map.tcl and the README section "Debug build".

set repo [file dirname [file dirname [file dirname [file normalize [info script]]]]]
source [file join $repo vivado ila_map.tcl]
catch { load_features labtools }

set ilas {}
catch { set ilas [get_hw_ilas -quiet] }
set dry [expr {[llength $ilas] == 0}]
if {!$dry && [llength $ilas] != 1} { error "ila_probes: expected one ILA core, found: $ilas" }
if {$dry} { puts "ila_probes: no ILA core connected, printing the commands only" }

set made 0
foreach entry $::ila_probes {
    lassign $entry probe text fields
    set low 0
    foreach f $fields {
        lassign $f name port w
        set bits {}
        for {set i [expr {$low + $w - 1}]} {$i >= $low} {incr i -1} { lappend bits "$probe\[$i\]" }
        set map [join $bits " "]                           ;# plain text, as in the create_hw_probe help
        if {$dry} {
            puts "WOULD RUN: create_hw_probe -map {$map} $name <ila>"
        } else {
            create_hw_probe -map $map $name [lindex $ilas 0]
        }
        incr low $w
        incr made
    }
}
puts "ila_probes: [expr {$dry ? {would create} : {created}}] $made user-defined probes"
