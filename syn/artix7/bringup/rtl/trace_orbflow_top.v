// trace_orbflow_top
// =================
// Stage-4 V3 "A route": complete the orbtrace pipeline ON THE FPGA so the PC
// receives a native OrbFlow (OFLOW) byte stream that orbuculum/orbcat decode
// directly — no PC-side byte-order guessing.
//
// This replaces the raw/traceIF-frame capture of trace_stream_top with the
// full orbtrace post-processing chain, exactly as orbtrace/orbtrace/trace/
// core.py wires it for the trace path (input_format 0x01..0x03):
//
//   STM32 ETM ─ trace_capture_a7 (BUFR_IO, tap=TAP) ─ {trace_b,trace_a}
//                                                            │
//                                            traceIF (128-bit TPIU frame)
//                                                            │  (trace_clk)
//                                       axis_async_fifo  trace_clk → clk100
//                                                            │
//                                                      tpiu_demux           ┐
//                                                            │              │
//                                                  checksum_appender        │ clk100
//                                                            │              │ orbtrace
//                                                       cobs_encoder        │ pipeline
//                                                            │              │
//                                                       super_framer        ┘
//                                                            │
//                                          one-shot OrbFlow byte capture (BRAM)
//                                                            │
//                                            UDP :5001 paged readout (16-bit addr)
//
// The captured bytes are a valid OFLOW stream. Decode on the PC with:
//   python3 trace_dump.py --ip 192.168.10.42 --depth 61440 -o /tmp/oflow.bin
//   orbcat -f /tmp/oflow.bin -p OFLOW -t 1 -E        (or orbmortem -P ETM3.5)
//
// Capture is one-shot and freezes when full (LED1 steady). Re-arm by
// reconfiguring (reset / re-burn). Correct ordering: configure STM32 ETM
// FIRST, then (re)burn the FPGA so this one-shot capture arms on live data.

