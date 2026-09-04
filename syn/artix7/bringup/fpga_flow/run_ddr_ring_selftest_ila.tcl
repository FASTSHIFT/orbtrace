# Build ddr_ring_selftest_top WITH an ILA core (r38 P0-4 on-board capture).
#
# The RTL signals are marked with (* mark_debug = "true" *) under an
# `ifdef ILA_DEBUG` gate — Vivado auto-inserts a debug hub + ILA connecting
# all marked nets. We drive the ILA sample clock from clk125 (where the byte
# lands on the wire).
#
#   cd build && vivado -mode batch -source ../fpga_flow/run_ddr_ring_selftest_ila.tcl
#
# Output: ddr_ring_selftest_ila.bit + .ltx (debug-nets metadata for hw_server).
#
# ILA marked signals (in clk125 domain):
#   pkt_tdata[7:0]        — the byte going onto the wire
#   pkt_tvalid            — payload valid
#   pkt_tready            — downstream ready
#   pkt_active            — packet in flight
#   pos[15:0]             — byte offset within packet (0..PKT-1)
#   latched_seq[31:0]     — packet index we're building
#   pkt_seq[31:0]         — local packet counter
#   stream_tdata[7:0]     — byte pulled from streamer
#   stream_tvalid         — streamer output valid
#   stream_seq[31:0]      — streamer packet seq (monotonic word-index/PKT_WORDS)
#   stream_rtx            — retransmit tag (should be 0 in S1b)
#   src_fixed_125         — CSR bit selecting 0x42 mode
#   ring_overrun          — sticky writer-lapped-streamer flag
#   nack_busy / nack_fail — NACK path status (should be 0 in S1b)
#
# On the board:
#   1. Program the .bit
#   2. Open Vivado HW Manager, connect to xc7a35t
#   3. Load the .ltx alongside the .bit (Vivado picks it up automatically
#      if in the same directory)
#   4. In Debug Probes pane: set trigger to
#        src_fixed_125 == 1 && pkt_active == 1 && pkt_tready == 1 &&
#        pos > 3 (skip header) && pkt_tvalid == 1 && pkt_tdata != 0x42
#      Only fires on the wire-side bad byte while in 0x42 mode.
#   5. Arm, wait for a bad byte, inspect waveform.

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
read_verilog $bringup/rtl/la_ddr_ring_streamer.v
read_verilog $bringup/rtl/fpga_core_net.v
read_verilog $bringup/rtl/dbg_regfile.v
read_verilog $bringup/rtl/ddr_ring_selftest_top.v

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

read_xdc $bringup/rtl/trace_ddr_selftest.xdc

set build_id [clock seconds]
puts "BUILD_ID = $build_id ([clock format $build_id])"
# Synthesize with the ILA_DEBUG define, which turns on the mark_debug attrs.
synth_design -top ddr_ring_selftest_top -part $part -verilog_define ILA_DEBUG \
    -generic BUILD_ID=$build_id

# ---- Build the ILA core explicitly from mark_debug nets. -------------
# Vivado does NOT auto-create the ILA from `mark_debug` alone — it only marks
# the nets as "keep visible for debug". We create an ila_v6 core here and
# connect every marked net to a probe port.
#
# List (name -> width) matches the mark_debug attributes in
# ddr_ring_selftest_top.v.
puts "==== ILA core setup ===="
create_debug_core u_ila_wire ila
set_property C_DATA_DEPTH 4096 [get_debug_cores u_ila_wire]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_wire]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_wire]
set_property C_ADV_TRIGGER true [get_debug_cores u_ila_wire]
set_property C_INPUT_PIPE_STAGES 1 [get_debug_cores u_ila_wire]
set_property C_EN_STRG_QUAL true [get_debug_cores u_ila_wire]
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_wire]
set_property ALL_PROBE_SAME_MU_CNT 4 [get_debug_cores u_ila_wire]

# Sample clock: clk125 (the packetiser domain — where the byte lands on wire).
set_property port_width 1 [get_debug_ports u_ila_wire/clk]
connect_debug_port u_ila_wire/clk [get_nets clk125]

