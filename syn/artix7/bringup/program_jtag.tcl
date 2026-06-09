# JTAG volatile download of blink.bit to the A7-Lite over the on-board
# FT232H (USB 0403:6014). Lights the 2 LEDs; lost on power cycle.
#
#   source /path/to/Vivado/2021.1/settings64.sh
#   vivado -mode batch -source syn/artix7/bringup/program_jtag.tcl
#
# Run from the directory containing blink.bit (or edit BITFILE below).

set BITFILE "blink.bit"

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
