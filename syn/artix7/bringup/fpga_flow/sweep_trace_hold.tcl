# sweep_trace_hold.tcl — in ONE vivado process, build the trace_ddr_stream
# design at several fixed data-IDELAY tap values and print the trace_clk_in
# hold WHS for each, so we can pick the tap that closes IDDR input hold from
# STA (deterministic judge, no hardware guessing).
#
# Run (background, log to file):
#   vivado -mode batch -source ../fpga_flow/sweep_trace_hold.tcl \
#          > build/idelay_sweep.log 2>&1
# Then grep the log for "HOLD-RESULT".
#
# Optional env TAPS="6 12 18 24 30" to override the swept values.

set part      xc7a35tfgg484-2
set bdir      [file dirname [info script]]
set bringup   [file normalize [file join $bdir ..]]
set repo_root [file normalize [file join $bdir .. .. .. ..]]
set ex        $repo_root/syn/external/verilog-ethernet/example/NexysVideo/fpga
set rtl       $repo_root/syn/artix7/rtl
set ipdir     $bringup/rtl/ddr3/ip

set taps {6 12 18 24 30}
if {[info exists ::env(TAPS)]} { set taps $::env(TAPS) }

# Build the IP once (shared across all runs in this process).
create_project -in_memory -part $part
read_ip $ipdir/mig_ddr3/mig_ddr3.xci
read_ip $ipdir/clock/clock.xci
generate_target all [get_ips]
synth_ip [get_ips]

set rtl_files [list \
    $rtl/trace_capture_a7.v \
    $bringup/rtl/ddr3/ddr3_ctrl.v $bringup/rtl/ddr3/ddr3_wr_ctrl.v \
    $bringup/rtl/ddr3/ddr3_rd_ctrl.v $bringup/rtl/ddr3/ddr3_arbit.v \
    $bringup/rtl/la_ddr_writer.v $bringup/rtl/la_ddr_ring_streamer.v \
    $bringup/rtl/fpga_core_net.v $bringup/rtl/dbg_regfile.v \
    $bringup/rtl/trace_ddr_stream_top.v]
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
} { lappend rtl_files $ex/$s }

foreach v $taps {
    puts "======== IDELAY_FIXED_VAL = $v : synth+impl ========"
    read_verilog $rtl_files
    read_xdc $bringup/rtl/trace_ddr_stream.xdc
    synth_design -top trace_ddr_stream_top -part $part \
        -generic USE_IDELAY=1 -generic CAP_IDELAY_FIXED=1 \
        -generic CAP_IDELAY_FIXED_VAL=$v
    opt_design
    place_design
    route_design
    set ph [get_timing_paths -hold \
            -from [get_clocks trace_clk_in] -to [get_clocks trace_clk_in]]
    set whs [get_property SLACK $ph]
    set ps [get_timing_paths -setup \
            -from [get_clocks trace_clk_in] -to [get_clocks trace_clk_in]]
    set wns [get_property SLACK $ps]
    puts "HOLD-RESULT tap=$v  WNS(setup)=$wns  WHS(hold)=$whs ns"
    close_design
}
puts "======== SWEEP DONE ========"
