# Build the Stage-4 V3 "A route" OrbFlow bitstream (trace_orbflow_top) for
# A7-Lite. Completes the orbtrace pipeline on the FPGA so the PC receives a
# native OFLOW byte stream (no PC-side byte-order guessing).
#
#   source $XILINX_VIVADO/settings64.sh
#   cd build && vivado -mode batch -source ../run_trace_orbflow.tcl
#
# Output: trace_orbflow.bit (+ .mcs/.bin for QSPI flash fixation).
# Env: TAP=<n> overrides IDELAY tap (default 28, V2 eye centre).

set part      xc7a35tfgg484-2
set bdir      [file dirname [info script]]
set repo_root [file normalize [file join $bdir .. .. ..]]
set ex        $repo_root/syn/external/verilog-ethernet/example/NexysVideo/fpga
set rtl       $repo_root/syn/artix7/rtl
set a7        $repo_root/syn/artix7

# capture front-end + traceIF + network core + new OrbFlow top
read_verilog $rtl/trace_capture_a7.v
read_verilog $repo_root/verilog/traceIF.v
read_verilog $bdir/fpga_core_net.v
read_verilog $bdir/trace_orbflow_top.v

# orbtrace post-processing pipeline (Amaranth-exported, Stage-2 OOC-verified)
read_verilog $a7/tpiu_demux.v
read_verilog $a7/checksum_appender.v
read_verilog $a7/cobs_encoder.v
read_verilog $a7/super_framer.v

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

read_xdc $bdir/trace_orbflow.xdc

set tap 28
if {[info exists ::env(TAP)]} { set tap $::env(TAP) }
set swap 0
if {[info exists ::env(SWAP_NIBBLES)]} { set swap $::env(SWAP_NIBBLES) }
puts "============ TAP = $tap  SWAP_NIBBLES = $swap ============"
synth_design -top trace_orbflow_top -part $part -generic TAP=$tap -generic SWAP_NIBBLES=$swap
opt_design
place_design
route_design
report_timing_summary -no_detailed_paths -no_header
write_bitstream -force trace_orbflow.bit

# QSPI flash images (IS25LP128F, 128 Mb / 16 MB, SPIx4 @ 50 MHz). See
# flash_program.tcl to actually write the .mcs into the on-board QSPI.
write_cfgmem -force -format mcs -interface spix4 -size 16 \
    -loadbit "up 0x0 trace_orbflow.bit" -file trace_orbflow.mcs
write_cfgmem -force -format bin -interface spix4 -size 16 \
    -loadbit "up 0x0 trace_orbflow.bit" -file trace_orbflow.bin

puts "============ TRACE ORBFLOW BUILD DONE (tap=$tap) ============"
puts "  trace_orbflow.bit -> JTAG volatile load (gone on power cycle)"
puts "  trace_orbflow.mcs -> QSPI flash via flash_program.tcl (persists)"
