# Pure-JTAG SAMPLE sweep to find which FPGA pin carries a LIVE toggling signal
# (e.g. the SWO line the user plugged into an unknown IO). NO bitstream needed.
#
# Method: clear the configuration (JPROGRAM) so the FPGA releases all IO to
# inputs, enter SAMPLE/PRELOAD (IR=0x01), then capture the 812-bit boundary
# register many times. A pin driven by an external toggling signal (SWO @ 2MHz)
# will read both 0 and 1 across captures; idle/pulled pins stay constant.
# We write each capture as a hex line to sample_results.txt; sample_decode.py
# correlates the per-pin INPUT cell against pinmap.json.
#
#   source $XILINX_VIVADO/settings64.sh
#   vivado -mode batch -source run_sample.tcl
#
# 7-series: IR len 6, SAMPLE/PRELOAD = 0x01, boundary DR = 812 bits.

set BRLEN 812
set NCAP  64        ;# number of boundary captures

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

# Clear configuration so the user design stops driving the pins (JPROGRAM=0x0b),
# leaving every IO as a high-Z input that SAMPLE can observe.
scan_ir_hw_jtag 6 -tdi 0b
after 300

# SAMPLE/PRELOAD: capture pin states into the boundary register, non-invasive.
scan_ir_hw_jtag 6 -tdi 01

set rf [open sample_results.txt w]
for {set i 0} {$i < $NCAP} {incr i} {
    # capture-DR then shift out; -tdi pattern is don't-care for SAMPLE read
    set rb [scan_dr_hw_jtag $BRLEN -tdi [string repeat 0 203]]
    puts $rf $rb
    after 5
}
close $rf
puts "captured $NCAP boundary samples -> sample_results.txt"

close_hw_target
disconnect_hw_server
