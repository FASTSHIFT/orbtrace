// trace_stream_top
// ================
// Stage-4 V3 step 1: fix the IDELAY tap (from V2's eye centre) and stream the
// REAL decoded trace frames out over UDP so the PC can inspect/decode them.
//
//   STM32 ETM pins ── trace_capture_a7 (BUFR_IO, tap=TAP) ── traceIF
//        |                                                      |
//        |                                            FrAvail + Frame(128b)
//        v                                                      v
//   (board jumpers, GPIO1)                         frame ring buffer (trace_clk)
//                                                              |
//                                          UDP :5001 readout (ext hook in eth)
//
// PC sends any frame to :5001 -> reply = the last N captured 128-bit frames
// (N*16 bytes), newest-last. See trace_stream_read.py.
//
// No pattern generator here (STM32 drives the pins). Tap is a build-time
// parameter (default 28, the V2 eye centre).

`default_nettype none

module trace_stream_top #(
    parameter [4:0] TAP   = 5'd28,   // V2 eye centre
    parameter       NFRM  = 8        // ring depth (frames); UDP reply = NFRM*16 B
) (
    input  wire        sys_clk_50,
    input  wire        rst_n,

    input  wire        phy_rx_clk,
    input  wire [3:0]  phy_rxd,
    input  wire        phy_rx_ctl,
    output wire        phy_tx_clk,
    output wire [3:0]  phy_txd,
    output wire        phy_tx_ctl,
    output wire        phy_reset_n,
    inout  wire        phy_mdio,
    output wire        phy_mdc,

    // Trace capture IN (from STM32 PE2..PE6)
    input  wire        trace_clk_in,
    input  wire [3:0]  trace_data_in,

    output wire        led0,   // idelayctrl ready
    output wire        led1    // toggles while frames arrive (activity)
);

    wire rst = ~rst_n;

    // ---- MMCM: 125 / 125@90 / 200 / 100 ----
    wire clkfb, clk125_u, clk125_90_u, clk200_u, clk100_u, mmcm_locked;
    MMCME2_BASE #(
        .CLKIN1_PERIOD(20.0), .CLKFBOUT_MULT_F(20.0), .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(8.0),
        .CLKOUT1_DIVIDE(8), .CLKOUT1_PHASE(90.0),
        .CLKOUT2_DIVIDE(5), .CLKOUT3_DIVIDE(10),
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

    // ---- capture front-end: BUFR_IO, fixed tap ----
    wire        trace_clk;
    wire [3:0]  trace_a, trace_b;
    wire        idelayctrl_rdy;

    // one-shot tap load after IDELAYCTRL ready
    reg [3:0] ld_sync = 4'h0;
    reg       loaded  = 1'b0;
    reg       tap_load = 1'b0;
    always @(posedge clk200 or posedge sys_rst) begin
        if (sys_rst) begin ld_sync <= 0; loaded <= 0; tap_load <= 0; end
        else begin
            ld_sync <= {ld_sync[2:0], idelayctrl_rdy};
            tap_load <= 1'b0;
            if (ld_sync[3] && !loaded) begin tap_load <= 1'b1; loaded <= 1'b1; end
        end
    end

    trace_capture_a7 #(.CLK_BUF("BUFR_IO")) u_capture (
        .rst           (sys_rst),
        .ref_200m      (clk200),
        .trace_clk_p   (trace_clk_in),
        .trace_data_p  (trace_data_in),
        .tap_data0     (TAP), .tap_data1(TAP), .tap_data2(TAP), .tap_data3(TAP),
        .tap_load      (tap_load),
        .trace_clk     (trace_clk),
        .trace_a       (trace_a),
        .trace_b       (trace_b),
        .idelayctrl_rdy(idelayctrl_rdy)
    );

    // ---- traceIF: decode frames ----
    wire         fr_avail;
    wire [127:0] frame;
    traceIF #(.MAXBUSWIDTH(4)) u_traceif (
        .rst        (sys_rst | ~idelayctrl_rdy),
        .traceDina  (trace_a),
        .traceDinb  (trace_b),
        .traceClkin (trace_clk),
        .width      (2'b11),
        .edgeOutput (),
        .FrAvail    (fr_avail),
        .Frame      (frame)
    );

    // ---- frame ring buffer (trace_clk domain) ----
    // Store the most recent NFRM frames as a flat NFRM*16-byte memory,
    // readable byte-wise by the PC. frame_strobe = FrAvail toggle.
    reg fr_q;
    wire frame_strobe = fr_avail ^ fr_q;
    always @(posedge trace_clk) fr_q <= fr_avail;

    localparam NB = NFRM*16;            // bytes
    (* ram_style = "distributed" *)
    reg [7:0] ring [0:NB-1];
    reg [$clog2(NFRM)-1:0] wr_frm;
    integer k;
    reg [31:0] frame_count;
    always @(posedge trace_clk) begin
        if (sys_rst) begin
            wr_frm <= 0;
            frame_count <= 0;
        end else if (frame_strobe) begin
            // write 16 bytes of `frame` (MSB first) into slot wr_frm
            for (k = 0; k < 16; k = k + 1)
                ring[wr_frm*16 + k] <= frame[8*(15-k) +: 8];
            wr_frm <= wr_frm + 1'b1;
            frame_count <= frame_count + 1'b1;
        end
    end

    // ---- UDP readout via ext hook ----
    wire [7:0] ext_addr, ext_data;
    // addr 0..NB-1 -> ring bytes ; NB..NB+3 -> frame_count (LE)
    assign ext_data = (ext_addr < NB)        ? ring[ext_addr] :
                      (ext_addr == NB+0)     ? frame_count[7:0]   :
                      (ext_addr == NB+1)     ? frame_count[15:8]  :
                      (ext_addr == NB+2)     ? frame_count[23:16] :
                      (ext_addr == NB+3)     ? frame_count[31:24] :
                      (ext_addr == NB+4)     ? {3'b0, wr_frm}     : 8'h00;

    fpga_core_net #(.TARGET("XILINX")) u_eth (
        .clk(clk125), .clk90(clk125_90), .rst(sys_rst),
        .btnu(1'b0), .btnl(1'b0), .btnd(1'b0), .btnr(1'b0), .btnc(1'b0),
        .sw(8'h0), .led(),
        .phy_rx_clk(phy_rx_clk), .phy_rxd(phy_rxd), .phy_rx_ctl(phy_rx_ctl),
        .phy_tx_clk(phy_tx_clk), .phy_txd(phy_txd), .phy_tx_ctl(phy_tx_ctl),
        .phy_reset_n(phy_reset_n),
        .phy_int_n(1'b1), .phy_pme_n(1'b1),
        .uart_rxd(1'b1), .uart_txd(),
        .dbg_rx_good_frame(), .dbg_rx_bad_fcs(), .dbg_tx_axis_tvalid(),
        .ext_addr(ext_addr), .ext_data(ext_data)
    );

    assign phy_mdio = 1'bz;
    assign phy_mdc  = 1'b0;

    // ---- LEDs ----
    reg [26:0] cnt = 0;
    always @(posedge clk100) cnt <= cnt + 1'b1;
    // led1 reflects frame activity: light if any frame has arrived
    reg seen;
    always @(posedge trace_clk or posedge sys_rst)
        if (sys_rst) seen <= 1'b0; else if (frame_strobe) seen <= 1'b1;
    assign led0 = ~idelayctrl_rdy;
    assign led1 = ~(seen & cnt[24]);

endmodule

`default_nettype wire
