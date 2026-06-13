# JTAG volatile download of eyescan.bit (Stage-4 V1) to the A7-Lite.
#   cd build && vivado -mode batch -source ../fpga_flow/program_eyescan.tcl
set BITFILE "eyescan.bit"

open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag

set tgt ""
set tries 0
while {$tgt eq "" && $tries < 20} {
    catch {refresh_hw_server -force_poll}
    foreach t [get_hw_targets -quiet] {
        if {$t ne ""} { set tgt $t; break }
    }
    if {$tgt eq ""} { puts "  waiting for JTAG target... ($tries)"; after 1500; incr tries }
}
if {$tgt eq ""} { puts "ERROR: no non-empty JTAG target"; exit 1 }

current_hw_target $tgt
open_hw_target $tgt
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PROGRAM.FILE $BITFILE $dev
program_hw_devices $dev
puts "============ PROGRAMMED $BITFILE -> $dev ============"
close_hw_target
disconnect_hw_server
