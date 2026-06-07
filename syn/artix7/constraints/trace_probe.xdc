# Trace probe top constraints — A7-Lite (xc7a35tfgg484-2)
# Stage-2 T4: provide real pin & timing constraints so post-implementation
# numbers reflect actual board placement.

# ============================================================
# Board oscillator (50 MHz, J19)
# ============================================================
set_property PACKAGE_PIN J19 [get_ports sys_clk_50]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk_50]
create_clock -period 20.000 -name sys_clk_50 [get_ports sys_clk_50]

# ============================================================
# Reset (active-low button on board, RESET signal in stock xdc -> L18)
# ============================================================
set_property PACKAGE_PIN L18 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]
set_false_path -from [get_ports rst_n]

# ============================================================
# ARM Trace pins (GPIO1, Bank 16, see PLAN_STAGE2 §T5).
# TRACECLK on MRCC-capable pin GPIO1_4P (D17 = IO_L12P_T1_MRCC_16).
# Data lanes on adjacent GPIO1 Bank 16 pins.
# ============================================================
set_property PACKAGE_PIN D17 [get_ports trace_clk_in]
set_property PACKAGE_PIN F13 [get_ports {trace_data_in[0]}]
set_property PACKAGE_PIN F14 [get_ports {trace_data_in[1]}]
set_property PACKAGE_PIN E13 [get_ports {trace_data_in[2]}]
set_property PACKAGE_PIN E14 [get_ports {trace_data_in[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports trace_clk_in]
set_property IOSTANDARD LVCMOS33 [get_ports {trace_data_in[*]}]

# Trace clock: nominal 100 MHz for synthesis/timing; real range is target-dependent
create_clock -period 10.000 -name trace_clk_in [get_ports trace_clk_in]

# ============================================================
# RGMII gigabit Ethernet (from A7_lite.xdc)
# ============================================================
set_property PACKAGE_PIN K18 [get_ports phy_rx_clk]
set_property PACKAGE_PIN L14 [get_ports {phy_rxd[0]}]
set_property PACKAGE_PIN M15 [get_ports {phy_rxd[1]}]
set_property PACKAGE_PIN L16 [get_ports {phy_rxd[2]}]
set_property PACKAGE_PIN M16 [get_ports {phy_rxd[3]}]
set_property PACKAGE_PIN K19 [get_ports phy_rx_ctl]
set_property PACKAGE_PIN K17 [get_ports phy_tx_clk]
set_property PACKAGE_PIN K16 [get_ports {phy_txd[0]}]
set_property PACKAGE_PIN L15 [get_ports {phy_txd[1]}]
set_property PACKAGE_PIN L13 [get_ports {phy_txd[2]}]
set_property PACKAGE_PIN M13 [get_ports {phy_txd[3]}]
set_property PACKAGE_PIN N20 [get_ports phy_tx_ctl]
set_property PACKAGE_PIN N22 [get_ports phy_reset_n]
set_property PACKAGE_PIN M22 [get_ports phy_mdc]
set_property PACKAGE_PIN M20 [get_ports phy_mdio]
set_property IOSTANDARD LVCMOS33 [get_ports phy_*]

# RGMII RX clock at 125 MHz
create_clock -period 8.000 -name phy_rx_clk [get_ports phy_rx_clk]

# ============================================================
# LEDs (M18 / N18 from stock xdc)
# ============================================================
set_property PACKAGE_PIN M18 [get_ports led0]
set_property PACKAGE_PIN N18 [get_ports led1]
set_property IOSTANDARD LVCMOS33 [get_ports led0]
set_property IOSTANDARD LVCMOS33 [get_ports led1]

# ============================================================
# Asynchronous clock domains (declare unrelated to avoid spurious cross-clock
# timing checks in the simplified T4 datapath; production CDC will be
# AsyncFIFO-based and handled in Stage-3).
#
# MMCM mapping (must match trace_probe_top.v MMCME2_BASE):
#   CLKOUT0 = 125 MHz, 0°    (RGMII MAC)
#   CLKOUT1 = 125 MHz, 90°   (RGMII TX clk pin)
#   CLKOUT2 = 200 MHz        (IDELAYCTRL)
#   CLKOUT3 = 100 MHz        (sys/trace-core domain)
# ============================================================
set_clock_groups -asynchronous \
    -group [get_clocks sys_clk_50] \
    -group [get_clocks trace_clk_in] \
    -group [get_clocks phy_rx_clk] \
    -group [get_clocks -of_objects [get_pins u_mmcm/CLKOUT0]] \
    -group [get_clocks -of_objects [get_pins u_mmcm/CLKOUT1]] \
    -group [get_clocks -of_objects [get_pins u_mmcm/CLKOUT2]] \
    -group [get_clocks -of_objects [get_pins u_mmcm/CLKOUT3]]
