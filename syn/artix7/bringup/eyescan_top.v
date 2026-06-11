// eyescan_top
// ===========
// Stage-4 V1 top: FPGA self-loopback eye-scan of the source-synchronous DDR
// trace capture path, with NO STM32 in the loop. The FPGA launches a known
// DDR pattern out 5 pins; you jumper those to the 5 trace input pins on the
// board; trace_capture_a7 samples them; trace_eyescan sweeps the IDELAY taps
// and builds a per-tap/per-lane error table; the table is read out over UDP
// (port 5001) via fpga_core_net's external-readout hook.
//
// Wiring (board jumpers, GPIO1 / BANK 16):
//   txclk_out  -> trace_clk_in   (loopback clock)
//   txd_out[0] -> trace_data_in[0]
//   txd_out[1] -> trace_data_in[1]
//   txd_out[2] -> trace_data_in[2]
//   txd_out[3] -> trace_data_in[3]
//
// PC side: send any 256-byte UDP frame to <ip>:5001; the reply is the
// 256-byte eye table: addr = tap*8 + lane*2 + {hi,lo} (16-bit error count).
// See eyescan_read.py.

`default_nettype none

module eyescan_top (
    input  wire        sys_clk_50,
    input  wire        rst_n,

    // RGMII gigabit Ethernet (RTL8211E) — UDP readout
    input  wire        phy_rx_clk,
    input  wire [3:0]  phy_rxd,
    input  wire        phy_rx_ctl,
    output wire        phy_tx_clk,
    output wire [3:0]  phy_txd,
    output wire        phy_tx_ctl,
    output wire        phy_reset_n,
    inout  wire        phy_mdio,
    output wire        phy_mdc,

    // Loopback pattern OUT (jumper to trace_*_in)
    output wire        txclk_out,
    output wire [3:0]  txd_out,

    // Trace capture IN (looped back from the OUT pins)
    input  wire        trace_clk_in,
    input  wire [3:0]  trace_data_in,

    output wire        led0,   // idelayctrl ready
    output wire        led1    // scan_done (slow) / eye_found gates it
);

    wire rst = ~rst_n;

    // ------------------------------------------------------------------
    // MMCM: 50 -> 125 (RGMII), 125@90, 200 (idelay/pattern), 100 (sys)
    // ------------------------------------------------------------------
    wire clkfb;
    wire clk125_u, clk125_90_u, clk200_u, clk100_u, mmcm_locked;
    MMCME2_BASE #(
        .CLKIN1_PERIOD(20.0), .CLKFBOUT_MULT_F(20.0), .DIVCLK_DIVIDE(1),
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
    always @(posedge clk100 or posedge rst)
        if (rst) rst_sync <= 4'hf;
        else     rst_sync <= {rst_sync[2:0], ~mmcm_locked};
    wire sys_rst = rst_sync[3];

    // ------------------------------------------------------------------
    // Pattern launch clock. Use clk100 (DDR @ 100MHz = 200 Mbps/lane) — a
    // conservative low-speed first pass; raise later in V4. The pattern
    // generator lives inside trace_eyescan and drives ODDRs off clk_tx.
    // ------------------------------------------------------------------
    wire        txclk_pat;
    wire [3:0]  txd_pat;

    // ------------------------------------------------------------------
    // Capture front-end (reused from Stage-2). Runtime tap from eyescan.
    // ------------------------------------------------------------------
    wire        trace_clk;
    wire [3:0]  trace_a, trace_b;
    wire        idelayctrl_rdy;
    wire [4:0]  tap;
    wire        tap_load;

    trace_capture_a7 #(.CLK_BUF("BUFR_IO")) u_capture (
        .rst           (sys_rst),
        .ref_200m      (clk200),
        .trace_clk_p   (trace_clk_in),
        .trace_data_p  (trace_data_in),
        .tap_data0     (tap),
        .tap_data1     (tap),
        .tap_data2     (tap),
        .tap_data3     (tap),
        .tap_load      (tap_load),
        .trace_clk     (trace_clk),
        .trace_a       (trace_a),
        .trace_b       (trace_b),
        .idelayctrl_rdy(idelayctrl_rdy)
    );

    // ------------------------------------------------------------------
    // traceIF (UPSTREAM, sim-proven): locks the 0x7FFF_FFFF sync word and
    // emits decoded 128-bit frames. This is the validity judge for the
    // eye-scan, replacing the home-grown bit checker.
    // ------------------------------------------------------------------
    wire         fr_avail;
    wire [127:0] frame;
    traceIF #(.MAXBUSWIDTH(4)) u_traceif (
        .rst        (sys_rst | ~idelayctrl_rdy),
        .traceDina  (trace_a),
        .traceDinb  (trace_b),
        .traceClkin (trace_clk),
        .width      (2'b11),       // 4-bit
        .edgeOutput (),
        .FrAvail    (fr_avail),
        .Frame      (frame)
    );

    // ------------------------------------------------------------------
    // Eye-scan engine: pattern gen + tap sweep + per-tap frame tally,
    // judged from traceIF's FrAvail/Frame.
    // ------------------------------------------------------------------
    wire [7:0] ext_addr;
    wire [7:0] ext_data;
    wire       scan_done, eye_found;
    wire [4:0] best_tap;

    trace_eyescan #(.WIN_BITS(18)) u_eye (
        .rst           (sys_rst),
        .clk_tx        (clk100),
        .txclk_out     (txclk_pat),
        .txd_out       (txd_pat),
        .tap           (tap),
        .tap_load      (tap_load),
        .idelayctrl_rdy(idelayctrl_rdy),
        .trace_clk     (trace_clk),
        .fr_avail      (fr_avail),
        .frame         (frame),
        .rd_addr       (ext_addr),
        .rd_data       (ext_data),
        .scan_done     (scan_done),
        .best_tap      (best_tap),
        .eye_found     (eye_found)
    );

    assign txclk_out = txclk_pat;
    assign txd_out   = txd_pat;

    // ------------------------------------------------------------------
    // Ethernet stack: UDP readout of the eye table on port 5001.
    // ------------------------------------------------------------------
    wire [7:0] led_eth;
    fpga_core_net #(.TARGET("XILINX")) u_eth (
        .clk(clk125), .clk90(clk125_90), .rst(sys_rst),
        .btnu(1'b0), .btnl(1'b0), .btnd(1'b0), .btnr(1'b0), .btnc(1'b0),
        .sw(8'h0), .led(led_eth),
        .phy_rx_clk(phy_rx_clk),
        .phy_rxd(phy_rxd),
        .phy_rx_ctl(phy_rx_ctl),
        .phy_tx_clk(phy_tx_clk),
        .phy_txd(phy_txd),
        .phy_tx_ctl(phy_tx_ctl),
        .phy_reset_n(phy_reset_n),
        .phy_int_n(1'b1),
        .phy_pme_n(1'b1),
        .uart_rxd(1'b1),
        .uart_txd(),
        .dbg_rx_good_frame(),
        .dbg_rx_bad_fcs(),
        .dbg_tx_axis_tvalid(),
        .ext_addr(ext_addr),
        .ext_data(ext_data)
    );

    assign phy_mdio = 1'bz;
    assign phy_mdc  = 1'b0;

    // ------------------------------------------------------------------
    // LEDs (active-low). LED0 = IDELAYCTRL ready (steady on when ready).
    // LED1 = scan status: off=scanning, slow blink=done+eye found,
    // fast blink=done but NO clean tap (signal-integrity problem).
    // ------------------------------------------------------------------
    reg [26:0] cnt = 0;
    always @(posedge clk100) cnt <= cnt + 1'b1;
    wire slow = cnt[24];
    wire fast = cnt[21];

    assign led0 = ~idelayctrl_rdy;

    reg led1_r;
    always @(*) begin
        if (!scan_done)     led1_r = 1'b0;
        else if (eye_found) led1_r = slow;
        else                led1_r = fast;
    end
    assign led1 = ~led1_r;

endmodule

`default_nettype wire
