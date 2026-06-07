# r10 D1: authoritative bank check via Vivado device library (not xlsx).
link_design -part xc7a35tfgg484-2
puts "============ TRACE PIN BANK CHECK ============"
foreach p {D17 F13 E14 D14 E16} {
    set bank [get_property BANK [get_package_pins $p]]
    set fn   [get_property PIN_FUNC [get_package_pins $p]]
    puts [format "  PIN %-4s : BANK=%-4s  FUNC=%s" $p $bank $fn]
}
puts "============ DBG PIN BANK CHECK ============"
foreach p {C13 B13 A13 A14 C14 C15 A15 A16 B15 B16 F16 E17 A18 A19} {
    set bank [get_property BANK [get_package_pins $p]]
    puts [format "  PIN %-4s : BANK=%-4s" $p $bank]
}
exit
