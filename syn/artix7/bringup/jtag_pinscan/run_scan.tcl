# Pure-JTAG EXTEST connectivity sweep. NO bitstream involved.
# Reads vectors.txt (lines "drive,phase,hex"), shifts each as the EXTEST
# boundary DR, captures the readback, writes results.txt ("drive,phase,hex").
#
#   source $XILINX_VIVADO/settings64.sh
#   vivado -mode batch -source run_scan.tcl
#
# 7-series: IR len 6, EXTEST = 0x26, BR len = 812 bits (203 hex nibbles).

set BRLEN 812
set NIB   [expr {($BRLEN + 3) / 4}]

open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
set tgt ""
set tries 0
while {$tgt eq "" && $tries < 20} {
    catch {refresh_hw_server -force_poll}
    foreach t [get_hw_targets -quiet] { if {$t ne ""} { set tgt $t; break } }
    if {$tgt eq ""} { after 1000; incr tries }
}
if {$tgt eq ""} { puts "ERROR: no JTAG target"; exit 1 }
current_hw_target $tgt
open_hw_target $tgt -jtag_mode true
puts "JTAG target open: $tgt"

# A user design (from JTAG load or QSPI auto-boot) actively drives the GPIO
# pins and fights EXTEST. Clear the configuration first: pulse JPROGRAM via
# the JTAG instruction so CONFIG logic releases the IO, then run EXTEST
# before anything reconfigures. (We are in jtag_mode, so issue the raw
# config-reset opcode JPROGRAM=0x0b, then EXTEST=0x26.)
scan_ir_hw_jtag 6 -tdi 0b
after 200

# enter EXTEST so the boundary cells drive/sample the pins
scan_ir_hw_jtag 6 -tdi 26

set vf [open vectors.txt r]
set rf [open results.txt w]
set n 0
while {[gets $vf line] >= 0} {
    if {$line eq ""} continue
    lassign [split $line ,] drive phase hex
    # shift the DR; capture readback (state of pins from the PREVIOUS update,
    # so we shift each vector twice: once to apply, once to capture its effect)
    scan_dr_hw_jtag $BRLEN -tdi $hex
    set rb [scan_dr_hw_jtag $BRLEN -tdi $hex]
    puts $rf "$drive,$phase,$rb"
    incr n
}
close $vf
close $rf
puts "ran $n vectors -> results.txt"

# release all pins (re-enter SAMPLE so we stop driving), then close
scan_ir_hw_jtag 6 -tdi 01
close_hw_target
disconnect_hw_server
