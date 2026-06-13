// net_test_top
// =============
// Stage-3 network bring-up: minimal top that exercises ONLY the gigabit
// Ethernet path (no trace pipeline), so we can verify the A7-Lite RGMII +
// RTL8211E PHY + verilog-ethernet UDP/ICMP/ARP stack against a PC, before
// wiring in trace.
//
// fpga_core is the verilog-ethernet NexysVideo example core: it answers ARP,
// replies to ICMP echo (ping), and loops back UDP on port 1234. FPGA IP is
// set to 192.168.10.42 (edit fpga_core_net.v local_ip to match your LAN).
//
// Stage-4 V0 hook: UDP port 5000 replies with an FPGA-internal GOLDEN frame
// (4-byte TPIU sync FF FF FF 7F + ramp) instead of echoing, proving
// FPGA-sourced bytes traverse the UDP egress byte-exact. Port 1234 keeps
// the plain echo for network regression. See PLAN_STAGE4.md (V0).
//
// Board: A7-Lite (XC7A35T). 50 MHz osc on J19. RGMII on the on-board ETH
// (RTL8211E), pins from A7_lite.xdc.

`default_nettype none

module net_test_top (
    input  wire        sys_clk_50,
    input  wire        rst_n,

    // RGMII gigabit Ethernet (RTL8211E)
    input  wire        phy_rx_clk,
    input  wire [3:0]  phy_rxd,
    input  wire        phy_rx_ctl,
    output wire        phy_tx_clk,
    output wire [3:0]  phy_txd,
    output wire        phy_tx_ctl,
    output wire        phy_reset_n,
    inout  wire        phy_mdio,
    output wire        phy_mdc,

    output wire        led0,   // mmcm locked
    output wire        led1    // any UDP rx activity (first payload byte bit)
);

    wire rst = ~rst_n;

    // ------------------------------------------------------------------
    // MMCM: 50 -> 125 (RGMII), 125@90 (RGMII tx), 200 (idelay), 100 (sys)
    // (same clocking as trace_probe_top)
    // ------------------------------------------------------------------
    wire clkfb;
    wire clk125_u, clk125_90_u, clk200_u, clk100_u, mmcm_locked;

    MMCME2_BASE #(
        .CLKIN1_PERIOD(20.0),
        .CLKFBOUT_MULT_F(20.0),
        .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(8.0),
        .CLKOUT1_DIVIDE(8), .CLKOUT1_PHASE(90.0),
        .CLKOUT2_DIVIDE(5),
        .CLKOUT3_DIVIDE(10),
        .CLKOUT0_PHASE(0.0), .CLKOUT2_PHASE(0.0), .CLKOUT3_PHASE(0.0)
    ) u_mmcm (
        .CLKIN1(sys_clk_50), .CLKFBIN(clkfb), .CLKFBOUT(clkfb),
        .CLKOUT0(clk125_u), .CLKOUT1(clk125_90_u),
        .CLKOUT2(clk200_u), .CLKOUT3(clk100_u),
        .LOCKED(mmcm_locked), .RST(rst), .PWRDWN(1'b0)
    );

    wire clk125, clk125_90, clk200, clk100;
    BUFG b0(.I(clk125_u),    .O(clk125));
    BUFG b1(.I(clk125_90_u), .O(clk125_90));
    BUFG b2(.I(clk200_u),    .O(clk200));
    BUFG b3(.I(clk100_u),    .O(clk100));

    reg [3:0] rst_sync = 4'hf;
    always @(posedge clk125 or posedge rst)
        if (rst) rst_sync <= 4'hf;
        else     rst_sync <= {rst_sync[2:0], ~mmcm_locked};
    wire sys_rst = rst_sync[3];

    // ------------------------------------------------------------------
    // RGMII RX path. verilog-ethernet's rgmii_phy_if uses ssio_ddr_in with
    // a plain BUFG/BUFR clock and NO IDELAY — it assumes the PHY has
    // already centred clock-to-data (i.e. the PHY's RGMII RX internal delay
    // is ON). The RTL8211E on A7-Lite very likely straps RX delay ON, so
    // adding our OWN IDELAY on top double-delays and corrupts the phase
    // (CRC fails — exactly what we saw). So: feed phy_rxd straight through,
    // let the MAC's BUFG path sample it, and trust the PHY delay.
    //
    // (If this still fails, the PHY strap has RX delay OFF and we must add
    // a calibrated FPGA-side IDELAY back — that's the scan path. But try
    // the zero-extra-delay case first since it matches verilog-ethernet's
    // design assumption.)
    // ------------------------------------------------------------------
    wire idelay_rdy = 1'b1;      // not used in passthrough mode
    wire [3:0] rxd_dly   = phy_rxd;
    wire       rxctl_dly = phy_rx_ctl;

    // ------------------------------------------------------------------
    // verilog-ethernet NexysVideo core: ARP + ICMP(ping) + UDP loopback.
    // ------------------------------------------------------------------
    wire [7:0] led_eth;
    wire       rx_good_frame, rx_bad_fcs, tx_valid;
    fpga_core_net #(.TARGET("XILINX")) u_eth (
        .clk(clk125), .clk90(clk125_90), .rst(sys_rst),
        .btnu(1'b0), .btnl(1'b0), .btnd(1'b0), .btnr(1'b0), .btnc(1'b0),
        .sw(8'h0), .led(led_eth),
        .phy_rx_clk(phy_rx_clk),
        .phy_rxd(rxd_dly),
        .phy_rx_ctl(rxctl_dly),
        .phy_tx_clk(phy_tx_clk),
        .phy_txd(phy_txd),
        .phy_tx_ctl(phy_tx_ctl),
        .phy_reset_n(phy_reset_n),
        .phy_int_n(1'b1),
        .phy_pme_n(1'b1),
        .uart_rxd(1'b1),
        .uart_txd(),
        .dbg_rx_good_frame(rx_good_frame),
        .dbg_rx_bad_fcs(rx_bad_fcs),
        .dbg_tx_axis_tvalid(tx_valid),
        .ext_addr(),
        .ext_data(8'h00)
    );

    assign phy_mdio = 1'bz;
    assign phy_mdc  = 1'b0;

    // ------------------------------------------------------------------
    // Diagnostic LEDs with FREQUENCY-ENCODED states (active-low).
    //
    // LED0 = RX frame quality:
    //    SLOW blink (~1.5 Hz) : a CRC-GOOD frame has arrived  -> RX phase OK
    //    FAST blink (~12 Hz)  : only CRC-BAD frames arrived    -> RX phase wrong
    //    off                  : no frame received at all
    //   (good takes priority: once any good frame is seen, LED0 goes slow.)
    //
    // LED1 = TX activity:
    //    SLOW blink (~1.5 Hz) : the MAC has transmitted at least one frame
    //                           (ARP reply / ICMP echo) -> TX path works
    //    off                  : FPGA has never transmitted
    // ------------------------------------------------------------------
    reg good_seen = 0, bad_seen = 0, tx_seen = 0;
    reg [26:0] cnt = 0;
    always @(posedge clk125) begin
        cnt <= cnt + 1'b1;
        if (rx_good_frame) good_seen <= 1'b1;
        if (rx_bad_fcs)    bad_seen  <= 1'b1;
        if (led_eth[0])    tx_seen   <= 1'b1;   // MAC's own activity flag (legal load)
        if (tx_valid)      tx_seen   <= 1'b1;   // MAC wants to transmit a frame (pre-RGMII)
    end

    wire slow = cnt[24];   // ~1.9 Hz at 125MHz/2^25
    wire fast = cnt[21];   // ~15 Hz

    // LED0: good -> slow; else if bad -> fast; else off
    reg led0_r;
    always @(*) begin
        if (good_seen)      led0_r = slow;
        else if (bad_seen)  led0_r = fast;
        else                led0_r = 1'b0;
    end
    assign led0 = ~led0_r;

    // LED1: TX seen -> slow blink; else off
    assign led1 = ~(tx_seen & slow);

endmodule

`default_nettype wire
