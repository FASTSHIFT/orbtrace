# trace_ddr_selftest_top constraints — A7-Lite (XC7A35T-FGG484).
# Ethernet (RGMII) + LEDs + sys clk/reset. DDR3 pins come from the MIG IP's own
# generated XDC (mig_ddr3.xci). No trace-capture pins in P2a.

set_property PACKAGE_PIN J19 [get_ports sys_clk_50]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk_50]
create_clock -period 20.000 -name sys_clk_50 [get_ports sys_clk_50]

set_property PACKAGE_PIN L18 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]
set_false_path -from [get_ports rst_n]

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

# LEDs: led0=N18 (network/sys), led1=M18 (DDR3) — same swap as trace_mmcm.xdc
set_property PACKAGE_PIN N18 [get_ports led0]
set_property PACKAGE_PIN M18 [get_ports led1]
set_property IOSTANDARD LVCMOS33 [get_ports led0]
set_property IOSTANDARD LVCMOS33 [get_ports led1]

set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
