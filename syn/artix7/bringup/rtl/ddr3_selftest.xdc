# ddr3_selftest_top constraints — A7-Lite (XC7A35T-FGG484).
# DDR3 pins come from the MIG IP's own generated XDC (mig_ddr3.xci); this file
# only constrains the top-level clk / reset / LEDs. Matches blink.xdc pinout.

set_property -dict {PACKAGE_PIN J19 IOSTANDARD LVCMOS33} [get_ports sys_clk_50]
create_clock -period 20.000 -name sys_clk_50 [get_ports sys_clk_50]

set_property -dict {PACKAGE_PIN L18 IOSTANDARD LVCMOS33} [get_ports rst_n]

# LEDs (same pins as blink.xdc: led0=M18, led1=N18)
set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33} [get_ports led0]
set_property -dict {PACKAGE_PIN N18 IOSTANDARD LVCMOS33} [get_ports led1]

# Boot from on-board QSPI (SPIx4) like the other bringup bitstreams
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4               [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50  [current_design]
