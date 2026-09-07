# probe_trace_hold.tcl — build the direct design and report the hold paths on
# the trace_data_in IDDR captures, to confirm which lanes/phases violate hold
# under the new source-synchronous input constraints.
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
read_verilog $rtl/trace_capture_a7.v
foreach f {ddr3/ddr3_ctrl ddr3/ddr3_wr_ctrl ddr3/ddr3_rd_ctrl ddr3/ddr3_arbit \
           la_ddr_writer la_ddr_ring_streamer fpga_core_net dbg_regfile \
           trace_ddr_stream_top} {
    read_verilog $bringup/rtl/$f.v
}
foreach s {
    lib/eth/rtl/iddr.v lib/eth/rtl/oddr.v lib/eth/rtl/ssio_ddr_in.v
    lib/eth/rtl/ssio_ddr_out.v lib/eth/rtl/rgmii_phy_if.v
    lib/eth/rtl/eth_mac_1g_rgmii_fifo.v lib/eth/rtl/eth_mac_1g_rgmii.v
    lib/eth/rtl/eth_mac_1g.v lib/eth/rtl/axis_gmii_rx.v lib/eth/rtl/axis_gmii_tx.v
    lib/eth/rtl/lfsr.v lib/eth/rtl/eth_axis_rx.v lib/eth/rtl/eth_axis_tx.v
    lib/eth/rtl/udp_complete.v lib/eth/rtl/udp_checksum_gen.v lib/eth/rtl/udp.v
    lib/eth/rtl/udp_ip_rx.v lib/eth/rtl/udp_ip_tx.v lib/eth/rtl/ip_complete.v
    lib/eth/rtl/ip.v lib/eth/rtl/ip_eth_rx.v lib/eth/rtl/ip_eth_tx.v
    lib/eth/rtl/ip_arb_mux.v lib/eth/rtl/arp.v lib/eth/rtl/arp_cache.v
    lib/eth/rtl/arp_eth_rx.v lib/eth/rtl/arp_eth_tx.v lib/eth/rtl/eth_arb_mux.v
    lib/eth/lib/axis/rtl/arbiter.v lib/eth/lib/axis/rtl/priority_encoder.v
    lib/eth/lib/axis/rtl/axis_fifo.v lib/eth/lib/axis/rtl/axis_async_fifo.v
    lib/eth/lib/axis/rtl/axis_async_fifo_adapter.v lib/eth/lib/axis/rtl/sync_reset.v
} { read_verilog $ex/$s }
read_xdc $bringup/rtl/trace_ddr_stream.xdc
set ui 0
if {[info exists ::env(USE_IDELAY)]} { set ui $::env(USE_IDELAY) }
synth_design -top trace_ddr_stream_top -part $part -generic USE_IDELAY=$ui
opt_design
place_design
route_design
puts "==== USE_IDELAY=$ui : TRACE-CLK HOLD PATHS (worst 8) ===="
report_timing -hold -max_paths 8 -nworst 8 -sort_by slack \
    -from [get_clocks trace_clk_in] -to [get_clocks trace_clk_in] -no_header
