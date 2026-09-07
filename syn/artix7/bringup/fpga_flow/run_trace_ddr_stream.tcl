# Build trace_ddr_stream_top: doc 21 S2 — real trace source through the DDR
# ring buffer end-to-end. Datapath:
#
#   STM32 ETM 4-bit -> trace_capture_a7 (IDDR, tap=2) -> cap_byte @ cap_valid
#     -> la_ddr_writer -> DDR3 ring (16 MB) -> la_ddr_ring_streamer
#     -> packetiser -> fpga_core_net STREAM -> UDP :5555
#
#   cd build && vivado -mode batch -source ../fpga_flow/run_trace_ddr_stream.tcl
#
# On the board:
#   1. Program the .bit
#   2. Ensure NIC .245 is up and net.core.rmem_max is 256 MB
#   3. stream_grab <iface> <secs> <out.bin> to capture the UDP stream
#   4. Feed the payload to cortrace-decode / etm_with_time.py
#
# CSRs (:5002):
#   0x0B=1  -> fixed 0x42 source (S1b diagnostic, bypasses trace)
#   0x09=1  -> ramp source (bypasses trace, exercises DDR ring only)
#   default -> real trace from trace_capture_a7
#
# Reuses the same XDC as trace_ddr_selftest_top / ddr_ring_selftest_top
# (identical pinout: RGMII + DDR3 + trace_clk_in D17 + trace_data_in E5..E8).

set part      xc7a35tfgg484-2
set bdir      [file dirname [info script]]
set bringup   [file normalize [file join $bdir ..]]
set repo_root [file normalize [file join $bdir .. .. .. ..]]
set ex        $repo_root/syn/external/verilog-ethernet/example/NexysVideo/fpga
set rtl       $repo_root/syn/artix7/rtl
set ipdir     $bringup/rtl/ddr3/ip

create_project -in_memory -part $part

# ---- IP: MIG DDR3 + clocking wizard ----
read_ip $ipdir/mig_ddr3/mig_ddr3.xci
read_ip $ipdir/clock/clock.xci
generate_target all [get_ips]
synth_ip [get_ips]

# ---- capture front-end (shared with trace_stream/trace_orbflow tops) ----
read_verilog $rtl/trace_capture_a7.v

# ---- DDR3 abstraction + writer + streamer + top ----
read_verilog $bringup/rtl/ddr3/ddr3_ctrl.v
read_verilog $bringup/rtl/ddr3/ddr3_wr_ctrl.v
read_verilog $bringup/rtl/ddr3/ddr3_rd_ctrl.v
read_verilog $bringup/rtl/ddr3/ddr3_arbit.v
read_verilog $bringup/rtl/la_ddr_writer.v
read_verilog $bringup/rtl/la_ddr_ring_streamer.v
read_verilog $bringup/rtl/fpga_core_net.v
read_verilog $bringup/rtl/dbg_regfile.v
read_verilog $bringup/rtl/trace_ddr_stream_top.v

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

# XDC: doc 21 S2 combined pinout (trace pins + RGMII + DDR3 via MIG).
read_xdc $bringup/rtl/trace_ddr_stream.xdc

set build_id [clock seconds]
puts "BUILD_ID = $build_id ([clock format $build_id])"
# USE_IDELAY=0 builds the upstream-faithful direct IBUF->IDDR capture (no
# per-lane IDELAYE2 deskew, frequency-independent). Set env USE_IDELAY=0 to
# build that variant; default 1 keeps the tap-sweep path.
set use_idelay 1
if {[info exists ::env(USE_IDELAY)]} { set use_idelay $::env(USE_IDELAY) }
puts "USE_IDELAY = $use_idelay"
synth_design -top trace_ddr_stream_top -part $part \
    -generic BUILD_ID=$build_id -generic USE_IDELAY=$use_idelay

puts "==== CLOCKS ===="
foreach c [get_clocks] { puts "  clock: $c  period=[get_property PERIOD $c]  src=[get_property SOURCE_PINS $c]" }
set g_sys [get_clocks {clk125_u clk125_90_u clk200_u clk100_u}]
set g_mig [get_clocks -include_generated_clocks -of_objects [get_pins u_clock/inst/*/CLKOUT0]]
puts "g_sys=$g_sys"
puts "g_mig=$g_mig"
set_clock_groups -asynchronous \
    -group [get_clocks sys_clk_50] \
    -group [get_clocks phy_rx_clk] \
    -group [get_clocks -include_generated_clocks trace_clk_in] \
    -group $g_sys \
    -group $g_mig
set_false_path -from [get_pins rst_sync_reg[3]/C] \
               -to [get_pins -hier -filter {NAME =~ *rgmii_phy_if_inst*rx_rst_reg_reg*/PRE}]

# CSR bits (clk125) into their clk200 first-stage synchroniser registers are
# quasi-static 2-FF crossings -- exclude from timing (else the clk125->clk200
# 1ns setup fails, e.g. src_fixed_125 -> src_fixed_s0 at WNS -0.854). The s0
# reg is the metastability catcher; the s0->200 second stage is timed normally.
set_false_path -to [get_cells -hier -filter {NAME =~ *selftest_s0_reg* || \
                                              NAME =~ *src_fixed_s0_reg*  || \
                                              NAME =~ *tap0_s0_reg*  || NAME =~ *tap1_s0_reg* || \
                                              NAME =~ *tap2_s0_reg*  || NAME =~ *tap3_s0_reg* || \
                                              NAME =~ *tapc_s0_reg*  || NAME =~ *tap_ld_s0_reg* || \
                                              NAME =~ *eye_s0_reg*}]

opt_design
place_design
route_design
report_timing_summary -no_detailed_paths -no_header
puts "==== WORST SETUP PATHS ===="
report_timing -setup -max_paths 8 -sort_by slack -no_header
puts "==== UTILIZATION ===="
report_utilization

set outbit "trace_ddr_stream.bit"
if {[info exists ::env(OUTBIT)]} { set outbit $::env(OUTBIT) }
write_bitstream -force $outbit
puts "============ TRACE DDR STREAM BUILD DONE -> $outbit ============"
