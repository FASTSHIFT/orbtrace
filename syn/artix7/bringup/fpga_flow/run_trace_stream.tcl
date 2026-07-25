# Build the Stage-4 V3 trace-stream bitstream (trace_stream_top) for A7-Lite.
#   source $XILINX_VIVADO/settings64.sh
#   cd build && vivado -mode batch -source ../fpga_flow/run_trace_stream.tcl
# Output: trace_stream.bit
#
# Fixes IDELAY tap (default 28, V2 eye centre) and streams decoded trace
# frames out over UDP :5001.

set part      xc7a35tfgg484-2
set bdir      [file dirname [info script]]
set bringup   [file normalize [file join $bdir ..]]
set repo_root [file normalize [file join $bdir .. .. .. ..]]
set ex        $repo_root/syn/external/verilog-ethernet/example/NexysVideo/fpga
set rtl       $repo_root/syn/artix7/rtl

read_verilog $rtl/trace_capture_a7.v
read_verilog $repo_root/verilog/traceIF.v
read_verilog $bringup/rtl/fpga_core_net.v
read_verilog $bringup/rtl/trace_stream_top.v

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

read_xdc $bringup/rtl/trace_stream.xdc

set tap 28
if {[info exists ::env(TAP)]} { set tap $::env(TAP) }
set capraw 0
if {[info exists ::env(CAP_RAW)]} { set capraw $::env(CAP_RAW) }
set eye 4
if {[info exists ::env(EYE)]} { set eye $::env(EYE) }
set selftest 0
if {[info exists ::env(SELFTEST)]} { set selftest $::env(SELFTEST) }
set twidth 4
if {[info exists ::env(TRACE_WIDTH)]} { set twidth $::env(TRACE_WIDTH) }
set capmethod "OVERSAMPLE"
if {[info exists ::env(CAP_METHOD)]} { set capmethod $::env(CAP_METHOD) }
set stream 0
if {[info exists ::env(STREAM)]} { set stream $::env(STREAM) }
puts "============ TAP = $tap  CAP_RAW = $capraw  EYE = $eye  SELFTEST = $selftest  TRACE_WIDTH = $twidth  CAP_METHOD = $capmethod  STREAM = $stream ============"
synth_design -top trace_stream_top -part $part \
    -generic TAP=$tap -generic CAP_RAW=$capraw -generic EYE=$eye \
    -generic SELFTEST=$selftest -generic TRACE_WIDTH=$twidth \
    -generic CAP_METHOD=$capmethod -generic STREAM=$stream
opt_design
place_design
route_design
report_timing_summary -no_detailed_paths -no_header
set outbit "trace_stream.bit"
if {[info exists ::env(OUTBIT)]} { set outbit $::env(OUTBIT) }
write_bitstream -force $outbit
puts "============ TRACE STREAM BUILD DONE (tap=$tap method=$capmethod) -> $outbit ============"
