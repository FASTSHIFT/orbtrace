# Build trace_ddr_selftest_top: proposal 32 P2a — DDR3 MIG + Ethernet :5001
# readout coexistence. Output: trace_ddr_selftest.bit
#
#   cd build && vivado -mode batch -source ../fpga_flow/run_trace_ddr_selftest.tcl
#
# Proves MIG (DDR3) coexists with the Ethernet stack + dbg_regfile, and surfaces
# DDR3 self-test status via the existing :5001 readout (fpga_health.py). No
# trace-capture tap yet (that's P2b). DDR3 needs a COLD BOOT to calibrate.

set part      xc7a35tfgg484-2
set bdir      [file dirname [info script]]
set bringup   [file normalize [file join $bdir ..]]
set repo_root [file normalize [file join $bdir .. .. .. ..]]
set ex        $repo_root/syn/external/verilog-ethernet/example/NexysVideo/fpga
set rtl       $repo_root/syn/artix7/rtl
set ipdir     $bringup/rtl/ddr3/ip

create_project -in_memory -part $part

# ---- IP: MIG DDR3 + clocking wizard (vendor .xci) ----
read_ip $ipdir/mig_ddr3/mig_ddr3.xci
read_ip $ipdir/clock/clock.xci
generate_target all [get_ips]
synth_ip [get_ips]

# ---- DDR3 abstraction layer + top ----
read_verilog $bringup/rtl/ddr3/ddr3_ctrl.v
read_verilog $bringup/rtl/ddr3/ddr3_wr_ctrl.v
read_verilog $bringup/rtl/ddr3/ddr3_rd_ctrl.v
read_verilog $bringup/rtl/ddr3/ddr3_arbit.v
read_verilog $bringup/rtl/fpga_core_net.v
read_verilog $bringup/rtl/dbg_regfile.v
read_verilog $bringup/rtl/trace_ddr_selftest_top.v

foreach s {
    lib/eth/rtl/iddr.v
    lib/eth/rtl/oddr.v
    lib/eth/rtl/ssio_ddr_in.v
    lib/eth/rtl/ssio_ddr_out.v
    lib/eth/rtl/rgmii_phy_if.v
    lib/eth/rtl/eth_mac_1g_rgmii_fifo.v
    lib/eth/rtl/eth_mac_1g_rgmii.v
    lib/eth/rtl/eth_mac_1g.v
    lib/eth/rtl/axis_gmii_rx.v
    lib/eth/rtl/axis_gmii_tx.v
    lib/eth/rtl/lfsr.v
    lib/eth/rtl/eth_axis_rx.v
    lib/eth/rtl/eth_axis_tx.v
    lib/eth/rtl/udp_complete.v
    lib/eth/rtl/udp_checksum_gen.v
    lib/eth/rtl/udp.v
    lib/eth/rtl/udp_ip_rx.v
    lib/eth/rtl/udp_ip_tx.v
    lib/eth/rtl/ip_complete.v
    lib/eth/rtl/ip.v
    lib/eth/rtl/ip_eth_rx.v
    lib/eth/rtl/ip_eth_tx.v
    lib/eth/rtl/ip_arb_mux.v
    lib/eth/rtl/arp.v
    lib/eth/rtl/arp_cache.v
    lib/eth/rtl/arp_eth_rx.v
    lib/eth/rtl/arp_eth_tx.v
    lib/eth/rtl/eth_arb_mux.v
    lib/eth/lib/axis/rtl/arbiter.v
    lib/eth/lib/axis/rtl/priority_encoder.v
    lib/eth/lib/axis/rtl/axis_fifo.v
    lib/eth/lib/axis/rtl/axis_async_fifo.v
    lib/eth/lib/axis/rtl/axis_async_fifo_adapter.v
    lib/eth/lib/axis/rtl/sync_reset.v
} {
    read_verilog $ex/$s
}

read_xdc $bringup/rtl/trace_ddr_selftest.xdc

synth_design -top trace_ddr_selftest_top -part $part
# Print all clocks so we can see the real names (sys MMCM, clock-IP 200M, MIG
# internal, phy) for debugging the async grouping.
puts "==== CLOCKS ===="
foreach c [get_clocks] { puts "  clock: $c  period=[get_property PERIOD $c]  src=[get_property SOURCE_PINS $c]" }
# Async clock groups by NET-driven clock objects (robust vs IP hierarchy names):
# every physically-unrelated clock domain in the design. The sys MMCM (125/100),
# the clock-IP 200M ref + all MIG-generated clocks, phy_rx_clk, and sys_clk_50
# are mutually asynchronous; all CDC crossings are 2-FF synced.
set g_sys [get_clocks {clk125_u clk125_90_u clk100_u}]
set g_mig [get_clocks -include_generated_clocks -of_objects [get_pins u_clock/inst/*/CLKOUT0]]
puts "g_sys=$g_sys"
puts "g_mig=$g_mig"
set_clock_groups -asynchronous \
    -group [get_clocks sys_clk_50] \
    -group [get_clocks phy_rx_clk] \
    -group $g_sys \
    -group $g_mig
# the sys_rst (clk100) fans into the RGMII MAC reset (phy_rx_clk domain) as an
# async reset; make it an explicit false path so the recovery/removal check
# between these async domains is not timed (it is a synchronised reset).
set_false_path -from [get_pins rst_sync_reg[3]/C] \
               -to [get_pins -hier -filter {NAME =~ *rgmii_phy_if_inst*rx_rst_reg_reg*/PRE}]
opt_design
place_design
route_design
report_timing_summary -no_detailed_paths -no_header
# dump the worst failing setup paths WITH their launch/capture clocks so we can
# see whether the violation is real logic or an unconstrained CDC.
puts "==== WORST SETUP PATHS ===="
report_timing -setup -max_paths 8 -sort_by slack -no_header
set outbit "trace_ddr_selftest.bit"
if {[info exists ::env(OUTBIT)]} { set outbit $::env(OUTBIT) }
write_bitstream -force $outbit
puts "============ TRACE DDR SELFTEST BUILD DONE -> $outbit ============"
