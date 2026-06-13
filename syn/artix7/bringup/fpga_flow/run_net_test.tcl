# Build the network bring-up bitstream (net_test_top) for A7-Lite.
#   source $XILINX_VIVADO/settings64.sh
#   cd build && vivado -mode batch -source ../fpga_flow/run_net_test.tcl
# Output: net_test.bit / .mcs

set part      xc7a35tfgg484-2
set bdir      [file dirname [info script]]
set bringup   [file normalize [file join $bdir ..]]
set repo_root [file normalize [file join $bdir .. .. .. ..]]
set ex        $repo_root/syn/external/verilog-ethernet/example/NexysVideo/fpga

# verilog-ethernet stack (NexysVideo example). The example "core" (fpga_core)
# is forked locally as rtl/fpga_core_net.v with A7-Lite IP + RGMII TX
# timing fixes, so the submodule stays pristine. Everything else (MAC/IP/UDP
# library) is read straight from the submodule.
read_verilog $bringup/rtl/fpga_core_net.v
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

read_verilog $bringup/rtl/net_test_top.v
read_xdc      $bringup/rtl/net_test.xdc

synth_design -top net_test_top -part $part
opt_design
place_design
route_design

report_utilization
report_timing_summary -no_detailed_paths -no_header

write_bitstream -force net_test.bit
write_cfgmem -force -format mcs -interface spix4 -size 16 \
    -loadbit "up 0x0 net_test.bit" -file net_test.mcs

puts "============ NET TEST BUILD DONE ============"
puts " net_test.bit -> JTAG load; FPGA IP = 192.168.10.42"
puts " Test: ping 192.168.10.42 ; UDP echo on port 1234"
