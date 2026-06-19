# Build the minimal SWO-verification bitstream (swo_stream_top) for A7-Lite.
#   source $XILINX_VIVADO/settings64.sh
#   cd build && vivado -mode batch -source ../fpga_flow/run_swo_stream.tcl
# Output: swo_stream.bit
#
# Captures SWO bytes (PB3 NRZ on B22) into BRAM and serves them over UDP :5001
# with the same paged protocol as trace_stream, so trace_dump.py reads it as-is.

set part      xc7a35tfgg484-2
set bdir      [file dirname [info script]]
set bringup   [file normalize [file join $bdir ..]]
set repo_root [file normalize [file join $bdir .. .. .. ..]]
set ex        $repo_root/syn/external/verilog-ethernet/example/NexysVideo/fpga

read_verilog $bringup/rtl/swo_pulse_capture.v
read_verilog $bringup/rtl/swo_nrz_decode.v
read_verilog $bringup/rtl/swo_uart_decode.v
read_verilog $bringup/rtl/fpga_core_net.v
read_verilog $bringup/rtl/swo_stream_top.v

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

read_xdc $bringup/rtl/swo_stream.xdc

synth_design -top swo_stream_top -part $part
opt_design
place_design
route_design
report_timing_summary -no_detailed_paths -no_header
write_bitstream -force swo_stream.bit
puts "============ SWO STREAM BUILD DONE ============"