# Helper: fetch nets by pattern, wire them as probe N of width W.
proc probe_of {core idx width nets} {
    if {[llength $nets] == 0} {
        puts "WARN probe $idx : no nets matched, skipping"
        return
    }
    if {[llength $nets] != $width} {
        puts "WARN probe $idx : expected width=$width but got [llength $nets]"
    }
    if {$idx > 0} { create_debug_port $core probe }
    set port [get_debug_ports $core/probe$idx]
    set_property port_width $width $port
    set_property PROBE_TYPE DATA_AND_TRIGGER $port
    connect_debug_port $port $nets
}

# probe0 pkt_tdata[7:0] — byte on wire
probe_of u_ila_wire 0 8 [get_nets pkt_tdata[*]]
# probe1 pkt_tvalid
probe_of u_ila_wire 1 1 [get_nets pkt_tvalid]
# probe2 pkt_tready
probe_of u_ila_wire 2 1 [get_nets pkt_tready]
# probe3 pkt_active
probe_of u_ila_wire 3 1 [get_nets pkt_active]
# probe4 pos[15:0]
probe_of u_ila_wire 4 16 [get_nets pos[*]]
# probe5 latched_seq[31:0]
probe_of u_ila_wire 5 32 [get_nets latched_seq[*]]
# probe6 pkt_seq[31:0]
probe_of u_ila_wire 6 32 [get_nets pkt_seq[*]]
# probe7 stream_tdata[7:0]
probe_of u_ila_wire 7 8 [get_nets stream_tdata[*]]
# probe8 stream_tvalid
probe_of u_ila_wire 8 1 [get_nets stream_tvalid]
# probe9 stream_seq[31:0]
probe_of u_ila_wire 9 32 [get_nets stream_seq[*]]
# probe10 stream_rtx
probe_of u_ila_wire 10 1 [get_nets stream_rtx]
# probe11 src_fixed_125
probe_of u_ila_wire 11 1 [get_nets src_fixed_125]
# probe12 ring_overrun
probe_of u_ila_wire 12 1 [get_nets ring_overrun]
# probe13 nack_busy
probe_of u_ila_wire 13 1 [get_nets nack_busy]
# probe14 nack_fail
probe_of u_ila_wire 14 1 [get_nets nack_fail]

report_debug_core

# ---- dbg_hub connected to clk125 (matches the ILA sample clock) ----
set dbg_hub [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false $dbg_hub
set_property C_USER_SCAN_CHAIN 1 $dbg_hub
connect_debug_port dbg_hub/clk [get_nets clk125]

puts "==== CLOCKS ===="
foreach c [get_clocks] { puts "  clock: $c  period=[get_property PERIOD $c]  src=[get_property SOURCE_PINS $c]" }
set g_sys [get_clocks {clk125_u clk125_90_u clk100_u}]
set g_mig [get_clocks -include_generated_clocks -of_objects [get_pins u_clock/inst/*/CLKOUT0]]
set_clock_groups -asynchronous \
    -group [get_clocks sys_clk_50] \
    -group [get_clocks phy_rx_clk] \
    -group $g_sys \
    -group $g_mig
set_false_path -from [get_pins rst_sync_reg[3]/C] \
               -to [get_pins -hier -filter {NAME =~ *rgmii_phy_if_inst*rx_rst_reg_reg*/PRE}]

opt_design
place_design
route_design
report_timing_summary -no_detailed_paths -no_header
puts "==== WORST SETUP PATHS ===="
report_timing -setup -max_paths 8 -sort_by slack -no_header
puts "==== UTILIZATION ===="
report_utilization

set outbit "ddr_ring_selftest_ila.bit"
if {[info exists ::env(OUTBIT)]} { set outbit $::env(OUTBIT) }
write_bitstream -force $outbit
write_debug_probes -force [file rootname $outbit].ltx
puts "============ DDR RING SELFTEST + ILA BUILD DONE -> $outbit ============"
