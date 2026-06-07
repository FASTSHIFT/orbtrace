# HG-4: 35T vs 100T pin-compatibility self-check on FGG484, straight from
# the Vivado device library (more authoritative than the UG475 PDF).
# Compares BANK + PIN_FUNC for every pin this design uses, across both dice.
#
# Also answers HG-3 prep: what BANK are the RGMII RX pins in? (decides
# whether a 2nd IDELAYCTRL is needed when PHY_RX_DELAY_INTERNAL=1).

set used_pins {
    J19 L18
    D17 F13 E14 D14 E16
    K18 K19 M16 L16 M15 L14 K17 N20 M13 L13 L15 K16 N22 M22 M20
    M18 N18
    C13 B13 A13 A14 C14 C15 A15 A16 B15 B16 F16 E17 A18 A19 B17
}

proc dump_part {part pins arrname} {
    upvar 1 $arrname A
    link_design -part $part
    foreach p $pins {
        set pp [get_package_pins -quiet $p]
        if {[llength $pp] == 0} {
            set A($p) "MISSING"
        } else {
            set A($p) "[get_property BANK $pp]/[get_property PIN_FUNC $pp]"
        }
    }
    close_design
}

dump_part xc7a35tfgg484-2  $used_pins  A35
dump_part xc7a100tfgg484-2 $used_pins  A100

puts "============ 35T vs 100T FGG484 PIN COMPAT (HG-4) ============"
puts [format "  %-5s %-28s %-28s %s" PIN 35T 100T MATCH]
set mismatch 0
foreach p $used_pins {
    set same [expr {$A35($p) eq $A100($p)}]
    if {!$same} { incr mismatch }
    puts [format "  %-5s %-28s %-28s %s" $p $A35($p) $A100($p) [expr {$same ? "OK" : "*** DIFF ***"}]]
}
puts "============ MISMATCHES: $mismatch ============"

# RGMII RX bank summary for HG-3
puts "============ RGMII RX pin banks (HG-3 prep) ============"
link_design -part xc7a35tfgg484-2
foreach p {K18 K19 M16 L16 M15 L14} {
    puts [format "  %-4s : BANK=%s" $p [get_property BANK [get_package_pins $p]]]
}
puts "  (trace IDELAYCTRL is in BANK 16; if RGMII RX != 16, a 2nd IDELAYCTRL is needed)"
exit
