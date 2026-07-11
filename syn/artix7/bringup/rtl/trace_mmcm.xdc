# trace_mmcm_top constraints — A7-Lite. MMCM 90-deg phase-shift sampling
# (proposal 22 §7.1). Same pinout as trace_stream.xdc but:
#   - trace_clk_in declared at its REAL ~21MHz (period 47.6ns) so the capture
#     MMCM (u_cap/u_mmcm) VCO = TRACECLK*MULT lands in 600-1200MHz (840MHz@M40).
#     (trace_stream.xdc used a 10ns/100MHz upper-bound which made the capture
#      MMCM VCO compute to 4000MHz and fail PDRC-34.)
#   - clock_groups reference the real instance hierarchy: system MMCM
#     u_sysmmcm (CLKOUT0/1/3) and capture MMCM u_cap/u_mmcm (CLKOUT0/1).

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
# TRACECLK = HCLK/2. create_clock for trace_clk_in is issued from
# run_trace_mmcm.tcl AFTER read_xdc (TRACE_PERIOD env), so one RTL/XDC covers a
# frequency band: capture MMCM VCO = MULT*1000/period must be 600-1440MHz.
#   21MHz->47.6/M40 ; 42MHz->23.8/M20 ; 84MHz->11.9/M10
# D17 (MRCC) -> IBUF -> BUFG -> MMCM. Allow dedicated-route demotion.
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

# LED pins swapped so physical positions match function: led0=NETWORK, led1=TRACE
# (board silkscreen order was reversed vs the led_status assignment).
set_property PACKAGE_PIN N18 [get_ports led0]
set_property PACKAGE_PIN M18 [get_ports led1]
set_property IOSTANDARD LVCMOS33 [get_ports led0]
set_property IOSTANDARD LVCMOS33 [get_ports led1]

# NOTE: set_clock_groups is issued from run_trace_mmcm.tcl AFTER synth +
# create_clock, because the MMCM-generated clocks (u_sysmmcm/*, u_cap/u_mmcm/*)
# and trace_clk_in do not exist yet at read_xdc time -- declaring the groups
# here silently no-ops, leaving clk90<->clk125 CDC paths constrained (they pass
# at 21M by slack luck but fail setup at 42M+).

set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
