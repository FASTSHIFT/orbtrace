# Stage-4 V3 "A route" OrbFlow constraints — A7-Lite. Identical pinout to
# trace_stream.xdc (STM32 ETM drives the trace inputs; RGMII gigabit egress);
# top module is trace_orbflow_top.

set_property PACKAGE_PIN J19 [get_ports sys_clk_50]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk_50]
create_clock -period 20.000 -name sys_clk_50 [get_ports sys_clk_50]

set_property PACKAGE_PIN L18 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]
set_false_path -from [get_ports rst_n]

# trace capture INPUT pins (BANK 16); TRACECLK on MRCC D17
set_property PACKAGE_PIN D17 [get_ports trace_clk_in]
set_property PACKAGE_PIN F13 [get_ports {trace_data_in[0]}]
set_property PACKAGE_PIN E14 [get_ports {trace_data_in[1]}]
set_property PACKAGE_PIN D14 [get_ports {trace_data_in[2]}]
set_property PACKAGE_PIN E16 [get_ports {trace_data_in[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports trace_clk_in]
set_property IOSTANDARD LVCMOS33 [get_ports {trace_data_in[*]}]
create_clock -period 10.000 -name trace_clk_in [get_ports trace_clk_in]
# D17 feeds a BUFR (BUFR_IO mode); allow dedicated-route demotion (trace_clk
# is slow /16, sub-optimal route is fine).
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -hierarchical -filter {NAME =~ *trace_clk_ibuf*}]

# RGMII (RTL8211E), BANK 15
set_property PACKAGE_PIN K18 [get_ports phy_rx_clk]
set_property PACKAGE_PIN K19 [get_ports phy_rx_ctl]
set_property PACKAGE_PIN M16 [get_ports {phy_rxd[3]}]
set_property PACKAGE_PIN L16 [get_ports {phy_rxd[2]}]
set_property PACKAGE_PIN M15 [get_ports {phy_rxd[1]}]
set_property PACKAGE_PIN L14 [get_ports {phy_rxd[0]}]
set_property PACKAGE_PIN K17 [get_ports phy_tx_clk]
set_property PACKAGE_PIN N20 [get_ports phy_tx_ctl]
set_property PACKAGE_PIN M13 [get_ports {phy_txd[3]}]
set_property PACKAGE_PIN L13 [get_ports {phy_txd[2]}]
set_property PACKAGE_PIN L15 [get_ports {phy_txd[1]}]
set_property PACKAGE_PIN K16 [get_ports {phy_txd[0]}]
set_property PACKAGE_PIN N22 [get_ports phy_reset_n]
set_property PACKAGE_PIN M22 [get_ports phy_mdc]
set_property PACKAGE_PIN M20 [get_ports phy_mdio]
set_property IOSTANDARD LVCMOS33 [get_ports phy_*]
create_clock -period 8.000 -name phy_rx_clk [get_ports phy_rx_clk]

set_property PACKAGE_PIN M18 [get_ports led0]
set_property PACKAGE_PIN N18 [get_ports led1]
set_property IOSTANDARD LVCMOS33 [get_ports led0]
set_property IOSTANDARD LVCMOS33 [get_ports led1]

set_clock_groups -asynchronous \
    -group [get_clocks sys_clk_50] \
    -group [get_clocks trace_clk_in] \
    -group [get_clocks phy_rx_clk] \
    -group [get_clocks -of_objects [get_pins u_mmcm/CLKOUT0]] \
    -group [get_clocks -of_objects [get_pins u_mmcm/CLKOUT1]] \
    -group [get_clocks -of_objects [get_pins u_mmcm/CLKOUT2]] \
    -group [get_clocks -of_objects [get_pins u_mmcm/CLKOUT3]]

set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
