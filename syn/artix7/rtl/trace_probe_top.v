// trace_probe_top
// =================
// Minimal Stage-2 T4 integration top for the Artix-7 trace probe.
// Brings together all three OOC-validated blocks into a single design with
// real board pins and real clock constraints, so we can get post-implement
// utilization and timing slack — the authoritative "fits on 35T?" answer.
//
// Datapath (intentionally minimal; full plumbing is Stage-3 on-board PoC):
//
//   board pins ──► trace_capture_a7 ──► traceIF ──► tpiu_demux
//                  (T2 skeleton)        (T3)        (T3)
//                                                       │
//                                                       ▼
//                                                checksum_appender
//                                                       │
//                                                       ▼
//                                                cobs_encoder
//                                                       │
//                                                       ▼
//                                                super_framer
//                                                       │
//                                                       ▼ (8b stream sink)
//                                                  network out
//
// The gigabit Ethernet stack (verilog-ethernet's NexysVideo fpga_core, T1)
// is instantiated in parallel; its UDP RX/TX is left "tied off" with simple
// pass-through so the synthesis is real (not optimized away to nothing) but
// the actual UDP-to-trace bridging is left for Stage-3.
//
// Clocks:
//   sys_clk_50  : 50 MHz from board crystal (CLK_50M @J19 on A7-Lite)
//   clk125      : RGMII gigabit clock, derived from MMCM
//   clk200      : IDELAYCTRL reference, derived from MMCM
//   trace_clk   : recovered from TRACECLK (via trace_capture_a7)

