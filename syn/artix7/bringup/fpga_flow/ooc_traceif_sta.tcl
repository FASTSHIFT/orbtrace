# OOC synthesis + STA of traceIF.v alone, to answer red-team r27 R7C:
# does traceIF's single-cycle combinational framing logic (36-bit construct
# shift + two 32-bit sync compares + 128-bit cFrame assembly) meet timing when
# clocked by TRACECLK at 48 / 100 / 150 / 198 MHz on this Artix-7 part?
#
# If WNS < 0 at a target frequency, framing is wrong BEFORE any sampling issue,
# and traceIF must be pipelined first.
#
#   TCLK_MHZ=100 vivado -mode batch -source ooc_traceif_sta.tcl
set part      xc7a35tfgg484-2
set bdir      [file dirname [info script]]
set repo_root [file normalize [file join $bdir .. .. .. ..]]

set fmhz 100
if {[info exists ::env(TCLK_MHZ)]} { set fmhz $::env(TCLK_MHZ) }
set per [expr {1000.0 / $fmhz}]

create_project -in_memory -part $part
read_verilog $repo_root/verilog/traceIF.v
synth_design -top traceIF -part $part -mode out_of_context \
    -generic MAXBUSWIDTH=4

# TRACECLK drives the only clock in traceIF (traceClkin).
create_clock -period $per -name traceClkin [get_ports traceClkin]

# Inputs (traceDina/b, width) arrive synchronous to TRACECLK from the IDDR;
# give a modest input delay so STA sees a realistic path, not a free ride.
set_input_delay -clock traceClkin [expr {$per * 0.2}] [get_ports {traceDina[*] traceDinb[*] width[*]}]

opt_design
place_design
route_design
puts "============ traceIF OOC STA @ ${fmhz} MHz (period ${per} ns) ============"
report_timing_summary -no_header -no_detailed_paths
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "============ traceIF @ ${fmhz} MHz : WNS = ${wns} ns ============"
