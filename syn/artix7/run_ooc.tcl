# Batch OOC synthesis for trace pipeline modules on Artix-7 (xc7a35t).
# Usage:  vivado -mode batch -nojournal -nolog -source syn/artix7/run_ooc.tcl
#
# All Amaranth-derived Verilog modules end up named matching their file.
# traceIF is the hand-written Verilog from verilog/ and is included as well.

set part xc7a35tfgg484-2
set syn_dir [file dirname [info script]]
set repo_root [file normalize [file join $syn_dir .. ..]]

set jobs {
    {traceIF          {verilog/traceIF.v}}
    {checksum_appender {syn/artix7/checksum_appender.v}}
    {cobs_encoder     {syn/artix7/cobs_encoder.v}}
    {super_framer     {syn/artix7/super_framer.v}}
    {tpiu_demux       {syn/artix7/tpiu_demux.v}}
}

set summary {}

foreach j $jobs {
    set top [lindex $j 0]
    set srcs [lindex $j 1]
    puts "===================================================="
    puts "OOC: $top"
    puts "===================================================="
    foreach s $srcs { read_verilog [file join $repo_root $s] }
    if {[catch {
        synth_design -top $top -part $part -mode out_of_context
        # Pull key utilization numbers
        set u [report_utilization -return_string]
        set lut "?"; set ff "?"; set bram "?"
        foreach line [split $u "\n"] {
            if {[regexp {^\| Slice LUTs\*\s*\|\s*(\d+)} $line _ x]} { set lut $x }
            if {[regexp {^\| Slice Registers\s*\|\s*(\d+)} $line _ x]} { set ff $x }
            if {[regexp {^\| Block RAM Tile\s*\|\s*(\d+(?:\.\d+)?)} $line _ x]} { set bram $x }
        }
        lappend summary [list $top $lut $ff $bram]
    } err]} {
        puts "ERROR synthesizing $top: $err"
        lappend summary [list $top "ERR" "ERR" "ERR"]
    }
    # reset between jobs
    close_design -quiet
    catch { close_project -quiet }
}

puts "\n\n===================================================="
puts "OOC SUMMARY (xc7a35tfgg484-2, available: 20800 LUT / 41600 FF / 50 BRAM)"
puts "===================================================="
puts [format "%-22s %8s %8s %8s" "module" "LUT" "FF" "BRAM"]
puts [string repeat "-" 50]
set tot_lut 0; set tot_ff 0; set tot_bram 0
foreach r $summary {
    puts [format "%-22s %8s %8s %8s" {*}$r]
    catch { incr tot_lut [lindex $r 1] }
    catch { incr tot_ff  [lindex $r 2] }
    # BRAM is float-ish, just print
}
puts [string repeat "-" 50]
puts [format "%-22s %8d %8d" "SUM (LUT+FF)" $tot_lut $tot_ff]
puts [format "%% of 35T: LUT=%.2f%%  FF=%.2f%%" \
      [expr 100.0*$tot_lut/20800.0] [expr 100.0*$tot_ff/41600.0]]
