# Build trace_pin_la_top: raw 5-pin logic analyzer (proposal 32 P2b, pin-level).
# Output: trace_pin_la.bit
#
#   cd build && vivado -mode batch -source ../fpga_flow/run_trace_pin_la.tcl
#
# 5 TRACE pins sampled at 200 MSPS -> DDR3 ring, + Ethernet :5001 status +
# armed readback on :5556 (STREAM_DEST_PORT). DDR3 needs a COLD BOOT to calib.

set part      xc7a35tfgg484-2
set bdir      [file dirname [info script]]
set bringup   [file normalize [file join $bdir ..]]
set repo_root [file normalize [file join $bdir .. .. .. ..]]
set ex        $repo_root/syn/external/verilog-ethernet/example/NexysVideo/fpga
set rtl       $repo_root/syn/artix7/rtl
set ipdir     $bringup/rtl/ddr3/ip

create_project -in_memory -part $part

read_ip $ipdir/mig_ddr3/mig_ddr3.xci
read_ip $ipdir/clock/clock.xci
generate_target all [get_ips]
synth_ip [get_ips]

read_verilog $bringup/rtl/ddr3/ddr3_ctrl.v
read_verilog $bringup/rtl/ddr3/ddr3_wr_ctrl.v
read_verilog $bringup/rtl/ddr3/ddr3_rd_ctrl.v
read_verilog $bringup/rtl/ddr3/ddr3_arbit.v
read_verilog $bringup/rtl/la_ddr_writer.v
read_verilog $bringup/rtl/la_ddr_reader.v
read_verilog $bringup/rtl/fpga_core_net.v
read_verilog $bringup/rtl/trace_pin_la_top.v

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

read_xdc $bringup/rtl/trace_ddr_blackbox.xdc

synth_design -top trace_pin_la_top -part $part

# Same clock groups as blackbox (async: sys_clk / phy_rx / trace_clk / sys 125s / mig)
set g_sys [get_clocks {clk125_u clk125_90_u clk100_u}]
set g_mig [get_clocks -include_generated_clocks -of_objects [get_pins u_clock/inst/*/CLKOUT0]]
set_clock_groups -asynchronous \
    -group [get_clocks sys_clk_50] \
    -group [get_clocks phy_rx_clk] \
    -group [get_clocks trace_clk_in] \
    -group $g_sys \
    -group $g_mig

opt_design
place_design
route_design
report_timing_summary -no_detailed_paths -no_header
set outbit "trace_pin_la.bit"
if {[info exists ::env(OUTBIT)]} { set outbit $::env(OUTBIT) }
write_bitstream -force $outbit
puts "============ TRACE PIN LA BUILD DONE -> $outbit ============"
