# Build the Stage-4 V1 eye-scan bitstream (eyescan_top) for A7-Lite.
#   source $XILINX_VIVADO/settings64.sh
#   cd build && vivado -mode batch -source ../run_eyescan.tcl
# Output: eyescan.bit

set part      xc7a35tfgg484-2
set bdir      [file dirname [info script]]
set repo_root [file normalize [file join $bdir .. .. ..]]
set ex        $repo_root/syn/external/verilog-ethernet/example/NexysVideo/fpga
set rtl       $repo_root/syn/artix7/rtl

# Stage-2 capture front-end (IDELAYE2 + IDDR + IDELAYCTRL)
read_verilog $rtl/trace_capture_a7.v

# V1 eye-scan engine + top + local eth core fork
read_verilog $bdir/trace_eyescan.v
read_verilog $bdir/fpga_core_net.v
read_verilog $bdir/eyescan_top.v

# verilog-ethernet MAC/IP/UDP library (from submodule)
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

read_xdc $bdir/eyescan.xdc

synth_design -top eyescan_top -part $part
opt_design
place_design
route_design

report_utilization
report_timing_summary -no_detailed_paths -no_header

write_bitstream -force eyescan.bit

puts "============ EYESCAN BUILD DONE ============"
puts " eyescan.bit -> JTAG load; jumper txclk_out/txd_out -> trace_*_in"
puts " Read eye table: python3 ../eyescan_read.py --ip 192.168.10.42"
