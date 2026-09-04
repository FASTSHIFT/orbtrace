# Build ddr_ring_selftest_top: doc 21 S1b — DDR ring + writer + streamer
# datapath with an INTERNAL ramp source (STM32 not required). Output:
# ddr_ring_selftest.bit.
#
#   cd build && vivado -mode batch -source ../fpga_flow/run_ddr_ring_selftest.tcl
#
# On the board, use `scripts/ddr_ring_selftest_status.py` to read the writer/
# streamer status via :5001 (0xFF5x page) and `scripts/stream_grab` +
# `_rampcheck.py` to verify the received UDP payload is a clean monotone-mod-256
# ramp.

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

# ---- DDR3 abstraction layer + writer + streamer + top ----
read_verilog $bringup/rtl/ddr3/ddr3_ctrl.v
read_verilog $bringup/rtl/ddr3/ddr3_wr_ctrl.v
read_verilog $bringup/rtl/ddr3/ddr3_rd_ctrl.v
read_verilog $bringup/rtl/ddr3/ddr3_arbit.v
read_verilog $bringup/rtl/la_ddr_writer.v
read_verilog $bringup/rtl/la_ddr_ring_streamer.v
read_verilog $bringup/rtl/fpga_core_net.v
read_verilog $bringup/rtl/dbg_regfile.v
read_verilog $bringup/rtl/ddr_ring_selftest_top.v

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

# XDC: reuse trace_ddr_selftest constraints — identical pinout (no trace pins,
# no capture front-end).
read_xdc $bringup/rtl/trace_ddr_selftest.xdc

set build_id [clock seconds]
puts "BUILD_ID = $build_id ([clock format $build_id])"
synth_design -top ddr_ring_selftest_top -part $part -generic BUILD_ID=$build_id

puts "==== CLOCKS ===="
foreach c [get_clocks] { puts "  clock: $c  period=[get_property PERIOD $c]  src=[get_property SOURCE_PINS $c]" }
set g_sys [get_clocks {clk125_u clk125_90_u clk100_u}]
set g_mig [get_clocks -include_generated_clocks -of_objects [get_pins u_clock/inst/*/CLKOUT0]]
puts "g_sys=$g_sys"
puts "g_mig=$g_mig"
set_clock_groups -asynchronous \
    -group [get_clocks sys_clk_50] \
    -group [get_clocks phy_rx_clk] \
    -group $g_sys \
    -group $g_mig
set_false_path -from [get_pins rst_sync_reg[3]/C] \
               -to [get_pins -hier -filter {NAME =~ *rgmii_phy_if_inst*rx_rst_reg_reg*/PRE}]
opt_design
place_design
route_design
report_timing_summary -no_detailed_paths -no_header
puts "==== WORST SETUP PATHS ===="
report_timing -setup -max_paths 8 -sort_by slack -no_header
set outbit "ddr_ring_selftest.bit"
if {[info exists ::env(OUTBIT)]} { set outbit $::env(OUTBIT) }
write_bitstream -force $outbit
puts "============ DDR RING SELFTEST BUILD DONE -> $outbit ============"
