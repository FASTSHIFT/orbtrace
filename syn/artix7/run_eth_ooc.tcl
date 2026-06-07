# Stage-2 T1: OOC synthesis of the gigabit Ethernet stack on Artix-7.
#
# Source: alexforencich/verilog-ethernet NexysVideo example (Artix-7 + RGMII).
# We synthesize fpga_core (MAC+UDP/IP/ARP + application), excluding the board
# I/O wrapper, to get the real "network stack" footprint independent of
# package/board pinout.

set part xc7a35tfgg484-2
set veth [file normalize [file join [file dirname [info script]] .. .. syn external verilog-ethernet]]
set ex   $veth/example/NexysVideo/fpga

# Source list (mirrors NexysVideo example/Makefile SYN_FILES, minus rtl/fpga.v
# which is the IOB wrapper we don't want for OOC numbers).
set sources {
    rtl/fpga_core.v
    rtl/debounce_switch.v
    rtl/sync_signal.v
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
}
foreach s $sources { read_verilog $ex/$s }

synth_design -top fpga_core -part $part -mode out_of_context

puts "============ UTILIZATION: fpga_core (gigabit Ethernet stack) ============"
report_utilization