`default_nettype none

module trace_orbflow_top #(
    parameter [4:0] TAP   = 5'd28,    // V2 eye centre
    parameter       DEPTH = 61440,    // captured OrbFlow bytes (keep < 65536
                                      // so 16-bit ext_addr also reaches the
                                      // status bytes at DEPTH..+2)
    parameter       SWAP_NIBBLES = 0  // 0: traceDina=trace_a (rising-edge);
                                      // 1: swap trace_a/trace_b into traceIF.
                                      // Reuse audit (doc 10) found the raw
                                      // capture only assembles TPIU frames in
                                      // the swapped nibble order, so this lets
                                      // the next capture test both cheaply.
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

    // ------------------------------------------------------------------
    // Clocking: 50 MHz -> 125/125@90/200/100 MHz
    // ------------------------------------------------------------------
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

    // ------------------------------------------------------------------
    // Capture front-end (BUFR_IO, fixed tap) + IDELAYCTRL one-shot tap load
    // ------------------------------------------------------------------
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
        .tap_clk(5'd0),
        .tap_load(tap_load),
        .trace_clk(trace_clk), .trace_a(trace_a), .trace_b(trace_b),
        .idelayctrl_rdy(idelayctrl_rdy)
    );

    // ------------------------------------------------------------------
    // traceIF: assemble byte-aligned 16-byte TPIU frames (trace_clk domain).
    // ------------------------------------------------------------------
    wire        fr_avail;
    wire [127:0] frame;
    wire [3:0]  tif_a = SWAP_NIBBLES ? trace_b : trace_a;
    wire [3:0]  tif_b = SWAP_NIBBLES ? trace_a : trace_b;
    traceIF #(.MAXBUSWIDTH(4)) u_traceif (
        .rst(sys_rst | ~idelayctrl_rdy),
        .traceDina(tif_a), .traceDinb(tif_b), .traceClkin(trace_clk),
        .width(2'b11), .edgeOutput(), .FrAvail(fr_avail), .Frame(frame)
    );

    // Toggle-strobe from reset-less isolation flops (clears DRC REQP-1840 on
    // the FIFO write-enable path; same pattern as trace_probe_top).
    reg fr_iso, fr_q;
    always @(posedge trace_clk) begin
        fr_iso <= fr_avail;
        fr_q   <= fr_iso;
    end
    wire frame_strobe = fr_iso ^ fr_q;

    // ------------------------------------------------------------------
    // CDC trace_clk -> clk100 for the 128-bit frame (Gray-pointer AsyncFIFO,
    // the same primitive the Ethernet stack trusts; a 1-bit toggle sync
    // cannot safely carry 128 wires — see trace_probe_top notes).
    // ------------------------------------------------------------------
    wire         cdc_out_valid;
    wire         cdc_in_ready;
    wire [127:0] cdc_out_frame;
    wire         dmux_in_ready;

    axis_async_fifo #(
        .DEPTH(16), .DATA_WIDTH(128),
        .KEEP_ENABLE(0), .LAST_ENABLE(0), .USER_ENABLE(0), .FRAME_FIFO(0)
    ) u_frame_cdc (
        .s_clk(trace_clk), .s_rst(sys_rst),
        .s_axis_tdata(frame), .s_axis_tkeep(16'h0),
        .s_axis_tvalid(frame_strobe), .s_axis_tready(cdc_in_ready),
        .s_axis_tlast(1'b0), .s_axis_tid(8'h0), .s_axis_tdest(8'h0), .s_axis_tuser(1'b0),
        .m_clk(clk100), .m_rst(sys_rst),
        .m_axis_tdata(cdc_out_frame), .m_axis_tkeep(),
        .m_axis_tvalid(cdc_out_valid), .m_axis_tready(dmux_in_ready),
        .m_axis_tlast(), .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(),
        .s_pause_req(1'b0), .s_pause_ack(), .m_pause_req(1'b0), .m_pause_ack(),
        .s_status_depth(), .s_status_depth_commit(), .s_status_overflow(),
        .s_status_bad_frame(), .s_status_good_frame(),
        .m_status_depth(), .m_status_depth_commit(), .m_status_overflow(),
        .m_status_bad_frame(), .m_status_good_frame()
    );

    // Overflow accounting (traceIF cannot be back-pressured).
    wire fifo_overflow_evt = frame_strobe & ~cdc_in_ready;
    reg [15:0] trace_lost_cnt;
    always @(posedge trace_clk)
        if (sys_rst)                trace_lost_cnt <= 16'd0;
        else if (fifo_overflow_evt) trace_lost_cnt <= trace_lost_cnt + 16'd1;

    // ------------------------------------------------------------------
    // Byte-order: orbtrace's TraceIF presents payload[0]=Frame[127:120]
    // (MSB byte first), and tpiu_demux maps in_frame[7:0]->payload[0]. So
    // feed tpiu_demux a byte-reversed frame to match the reference order.
    // ------------------------------------------------------------------
    wire [127:0] dmux_in_frame;
    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : g_byterev
            assign dmux_in_frame[8*gi +: 8] = cdc_out_frame[8*(15-gi) +: 8];
        end
    endgenerate

    // ------------------------------------------------------------------
    // orbtrace pipeline (clk100): tpiu_demux -> checksum -> cobs -> superframe
    // Proper valid/ready chaining (real back-pressure end to end).
    // ------------------------------------------------------------------
    wire        dmux_out_valid, dmux_out_last;
    wire [7:0]  dmux_data;
    wire        chk_in_ready;
    tpiu_demux u_dmux (
        .clk(clk100), .rst(sys_rst),
        .in_valid(cdc_out_valid), .in_ready(dmux_in_ready), .in_frame(dmux_in_frame),
        .bp_valid(1'b0), .bp_ready(), .bp_data(8'd0), .bypass_sel(1'b0),
        .out_valid(dmux_out_valid), .out_ready(chk_in_ready),
        .out_data(dmux_data), .out_last(dmux_out_last)
    );

    wire        chk_out_valid, chk_out_last;
    wire [7:0]  chk_data;
    wire        cobs_in_ready;
    checksum_appender u_chk (
        .clk(clk100), .rst(sys_rst),
        .in_valid(dmux_out_valid), .in_ready(chk_in_ready),
        .in_data(dmux_data), .in_last(dmux_out_last),
        .out_valid(chk_out_valid), .out_ready(cobs_in_ready),
        .out_data(chk_data), .out_last(chk_out_last)
    );

    wire        cobs_out_valid, cobs_out_last;
    wire [7:0]  cobs_data;
    wire        sf_in_ready;
    cobs_encoder u_cobs (
        .clk(clk100), .rst(sys_rst),
        .in_valid(chk_out_valid), .in_ready(cobs_in_ready),
        .in_data(chk_data), .in_last(chk_out_last),
        .out_valid(cobs_out_valid), .out_ready(sf_in_ready),
        .out_data(cobs_data), .out_last(cobs_out_last)
    );

    wire        sf_out_valid, sf_out_last;
    wire [7:0]  sf_data;
    wire        sf_out_ready;
    super_framer u_sf (
        .clk(clk100), .rst(sys_rst),
        .in_valid(cobs_out_valid), .in_ready(sf_in_ready),
        .in_data(cobs_data), .in_last(cobs_out_last),
        .out_valid(sf_out_valid), .out_ready(sf_out_ready),
        .out_data(sf_data), .out_last(sf_out_last)
    );

    // ------------------------------------------------------------------
    // One-shot OrbFlow byte capture (clk100). Byte-wide BRAM, fill until
    // full then freeze; super_framer is back-pressured by ~full.
    // ------------------------------------------------------------------
    localparam AW = $clog2(DEPTH);
    (* ram_style = "block" *)
    reg [7:0] capmem [0:DEPTH-1];
    reg [AW:0] wr_ptr;                  // extra bit = full
    wire full = wr_ptr[AW];
    assign sf_out_ready = ~full;        // accept OrbFlow bytes until full
    wire wr_en = sf_out_valid & sf_out_ready;
    always @(posedge clk100) begin
        if (wr_en) capmem[wr_ptr[AW-1:0]] <= sf_data;
    end
    always @(posedge clk100) begin
        if (sys_rst)    wr_ptr <= 0;
        else if (wr_en) wr_ptr <= wr_ptr + 1'b1;
    end

    // ------------------------------------------------------------------
    // UDP readout: ext_addr is a byte address straight into capmem.
    // ------------------------------------------------------------------
    wire [15:0] ext_addr;
    reg  [7:0]  cap_byte;
    always @(posedge clk125) cap_byte <= capmem[ext_addr[AW-1:0]];
    localparam [15:0] NB = DEPTH;
    wire [7:0] ext_data = (ext_addr < NB)        ? cap_byte :
                          (ext_addr == NB+0)     ? NB[7:0] :
                          (ext_addr == NB+1)     ? NB[15:8] :
                          (ext_addr == NB+2)     ? {7'b0, full} :
                          (ext_addr == NB+3)     ? trace_lost_cnt[7:0] :
                          (ext_addr == NB+4)     ? trace_lost_cnt[15:8] : 8'h00;

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
    assign led1 = ~full;     // off while filling, on (steady) when full

endmodule

`default_nettype wire
