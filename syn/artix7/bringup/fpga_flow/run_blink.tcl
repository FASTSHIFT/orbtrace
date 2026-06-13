# Bring-up: build the blink bitstream for A7-Lite (XC7A35T) end to end.
# Produces both a .bit (JTAG volatile load) and a .mcs/.bin (SPIx4 flash).
#
#   source /path/to/Vivado/2021.1/settings64.sh
#   vivado -mode batch -source syn/artix7/bringup/run_blink.tcl
#
# Outputs land in the current working directory:
#   blink.bit          - load over JTAG (volatile, gone on power cycle)
#   blink.mcs          - program into QSPI flash (persists)

set part    xc7a35tfgg484-2
set bdir    [file dirname [info script]]
set bringup [file normalize [file join $bdir ..]]

read_verilog $bringup/rtl/blink.v
read_xdc     $bringup/rtl/blink.xdc

synth_design -top blink -part $part
opt_design
place_design
route_design

report_utilization
report_timing_summary -no_detailed_paths -no_header

write_bitstream -force blink.bit

# QSPI flash image (matches vendor SPIx4 @ 50 MHz config). Vendor flow uses
# a .bin written into the IS25LP128F (128 Mb / 16 MB). We emit both mcs and
# bin so either Vivado Hardware Manager or openFPGALoader can program it.
write_cfgmem -force -format mcs -interface spix4 -size 16 \
    -loadbit "up 0x0 blink.bit" -file blink.mcs
write_cfgmem -force -format bin -interface spix4 -size 16 \
    -loadbit "up 0x0 blink.bit" -file blink.bin

puts "============ BRING-UP BUILD DONE ============"
puts "  blink.bit  -> JTAG volatile load (gone on power cycle, fast test)"
puts "  blink.mcs  -> QSPI flash via Vivado Hardware Manager (persists)"
puts "  blink.bin  -> QSPI flash via openFPGALoader (persists)"
