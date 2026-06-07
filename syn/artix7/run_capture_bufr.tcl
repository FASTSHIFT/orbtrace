# r11 HG-2: BUFG vs BUFIO/BUFR sensitivity study for the trace clock.
#
# Goal: quantify how much tighter the source-synchronous sampling window is
# with BUFG (global, large skew/insertion delay) vs BUFIO+BUFR (region-
# local). This decides whether the on-board deskew can find a >=8-tap eye
# at 100 MHz trace_clk — a buy-decision input, not a Stage-3 item.
#
# For each variant we synthesise trace_capture_a7 OOC with a 100 MHz
# trace_clk constraint + the same source-sync input delays the top design
# uses, then report the worst setup/hold slack on the
# trace_data_in -> IDDR/D capture path. The slack delta between the two
# variants is the window the clock-buffer choice costs us.

set part xc7a35tfgg484-2
set syn_dir [file dirname [info script]]

proc run_variant {part syn_dir buf} {
    read_verilog $syn_dir/rtl/trace_capture_a7.v
    synth_design -top trace_capture_a7 -part $part -mode out_of_context \
        -generic CLK_BUF=$buf

    # 100 MHz trace clock on the clock input pin
    create_clock -period 10.000 -name traceclk [get_ports trace_clk_p]
    # 200 MHz idelay ref
    create_clock -period 5.000 -name ref200 [get_ports ref_200m]
    # Source-synchronous DDR window, same as top-level xdc (+/- UI/4 = 1.25ns)
    set_input_delay -clock traceclk -max  1.25 [get_ports trace_data_p[*]]
    set_input_delay -clock traceclk -min -1.25 [get_ports trace_data_p[*]]
    set_input_delay -clock traceclk -max  1.25 [get_ports trace_data_p[*]] -clock_fall -add_delay
    set_input_delay -clock traceclk -min -1.25 [get_ports trace_data_p[*]] -clock_fall -add_delay

    opt_design
    place_design
    route_design

    puts "######## CLK_BUF = $buf ########"
    puts "---- overall timing summary (WNS/WHS = sampling window margin) ----"
    report_timing_summary -no_header -max_paths 1 -delay_type min_max
    puts "---- worst setup data->IDDR ----"
    report_timing -delay_type max -max_paths 2 -nworst 1 \
        -to [get_pins -hier -filter {NAME =~ *u_iddr*/D}]
    puts "---- worst hold data->IDDR ----"
    report_timing -delay_type min -max_paths 2 -nworst 1 \
        -to [get_pins -hier -filter {NAME =~ *u_iddr*/D}]
    puts "---- utilization ----"
    report_utilization
    close_design
}

run_variant $part $syn_dir "BUFG"
run_variant $part $syn_dir "BUFR_IO"
