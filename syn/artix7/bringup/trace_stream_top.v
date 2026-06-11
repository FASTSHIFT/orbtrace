// trace_stream_top
// ================
// Stage-4 V3: fix the IDELAY tap (V2 eye centre) and capture a contiguous
// block of the RAW trace byte stream (the TPIU bytes that traceIF consumes:
// {trace_b, trace_a} per trace_clk) into a deep BRAM, one-shot. The PC reads
// the whole block out over UDP :5001 and saves it to a file for offline
// decode by Orbuculum (orbmortem -P ETM3.5 -e proj.axf).
//
//   STM32 ETM ── trace_capture_a7 (BUFR_IO, tap=TAP) ── {trace_b,trace_a}
//                                                             |
//                                          one-shot fill -> capture BRAM (DEPTH)
//                                                             |
//                                            UDP :5001 paged readout (16-bit addr)
//
// Capture starts after IDELAYCTRL ready + tap load, and freezes once full so
// the PC reads a stable snapshot. Re-arm by reconfiguring (reset).

`default_nettype none

module trace_stream_top #(
    parameter [4:0] TAP   = 5'd28,    // V2 eye centre
    parameter       DEPTH = 16384     // captured bytes (16 KB)
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

    input  wire        trace_clk_in,
    input  wire [3:0]  trace_data_in,

    output wire        led0,   // idelayctrl ready
    output wire        led1    // capture full (steady) / filling (off)
);

    wire rst = ~rst_n;

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
    BUFG b0(.I(clk125_u), .O(clk125));
    BUFG b1(.I(clk125_90_u), .O(clk125_90));
    BUFG b2(.I(clk200_u), .O(clk200));
    BUFG b3(.I(clk100_u), .O(clk100));

    reg [3:0] rst_sync = 4'hf;
    always @(posedge clk100 or posedge rst)
        if (rst) rst_sync <= 4'hf;
        else     rst_sync <= {rst_sync[2:0], ~mmcm_locked};
    wire sys_rst = rst_sync[3];

    // capture front-end (BUFR_IO, fixed tap)
    wire        trace_clk;
    wire [3:0]  trace_a, trace_b;
    wire        idelayctrl_rdy;

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
        .rst(sys_rst), .ref_200m(clk200),
        .trace_clk_p(trace_clk_in), .trace_data_p(trace_data_in),
        .tap_data0(TAP), .tap_data1(TAP), .tap_data2(TAP), .tap_data3(TAP),
        .tap_load(tap_load),
        .trace_clk(trace_clk), .trace_a(trace_a), .trace_b(trace_b),
        .idelayctrl_rdy(idelayctrl_rdy)
    );

    // raw byte stream = {trace_b, trace_a} per trace_clk (the TPIU bytes)
    wire [7:0] raw_byte = {trace_b, trace_a};

    // traceIF only used as a link-health gate: start capturing once sync seen
    wire        fr_avail;
    wire [127:0] frame_unused;
    traceIF #(.MAXBUSWIDTH(4)) u_traceif (
        .rst(sys_rst | ~idelayctrl_rdy),
        .traceDina(trace_a), .traceDinb(trace_b), .traceClkin(trace_clk),
        .width(2'b11), .edgeOutput(), .FrAvail(fr_avail), .Frame(frame_unused)
    );
    reg fr_q, sync_seen;
    always @(posedge trace_clk or posedge sys_rst) begin
        if (sys_rst) begin fr_q <= 0; sync_seen <= 0; end
        else begin
            fr_q <= fr_avail;
            if (fr_avail ^ fr_q) sync_seen <= 1'b1;   // a frame decoded => synced
        end
    end

    // one-shot capture BRAM (trace_clk write, clk125 read). Clean simple-
    // dual-port pattern (no reset on the array) so it infers as block RAM.
    localparam AW = $clog2(DEPTH);
    (* ram_style = "block" *)
    reg [7:0] capmem [0:DEPTH-1];
    reg [AW:0] wr_ptr;          // extra bit to detect full
    wire full = wr_ptr[AW];
    wire wr_en = sync_seen && !full;
    always @(posedge trace_clk) begin
        if (wr_en) capmem[wr_ptr[AW-1:0]] <= raw_byte;
    end
    always @(posedge trace_clk or posedge sys_rst) begin
        if (sys_rst) wr_ptr <= 0;
        else if (wr_en) wr_ptr <= wr_ptr + 1'b1;
    end

    // UDP readout: ext_addr (16-bit) indexes capmem; beyond DEPTH return
    // status (DEPTH and full flag) so the PC knows size/ready.
    wire [15:0] ext_addr;
    reg  [7:0]  cap_rd;
    always @(posedge clk125) cap_rd <= capmem[ext_addr[AW-1:0]];
    wire [7:0] ext_data = (ext_addr < DEPTH) ? cap_rd :
                          (ext_addr == DEPTH+0) ? DEPTH[7:0] :
                          (ext_addr == DEPTH+1) ? DEPTH[15:8] :
                          (ext_addr == DEPTH+2) ? {7'b0, full} : 8'h00;

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

    assign led0 = ~idelayctrl_rdy;
    assign led1 = ~full;     // off while filling, on (steady low) when full

endmodule

`default_nettype wire
