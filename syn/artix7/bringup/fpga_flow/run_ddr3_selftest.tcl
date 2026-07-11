# Build ddr3_selftest_top: proposal 32 P1 — DDR3 datapath self-loop test.
# Output: ddr3_selftest.bit
#
#   cd build && vivado -mode batch -source ../fpga_flow/run_ddr3_selftest.tcl
#
# Reuses the vendor A7-Lite MIG IP (mig_ddr3.xci) + clock IP (clock.xci) +
# the vendor DDR3 abstraction layer (ddr3_ctrl/wr/rd/arbit). The MIG IP carries
# its own DDR3 pin XDC internally; ddr3_selftest.xdc only pins clk/rst/led.

set part      xc7a35tfgg484-2
set bdir      [file dirname [info script]]
set bringup   [file normalize [file join $bdir ..]]
set rtl       $bringup/rtl
set ipdir     $rtl/ddr3/ip

create_project -in_memory -part $part

# ---- IP: MIG DDR3 controller + clocking wizard (vendor .xci) ----
read_ip $ipdir/mig_ddr3/mig_ddr3.xci
read_ip $ipdir/clock/clock.xci
generate_target all [get_ips]
synth_ip [get_ips]

# ---- RTL ----
read_verilog $rtl/ddr3/ddr3_ctrl.v
read_verilog $rtl/ddr3/ddr3_wr_ctrl.v
read_verilog $rtl/ddr3/ddr3_rd_ctrl.v
read_verilog $rtl/ddr3/ddr3_arbit.v
read_verilog $rtl/ddr3_selftest_top.v

read_xdc $rtl/ddr3_selftest.xdc

synth_design -top ddr3_selftest_top -part $part
opt_design
place_design
route_design
report_timing_summary -no_detailed_paths -no_header
report_utilization -hierarchical
set outbit "ddr3_selftest.bit"
if {[info exists ::env(OUTBIT)]} { set outbit $::env(OUTBIT) }
write_bitstream -force $outbit
puts "============ DDR3 SELFTEST BUILD DONE -> $outbit ============"