`default_nettype none

module trace_probe_top (
    // Board oscillator + reset
    input  wire        sys_clk_50,
    input  wire        rst_n,

    // ARM trace pins (via GPIO1 / Bank 16, see PLAN_STAGE2 §T5)
    input  wire        trace_clk_in,    // GPIO1_4P / D17 (MRCC)
    input  wire [3:0]  trace_data_in,   // 4 lanes from GPIO1 Bank 16

    // RGMII gigabit Ethernet (RTL8211, on-board)
    input  wire        phy_rx_clk,
    input  wire [3:0]  phy_rxd,
    input  wire        phy_rx_ctl,
    output wire        phy_tx_clk,
    output wire [3:0]  phy_txd,
    output wire        phy_tx_ctl,
    output wire        phy_reset_n,
    inout  wire        phy_mdio,
    output wire        phy_mdc,

    // LEDs (sanity)
    output wire        led0,
    output wire        led1
);

    wire rst = ~rst_n;

    // ------------------------------------------------------------------
    // MMCM: 50MHz -> { 125MHz (RGMII clk), 125MHz @90° (RGMII clk90),
    //                  200MHz (IDELAYCTRL), 100MHz (sys) }
    // The 90° offset clk125 is required by ssio_ddr_out for the RGMII TX
    // clock to be source-synchronous-correct (data clocked on clk, clock
    // pin driven by clk90 so the centre-aligned eye lands at the PHY).
    // ------------------------------------------------------------------
    wire clkfb;
    wire clk125_unbuf, clk125_90_unbuf, clk200_unbuf, clk100_unbuf;
    wire mmcm_locked;

    MMCME2_BASE #(
        .CLKIN1_PERIOD(20.0),     // 50MHz -> 20ns
        .CLKFBOUT_MULT_F(20.0),   // VCO = 1000MHz
        .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(8.0),   // 125MHz, 0°
        .CLKOUT1_DIVIDE(8),       // 125MHz, 90° (RGMII TX)
        .CLKOUT1_PHASE(90.0),
        .CLKOUT2_DIVIDE(5),       // 200MHz (IDELAYCTRL)
        .CLKOUT3_DIVIDE(10),      // 100MHz sys
        .CLKOUT0_PHASE(0.0),
        .CLKOUT2_PHASE(0.0),
        .CLKOUT3_PHASE(0.0)
    ) u_mmcm (
        .CLKIN1   (sys_clk_50),
        .CLKFBIN  (clkfb),
        .CLKFBOUT (clkfb),
        .CLKOUT0  (clk125_unbuf),
        .CLKOUT1  (clk125_90_unbuf),
        .CLKOUT2  (clk200_unbuf),
        .CLKOUT3  (clk100_unbuf),
        .LOCKED   (mmcm_locked),
        .RST      (rst),
        .PWRDWN   (1'b0)
    );

    wire clk125, clk125_90, clk200, clk100;
    BUFG u_bg125   (.I(clk125_unbuf),    .O(clk125));
    BUFG u_bg125_90(.I(clk125_90_unbuf), .O(clk125_90));
    BUFG u_bg200   (.I(clk200_unbuf),    .O(clk200));
    BUFG u_bg100   (.I(clk100_unbuf),    .O(clk100));

    // Reset stretching: hold rst high until MMCM locks.
    reg [3:0] rst_sync;
    always @(posedge clk100 or posedge rst)
        if (rst) rst_sync <= 4'hf;
        else     rst_sync <= {rst_sync[2:0], ~mmcm_locked};
    wire sys_rst = rst_sync[3];

    // ------------------------------------------------------------------
    // T2: trace capture front-end (IDDR + IDELAYE2 + IDELAYCTRL)
    // ------------------------------------------------------------------
    wire        trace_clk;
    wire [3:0]  trace_a, trace_b;
    wire        idelayctrl_rdy;

    trace_capture_a7 u_capture (
        .rst           (sys_rst),
        .ref_200m      (clk200),
        .trace_clk_p   (trace_clk_in),
        .trace_data_p  (trace_data_in),
        .tap_data0     (5'd16),
        .tap_data1     (5'd16),
        .tap_data2     (5'd16),
        .tap_data3     (5'd16),
        .tap_load      (1'b0),
        .trace_clk     (trace_clk),
        .trace_a       (trace_a),
        .trace_b       (trace_b),
        .idelayctrl_rdy(idelayctrl_rdy)
    );

    // ------------------------------------------------------------------
    // T3 - traceIF: combine rising/falling nibble samples into TPIU frames
    // ------------------------------------------------------------------
    wire        fr_avail;
    wire [127:0] frame128;
    wire         tif_rst = sys_rst | ~idelayctrl_rdy;

    traceIF #(.MAXBUSWIDTH(4)) u_traceif (
        .rst        (tif_rst),
        .traceDina  (trace_a),
        .traceDinb  (trace_b),
        .traceClkin (trace_clk),
        .width      (2'b11),         // 4-bit
        .edgeOutput (),
        .FrAvail    (fr_avail),
        .Frame      (frame128)
    );

    // ------------------------------------------------------------------
    // Cross from trace_clk domain to clk100 (sys). For T4 sizing we use a
    // simple 2-FF synchroniser on a derived "frame valid pulse" + register
    // the frame data; this is *not* the production CDC (orbtrace uses an
    // AsyncFIFO). It keeps the front-end and back-end timing-isolated for
    // synthesis purposes.
    // ------------------------------------------------------------------
    reg fr_avail_meta, fr_avail_sync, fr_avail_d;
    always @(posedge clk100) {fr_avail_d, fr_avail_sync, fr_avail_meta} <= {fr_avail_sync, fr_avail_meta, fr_avail};
    wire fr_pulse = fr_avail_sync ^ fr_avail_d;

    reg [127:0] frame_lat;
    always @(posedge clk100) if (fr_pulse) frame_lat <= frame128;

    // ------------------------------------------------------------------
    // T3 - TPIU demux + checksum + COBS + super-framer (clk100 domain)
    // ------------------------------------------------------------------
    wire dmux_in_ready;
    wire dmux_out_valid; wire dmux_out_data_8 = 1'b0; // unused vars retained for synthesis
    wire dmux_out_data_b; wire dmux_out_last;
    wire [7:0] dmux_data;

    // For sizing: drive in_valid from fr_pulse; in_frame from frame_lat.
    // (Production handshaking is more careful; sizing isn't sensitive.)
    tpiu_demux u_dmux (
        .clk        (clk100),
        .rst        (sys_rst),
        .in_valid   (fr_pulse),
        .in_ready   (dmux_in_ready),
        .in_frame   (frame_lat),
        .bp_valid   (1'b0),
        .bp_ready   (),
        .bp_data    (8'd0),
        .bypass_sel (1'b0),
        .out_valid  (dmux_out_valid),
        .out_ready  (1'b1),
        .out_data   (dmux_data),
        .out_last   (dmux_out_last)
    );

    wire chk_out_valid; wire [7:0] chk_data; wire chk_out_last;
    checksum_appender u_chk (
        .clk        (clk100),
        .rst        (sys_rst),
        .in_valid   (dmux_out_valid),
        .in_ready   (),
        .in_data    (dmux_data),
        .in_last    (dmux_out_last),
        .out_valid  (chk_out_valid),
        .out_ready  (1'b1),
        .out_data   (chk_data),
        .out_last   (chk_out_last)
    );

    wire cobs_out_valid; wire [7:0] cobs_data; wire cobs_out_last;
    cobs_encoder u_cobs (
        .clk        (clk100),
        .rst        (sys_rst),
        .in_valid   (chk_out_valid),
        .in_ready   (),
        .in_data    (chk_data),
        .in_last    (chk_out_last),
        .out_valid  (cobs_out_valid),
        .out_ready  (1'b1),
        .out_data   (cobs_data),
        .out_last   (cobs_out_last)
    );

    wire sf_out_valid; wire [7:0] sf_data; wire sf_out_last;
    super_framer u_sf (
        .clk        (clk100),
        .rst        (sys_rst),
        .in_valid   (cobs_out_valid),
        .in_ready   (),
        .in_data    (cobs_data),
        .in_last    (cobs_out_last),
        .out_valid  (sf_out_valid),
        .out_ready  (1'b1),
        .out_data   (sf_data),
        .out_last   (sf_out_last)
    );

    // ------------------------------------------------------------------
    // T1: gigabit Ethernet stack (verilog-ethernet NexysVideo fpga_core).
    // For T4 sizing we instantiate fpga_core with the SF byte stream gated
    // into the sw input so the synthesizer cannot prune it. Real UDP-trace
    // bridging is Stage-3 work.
    //
    // TARGET="XILINX" is required: oddr.v / iddr.v default to a "GENERIC"
    // behavioural model that uses two always blocks driving the same reg,
    // which Vivado flags as a multiple-driver DRC. Setting TARGET="XILINX"
    // selects the proper ODDR/IDDR primitive instantiation.
    // ------------------------------------------------------------------
    fpga_core #(
        .TARGET("XILINX")
    ) u_eth (
        .clk         (clk125),
        .clk90       (clk125_90),
        .rst         (sys_rst),
        .btnu(1'b0), .btnl(1'b0), .btnd(1'b0), .btnr(1'b0), .btnc(1'b0),
        .sw          ({3'b0, sf_out_valid, sf_data[3:0]}),
        .led         (),
        .phy_rx_clk  (phy_rx_clk),
        .phy_rxd     (phy_rxd),
        .phy_rx_ctl  (phy_rx_ctl),
        .phy_tx_clk  (phy_tx_clk),
        .phy_txd     (phy_txd),
        .phy_tx_ctl  (phy_tx_ctl),
        .phy_reset_n (phy_reset_n),
        .phy_int_n   (1'b1),
        .phy_pme_n   (1'b1),
        .uart_rxd    (1'b1),
        .uart_txd    ()
    );

    // PHY mgmt tied off (real management TBD in stage-3)
    assign phy_mdio = 1'bz;
    assign phy_mdc  = 1'b0;

    assign led0 = idelayctrl_rdy;
    assign led1 = sf_out_valid;

endmodule

`default_nettype wire
