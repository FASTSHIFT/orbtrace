# Stage-2 T2: OOC synthesis of the Artix-7 source-synchronous DDR capture
# front-end for the trace pins.
#
# Front-end primitives: IBUF -> IDELAYE2 (per-lane deskew) -> IDDR + IDELAYCTRL.
# IDDR (DDR_CLK_EDGE = SAME_EDGE_PIPELINED) is the 7-series equivalent of
# ECP5's IDDRX1F used in orbtrace's upstream `glue.py` (litex DDRInput).
#
# Goal: prove the front-end synthesizes on xc7a35t and quantify its OOC
# footprint, replacing r08's 500-1500 LUT estimate with a real number.
# Phase calibration / training is deferred to Stage-3 on-board PoC.

set part xc7a35tfgg484-2
set syn_dir [file dirname [info script]]

read_verilog $syn_dir/rtl/trace_capture_a7.v

synth_design -top trace_capture_a7 -part $part -mode out_of_context

puts "============ UTILIZATION: trace_capture_a7 ============"
report_utilization

puts "============ PRIMITIVE INSTANCES ============"
foreach prim {IDDR ISERDESE2 IDELAYE2 IDELAYCTRL IBUF BUFG} {
    set n [llength [get_cells -hierarchical -filter "REF_NAME == $prim"]]
    puts [format "  %-12s : %d" $prim $n]
}
