// selftx_test_top
// ===============
// Standalone validation of fpga_core_net's self-initiated streaming UDP TX
// (proposal 18 stage 2 / r19 Q2: prove the self-TX path — no RX trigger, fixed
// dest, ARP — works in ISOLATION before coupling it to the SWO FIFO).
//
// Feeds the core a free-running 8-bit counter as the stream payload. On the PC
// you should see continuous UDP packets arriving at STREAM_DEST_IP:5555 whose
// payload is a 0,1,2,...,255,0,... ramp (split across 1024-byte packets). The
// existing :5001/:5002 RX-echo must still respond (arbitration intact).
//
//   PC: nc -u -l 5555 | xxd | head     (or tcpdump -A -i <if> udp port 5555)

`default_nettype none

module selftx_test_top #(
    // r20 clean discriminator: STREAM=0 strips the self-TX FSM entirely
    // (selects fpga_core_net g_echo_only -> pure RX echo, no self_busy), so
    // :5001 echo isolates whether THIS new top-level's link/clock/reset is up.
    //   echo works  -> link OK on new top  -> zero-packet bug is in FSM/header
    //   echo silent -> link not up on new top (root-cause A) -> stop here,
    //                  add STREAM to the known-good swo_stream_top instead.
    parameter STREAM = 1
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

    output wire        led0,
    output wire        led1
);
    wire rst = ~rst_n;

    wire clkfb, clk125_u, clk125_90_u, clk100_u, mmcm_locked;
    MMCME2_BASE #(
        .CLKIN1_PERIOD(20.0), .CLKFBOUT_MULT_F(20.0), .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(8.0),
        .CLKOUT1_DIVIDE(8), .CLKOUT1_PHASE(90.0),
        .CLKOUT3_DIVIDE(10),
        .CLKOUT0_PHASE(0.0), .CLKOUT3_PHASE(0.0)
    ) u_mmcm (
        .CLKIN1(sys_clk_50), .CLKFBIN(clkfb), .CLKFBOUT(clkfb),
        .CLKOUT0(clk125_u), .CLKOUT1(clk125_90_u),
        .CLKOUT3(clk100_u),
        .LOCKED(mmcm_locked), .RST(rst), .PWRDWN(1'b0)
    );
    wire clk125, clk125_90, clk100;
    BUFG b0(.I(clk125_u), .O(clk125));
    BUFG b1(.I(clk125_90_u), .O(clk125_90));
    BUFG b3(.I(clk100_u), .O(clk100));

    reg [3:0] rst_sync = 4'hf;
    always @(posedge clk100 or posedge rst)
        if (rst) rst_sync <= 4'hf;
        else     rst_sync <= {rst_sync[2:0], ~mmcm_locked};
    wire sys_rst = rst_sync[3];

    // counter payload source, throttled a bit so it doesn't saturate (this is a
    // connectivity test, not a throughput test). Produce a byte whenever ready.
    reg [7:0] ramp = 0;
    wire stream_tready;
    wire stream_tvalid = 1'b1;          // always have data
    always @(posedge clk125)
        if (sys_rst) ramp <= 0;
        else if (stream_tvalid && stream_tready) ramp <= ramp + 1'b1;

    fpga_core_net #(
        .TARGET("XILINX"),
        .STREAM(STREAM),
        .STREAM_DEST_IP({8'd192, 8'd168, 8'd10, 8'd245}),
        .STREAM_DEST_PORT(16'd5555),
        .STREAM_PKT_BYTES(16'd1024)
    ) u_eth (
        .clk(clk125), .clk90(clk125_90), .rst(sys_rst),
        .btnu(1'b0), .btnl(1'b0), .btnd(1'b0), .btnr(1'b0), .btnc(1'b0),
        .sw(8'h0), .led(),
        .phy_rx_clk(phy_rx_clk), .phy_rxd(phy_rxd), .phy_rx_ctl(phy_rx_ctl),
        .phy_tx_clk(phy_tx_clk), .phy_txd(phy_txd), .phy_tx_ctl(phy_tx_ctl),
        .phy_reset_n(phy_reset_n),
        .phy_int_n(1'b1), .phy_pme_n(1'b1),
        .uart_rxd(1'b1), .uart_txd(),
        .dbg_rx_good_frame(), .dbg_rx_bad_fcs(), .dbg_tx_axis_tvalid(),
        .ext_addr(), .ext_data(8'h0),
        .csr_addr(), .csr_data(), .csr_we(),
        .stream_tdata(ramp), .stream_tvalid(stream_tvalid), .stream_tready(stream_tready)
    );

    assign phy_mdio = 1'bz;
    assign phy_mdc  = 1'b0;
    assign led0 = ~mmcm_locked;
    assign led1 = ramp[7];
endmodule

`default_nettype wire
