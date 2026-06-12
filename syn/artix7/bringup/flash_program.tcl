# Flash-fixation: write a .mcs into the A7-Lite on-board QSPI (IS25LP128F,
# 128 Mb / 16 MB, SPIx4) so the design PERSISTS across power cycles.
# Unlike program_*.tcl (which do a volatile JTAG .bit download lost on power
# cycle), this programs the configuration flash via JTAG so the FPGA boots
# the design from QSPI on every power-up.
#
#   source /path/to/Vivado/2021.1/settings64.sh
#   cd build && vivado -mode batch -source ../flash_program.tcl
#
# Run from the directory containing the .mcs. Override with env MCS=<file>.
# Default: trace_orbflow.mcs

set MCS "trace_orbflow.mcs"
if {[info exists ::env(MCS)]} { set MCS $::env(MCS) }
# get_cfgmem_parts confirmed this is the correct SPIx4 part name for the
# IS25LP128F on the A7-Lite.
set CFGPART "is25lp128f-spi-x1_x2_x4"

if {![file exists $MCS]} { puts "ERROR: $MCS not found in [pwd]"; exit 1 }
puts "============ FLASH PROGRAM: $MCS -> QSPI ($CFGPART) ============"

open_hw_manager
# JTAG hw_server only (FT232H + VMware: do NOT auto-launch cs_server).
connect_hw_server -url localhost:3121 -allow_non_jtag

set tgt ""
set tries 0
while {$tgt eq "" && $tries < 20} {
    catch {refresh_hw_server -force_poll}
    foreach t [get_hw_targets -quiet] {
        if {$t ne ""} { set tgt $t; break }
    }
    if {$tgt eq ""} { puts "  waiting for JTAG target... ($tries)"; after 1500; incr tries }
}
if {$tgt eq ""} { puts "ERROR: no JTAG target"; exit 1 }
puts "  target: $tgt"

current_hw_target $tgt
open_hw_target $tgt

set dev [lindex [get_hw_devices] 0]
puts "  device: $dev"
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

# Attach the configuration memory part to the FPGA, point it at the .mcs,
# and program it (erase + blank-check skipped for speed; program + verify).
create_hw_cfgmem -hw_device $dev -mem_dev [lindex [get_cfgmem_parts $CFGPART] 0]
set cfg [get_property PROGRAM.HW_CFGMEM $dev]

set_property PROGRAM.BLANK_CHECK  0          $cfg
set_property PROGRAM.ERASE        1          $cfg
set_property PROGRAM.CFG_PROGRAM  1          $cfg
set_property PROGRAM.VERIFY       1          $cfg
set_property PROGRAM.CHECKSUM     0          $cfg
set_property PROGRAM.ADDRESS_RANGE  {use_file} $cfg
set_property PROGRAM.FILES        [list $MCS] $cfg
set_property PROGRAM.PRM_FILE     {}         $cfg
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cfg

# A configured FPGA is required to drive the QSPI programming pins. Vivado
# loads a small bscan/SPI bridge bitstream automatically when programming the
# cfgmem; create_hw_cfgmem handles this. Now program.
program_hw_cfgmem -hw_cfgmem $cfg
puts "============ FLASH PROGRAMMED. Power-cycle to boot from QSPI. ============"

# Optionally boot it now (re-load config from flash) without a power cycle:
boot_hw_device $dev

close_hw_target
disconnect_hw_server
puts "============ DONE ============"
