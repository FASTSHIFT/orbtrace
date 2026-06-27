# Build trace_mmcm_top: mid-speed parallel trace via MMCM 90-deg phase-shift
# sampling (proposal 22 §7.1). Output: trace_mmcm.bit
#   cd build && MULT=40 DIVID=40 vivado -mode batch -source ../fpga_flow/run_trace_mmcm.tcl
# MULT/DIVID set the trace-clk MMCM (VCO=TRACECLK*MULT must be 600-1200MHz).
# For TRACECLK 21MHz: MULT=40 DIVID=40 (VCO=840MHz).

set part      xc7a35tfgg484-2
set bdir      [file dirname [info script]]
set bringup   [file normalize [file join $bdir ..]]
set repo_root [file normalize [file join $bdir .. .. .. ..]]
set ex        $repo_root/syn/external/verilog-ethernet/example/NexysVideo/fpga
set rtl       $repo_root/syn/artix7/rtl

read_verilog $rtl/trace_capture_mmcm.v
read_verilog $bringup/rtl/fpga_core_net.v
read_verilog $bringup/rtl/trace_mmcm_top.v

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

read_xdc $bringup/rtl/trace_mmcm.xdc

set mult 40
if {[info exists ::env(MULT)]} { set mult $::env(MULT) }
set divid 40
if {[info exists ::env(DIVID)]} { set divid $::env(DIVID) }
puts "============ MULT=$mult DIVID=$divid ============"
synth_design -top trace_mmcm_top -part $part -generic MULT=$mult -generic DIVID=$divid
opt_design
place_design
route_design
report_timing_summary -no_detailed_paths -no_header
write_bitstream -force trace_mmcm.bit
puts "============ TRACE MMCM BUILD DONE (MULT=$mult DIVID=$divid) ============"
