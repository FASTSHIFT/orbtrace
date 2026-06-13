# A7-Lite (XC7A35T-FGG484) bring-up blink constraints.
# Pins verified against vendor 01_led/top_pin.xdc + A7_lite.xdc.

set_property IOSTANDARD LVCMOS33 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[1]}]

set_property PACKAGE_PIN J19 [get_ports clk]
set_property PACKAGE_PIN L18 [get_ports rst_n]
set_property PACKAGE_PIN M18 [get_ports {led[0]}]
set_property PACKAGE_PIN N18 [get_ports {led[1]}]

# 50 MHz board oscillator
create_clock -period 20.000 -name clk [get_ports clk]

# SPIx4 flash configuration (so it boots from on-board QSPI like vendor demo)
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4               [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50  [current_design]
