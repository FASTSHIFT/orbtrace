# gen_trace_ddr_stream_project.tcl
# =================================
# Create an ON-DISK Vivado PROJECT (.xpr) for the active trace_ddr_stream_top
# design so you can open it in the GUI and inspect the ACTUAL wiring:
#   * RTL Analysis -> Schematic (elaborated: see trace_capture_a7 IDDR path,
#     the DDR ring writer/streamer, fpga_core_net, packetiser nets)
#   * Open Synthesized Design -> Schematic / I/O Ports / Device view (real
#     placed primitives + pin assignment from the XDC + MIG)
#
# This mirrors run_trace_ddr_stream.tcl's source list EXACTLY but uses a
# real project (create_project on disk) instead of -in_memory, so the GUI
# can open it. It does NOT run impl/bitstream by default (fast); pass
# RUN_SYNTH=1 to also launch synthesis so the synthesized schematic is
# available offline.
#
# Usage (from the bringup dir, Vivado 2021.1 sourced):
#   cd build
#   vivado -mode batch -source ../fpga_flow/gen_trace_ddr_stream_project.tcl
#   # then open the GUI:
#   vivado build/trace_ddr_stream_proj/trace_ddr_stream_proj.xpr
#
# Options (env):
#   USE_IDELAY=0|1   default 0 (shipped direct IBUF->IDDR capture)
#   RUN_SYNTH=1      also run synth_design in project mode (slower)
#   PROJ_DIR=<path>  project location (default build/trace_ddr_stream_proj)

set part      xc7a35tfgg484-2
set bdir      [file dirname [info script]]
set bringup   [file normalize [file join $bdir ..]]
set repo_root [file normalize [file join $bdir .. .. .. ..]]
set ex        $repo_root/syn/external/verilog-ethernet/example/NexysVideo/fpga
set rtl       $repo_root/syn/artix7/rtl
set ipdir     $bringup/rtl/ddr3/ip

set use_idelay 0
if {[info exists ::env(USE_IDELAY)]} { set use_idelay $::env(USE_IDELAY) }
set proj_dir "$bringup/build/trace_ddr_stream_proj"
if {[info exists ::env(PROJ_DIR)]} { set proj_dir $::env(PROJ_DIR) }
set proj_name "trace_ddr_stream_proj"

# Fresh project every run (delete stale one so the GUI never opens a corrupt
# half-written project).
file delete -force $proj_dir
create_project $proj_name $proj_dir -part $part -force

# ---- IP: MIG DDR3 + clocking wizard (add the .xci to the project) ----
import_ip $ipdir/mig_ddr3/mig_ddr3.xci
import_ip $ipdir/clock/clock.xci
generate_target all [get_ips]

# ---- design sources ----
set design_v [list \
    $rtl/trace_capture_a7.v \
    $bringup/rtl/ddr3/ddr3_ctrl.v \
    $bringup/rtl/ddr3/ddr3_wr_ctrl.v \
    $bringup/rtl/ddr3/ddr3_rd_ctrl.v \
    $bringup/rtl/ddr3/ddr3_arbit.v \
    $bringup/rtl/la_ddr_writer.v \
    $bringup/rtl/la_ddr_ring_streamer.v \
    $bringup/rtl/fpga_core_net.v \
    $bringup/rtl/dbg_regfile.v \
    $bringup/rtl/trace_ddr_stream_top.v \
]

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
    lappend design_v $ex/$s
}
add_files -norecurse $design_v

# ---- constraints ----
add_files -fileset constrs_1 -norecurse $bringup/rtl/trace_ddr_stream.xdc

# Top + the USE_IDELAY generic (so the elaborated/synth schematic matches the
# shipped direct build).
set_property top trace_ddr_stream_top [current_fileset]
set_property generic "USE_IDELAY=$use_idelay" [current_fileset]

update_compile_order -fileset sources_1

puts "============================================================"
puts " Project created: $proj_dir/$proj_name.xpr"
puts " top = trace_ddr_stream_top   USE_IDELAY = $use_idelay   part = $part"
puts ""
puts " Open in GUI:"
puts "   vivado $proj_dir/$proj_name.xpr"
puts ""
puts " To see wiring WITHOUT synthesis:"
puts "   Flow Navigator -> RTL ANALYSIS -> Open Elaborated Design -> Schematic"
puts " To see the placed primitives + pin assignment:"
puts "   Run Synthesis, then Open Synthesized Design -> Schematic / I/O Ports"
puts "============================================================"

# Optional: run synthesis now so the synthesized netlist is available offline.
set run_synth 0
if {[info exists ::env(RUN_SYNTH)]} { set run_synth $::env(RUN_SYNTH) }
if {$run_synth} {
    puts ">>> RUN_SYNTH=1: launching synthesis (this takes a few minutes)..."
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
    puts ">>> synthesis done. Open the project and 'Open Synthesized Design'."
}
