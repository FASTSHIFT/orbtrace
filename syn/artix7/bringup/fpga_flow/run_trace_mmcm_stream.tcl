# Build trace_mmcm_stream_top: CONTINUOUS streaming MMCM parallel trace
# (proposal 22 §8). Output: trace_mmcm_stream.bit
#   cd build && MULT=40 DIVID=40 TRACE_PERIOD=47.6 PHASE=90.0 \
#       vivado -mode batch -source ../fpga_flow/run_trace_mmcm_stream.tcl
#
# Same MMCM front-end as run_trace_mmcm.tcl, but the one-shot BRAM is replaced
# by a CDC AsyncFIFO -> fpga_core_net self-TX -> continuous UDP to :5555.
# Verified golden recipes (proposal 22 §7.5):
#   21M (HCLK/4): MULT=40 DIVID=40 TRACE_PERIOD=47.6 PHASE=90.0   (default)
#   84M (HCLK/1): MULT=10 DIVID=10 TRACE_PERIOD=11.9 PHASE=112.5

set part      xc7a35tfgg484-2
set bdir      [file dirname [info script]]
set bringup   [file normalize [file join $bdir ..]]
set repo_root [file normalize [file join $bdir .. .. .. ..]]
set ex        $repo_root/syn/external/verilog-ethernet/example/NexysVideo/fpga
set rtl       $repo_root/syn/artix7/rtl

read_verilog $rtl/trace_capture_mmcm.v
read_verilog $rtl/trace_capture_direct.v
read_verilog $bringup/rtl/fpga_core_net.v
read_verilog $bringup/rtl/trace_mmcm_stream_top.v
read_verilog $bringup/rtl/dbg_regfile.v
read_verilog $bringup/rtl/led_status.v
read_verilog $bringup/rtl/frame_to_bytes.v
read_verilog $repo_root/verilog/traceIF.v
read_verilog $repo_root/syn/artix7/tpiu_demux.v

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
set tperiod 47.6
if {[info exists ::env(TRACE_PERIOD)]} { set tperiod $::env(TRACE_PERIOD) }
set phase 90.0
if {[info exists ::env(PHASE)]} { set phase $::env(PHASE) }
set width 4
if {[info exists ::env(WIDTH)]} { set width $::env(WIDTH) }
set bwtest 0
if {[info exists ::env(BANDWIDTH_TEST)]} { set bwtest $::env(BANDWIDTH_TEST) }
puts "============ STREAM MULT=$mult DIVID=$divid TRACE_PERIOD=$tperiod PHASE=$phase WIDTH=$width BWTEST=$bwtest ============"
set direct 0
if {[info exists ::env(DIRECT)]} { set direct $::env(DIRECT) }
synth_design -top trace_mmcm_stream_top -part $part \
    -generic MULT=$mult -generic DIVID=$divid -generic CLKIN_PERIOD=$tperiod \
    -generic PHASE=$phase -generic WIDTH=$width \
    -generic BANDWIDTH_TEST=$bwtest -generic DIRECT=$direct
create_clock -period $tperiod -name trace_clk_in [get_ports trace_clk_in]
if {$direct} {
    set_clock_groups -asynchronous \
        -group [get_clocks sys_clk_50] \
        -group [get_clocks trace_clk_in] \
        -group [get_clocks phy_rx_clk] \
        -group [get_clocks -of_objects [get_pins u_sysmmcm/CLKOUT0]] \
        -group [get_clocks -of_objects [get_pins u_sysmmcm/CLKOUT1]] \
        -group [get_clocks -of_objects [get_pins u_sysmmcm/CLKOUT3]]
} else {
    set_clock_groups -asynchronous \
        -group [get_clocks sys_clk_50] \
        -group [get_clocks trace_clk_in] \
        -group [get_clocks phy_rx_clk] \
        -group [get_clocks -of_objects [get_pins u_sysmmcm/CLKOUT0]] \
        -group [get_clocks -of_objects [get_pins u_sysmmcm/CLKOUT1]] \
        -group [get_clocks -of_objects [get_pins u_sysmmcm/CLKOUT3]] \
        -group [get_clocks -of_objects [get_pins u_cap/u_mmcm/CLKOUT0]] \
        -group [get_clocks -of_objects [get_pins u_cap/u_mmcm/CLKOUT1]]
}
opt_design
place_design
route_design
report_timing_summary -no_detailed_paths -no_header
set outbit "trace_mmcm_stream.bit"
if {[info exists ::env(OUTBIT)]} { set outbit $::env(OUTBIT) }
write_bitstream -force $outbit
puts "============ TRACE MMCM STREAM BUILD DONE (MULT=$mult DIVID=$divid -> $outbit) ============"
