# Generic JTAG volatile download of a .bit to the A7-Lite over the on-board
# FT232H (USB 0403:6014). Lost on power cycle. Bitfile from env BITFILE.
#
#   cd build && BITFILE=trace_orbflow.bit vivado -mode batch -source ../fpga_flow/program_bit.tcl
#
# Run from the directory containing the .bit.

set BITFILE "trace_orbflow.bit"
if {[info exists ::env(BITFILE)]} { set BITFILE $::env(BITFILE) }
if {![file exists $BITFILE]} { puts "ERROR: $BITFILE not found in [pwd]"; exit 1 }

open_hw_manager

# Connect to JTAG hw_server only. Do NOT auto-launch cs_server: under
# FT232H + VMware USB passthrough, cs_server and hw_server contend for the
# single FTDI channel and the target shows up "locked".
connect_hw_server -url localhost:3121 -allow_non_jtag

set tgt ""
set tries 0
while {$tgt eq "" && $tries < 20} {
    catch {refresh_hw_server -force_poll}
    foreach t [get_hw_targets -quiet] {
        if {$t ne ""} { set tgt $t; break }
    }
    if {$tgt eq ""} {
        puts "  waiting for JTAG target... ($tries)"
        after 1500
        incr tries
    }
}

puts "============ HW TARGETS ============"
foreach t [get_hw_targets -quiet] { puts "  target: '$t'" }
puts "  chosen: '$tgt'"
if {$tgt eq ""} { puts "ERROR: no non-empty JTAG target"; exit 1 }

current_hw_target $tgt
open_hw_target $tgt

set dev [lindex [get_hw_devices] 0]
puts "============ HW DEVICE: $dev ============"
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set_property PROGRAM.FILE $BITFILE $dev
program_hw_devices $dev
puts "============ PROGRAMMED $BITFILE -> $dev ============"

close_hw_target
disconnect_hw_server
