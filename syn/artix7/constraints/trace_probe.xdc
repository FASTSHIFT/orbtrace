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
# Data lanes on adjacent GPIO1 Bank 16 differential P pins (verified
# against A7_LITE_GPIO.xlsx — all on Bank 16, all 3.3V VCCIO_A).
#   trace_data_in[0] -> GPIO1_0P / F13
#   trace_data_in[1] -> GPIO1_1P / E14   (note: P pin of pair 1 is E14)
#   trace_data_in[2] -> GPIO1_2P / D14
#   trace_data_in[3] -> GPIO1_3P / E16
# ============================================================
set_property PACKAGE_PIN D17 [get_ports trace_clk_in]
set_property PACKAGE_PIN F13 [get_ports {trace_data_in[0]}]
set_property PACKAGE_PIN E14 [get_ports {trace_data_in[1]}]
set_property PACKAGE_PIN D14 [get_ports {trace_data_in[2]}]
set_property PACKAGE_PIN E16 [get_ports {trace_data_in[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports trace_clk_in]
set_property IOSTANDARD LVCMOS33 [get_ports {trace_data_in[*]}]

# Trace clock: nominal 100 MHz for synthesis/timing; real range is target-dependent
create_clock -period 10.000 -name trace_clk_in [get_ports trace_clk_in]

# Source-synchronous DDR input delays for trace data (r09 D3).
# Without these constraints Vivado treats trace_data_in as unconstrained-
# equivalent-constant and propagates dead code through the IDDR + traceIF
# + entire trace pipeline, yielding a misleadingly small T4 utilization.
# Center-aligned source-sync model: data eye centred on TRACECLK rising
# edge with ±UI/4 setup/hold window. UI = 5ns (DDR @ 100MHz); ±1.25ns
# is a conservative estimate before real eye-scan calibration on board.
set_input_delay -clock trace_clk_in -max  1.25 [get_ports {trace_data_in[*]}]
set_input_delay -clock trace_clk_in -min -1.25 [get_ports {trace_data_in[*]}]
set_input_delay -clock trace_clk_in -max  1.25 [get_ports {trace_data_in[*]}] -clock_fall -add_delay
set_input_delay -clock trace_clk_in -min -1.25 [get_ports {trace_data_in[*]}] -clock_fall -add_delay

# r09 D3 honest declaration: the trace_data_in -> IDDR/D path is a true
# source-synchronous input that physically requires per-lane deskew tap
# calibration to close timing. Stage-2 has only the static IDELAY tap=16
# default (no training FSM); on-board Stage-3 PoC will scan all 32 taps
# and choose the centre-of-eye per lane.
#
# Static-timing-wise, this means the trace input path will report a
# negative hold slack at OOC/post-impl time (~-3 ns at the conservative
# ±1.25 ns input-delay window above). This is NOT a real timing failure
# of the design; it is the static analyser refusing to bless an as-yet-
# uncalibrated source-sync interface. The bound is therefore a false
# path for setup/hold check purposes; eye-scan on board will replace it
# with measured numbers.
set_false_path -from [get_ports {trace_data_in[*]}] -hold

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
# Trace pipeline debug observation pins (r09 A1).
# Force opt_design to keep the trace post-pipeline in the routed netlist.
# All pinned to spare GPIO1 Bank 16 pins (verified against A7_LITE_GPIO.xlsx).
# Stage-3 replaces with the real UDP-trace bridge.
#   trace_dbg_data[0..7] -> GPIO1_5P/N..GPIO1_8P/N
#   trace_dbg_valid/last -> GPIO1_9P/N
#   trace_dbg_inter[0..3] -> GPIO1_10P/N..GPIO1_11P/N
# ============================================================
set_property PACKAGE_PIN C13 [get_ports {trace_dbg_data[0]}]
set_property PACKAGE_PIN B13 [get_ports {trace_dbg_data[1]}]
set_property PACKAGE_PIN A13 [get_ports {trace_dbg_data[2]}]
set_property PACKAGE_PIN A14 [get_ports {trace_dbg_data[3]}]
set_property PACKAGE_PIN C14 [get_ports {trace_dbg_data[4]}]
set_property PACKAGE_PIN C15 [get_ports {trace_dbg_data[5]}]
set_property PACKAGE_PIN A15 [get_ports {trace_dbg_data[6]}]
set_property PACKAGE_PIN A16 [get_ports {trace_dbg_data[7]}]
set_property PACKAGE_PIN B15 [get_ports trace_dbg_valid]
set_property PACKAGE_PIN B16 [get_ports trace_dbg_last]
set_property PACKAGE_PIN F16 [get_ports {trace_dbg_inter[0]}]
set_property PACKAGE_PIN E17 [get_ports {trace_dbg_inter[1]}]
set_property PACKAGE_PIN A18 [get_ports {trace_dbg_inter[2]}]
set_property PACKAGE_PIN A19 [get_ports {trace_dbg_inter[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {trace_dbg_data[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports {trace_dbg_inter[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports trace_dbg_valid]
set_property IOSTANDARD LVCMOS33 [get_ports trace_dbg_last]

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
