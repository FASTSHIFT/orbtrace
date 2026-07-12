// trace_pin_la_top
// ================
// RAW PIN LOGIC-ANALYZER (proposal 32 P2b, pin-level variant).
//
// Instead of the byte-level black-box (trace_ddr_blackbox_top which taps
// cap_byte after IDDR), this top samples the 5 TRACE pins DIRECTLY in the
// 200 MHz clk domain and writes to DDR3. Purpose: reproduce the "F429 84 M
// clean, H743 50 M dirty" asymmetry at the physical layer so we can *pin the
// blame* to a specific pin or edge (SI, source impedance, wrong TRACECLK
// slew, GPIO pin conflict etc.) rather than guessing at software.
//
// Sample format (1 byte per clk200 tick, 5 ns period):
//   bit[7:5] = 3'b0 (reserved / can host a debug tag later)
//   bit[4]   = TRACECLK  (post-IBUF, single-ended level)
//   bit[3]   = TRACED[3]
//   bit[2]   = TRACED[2]
//   bit[1]   = TRACED[1]
//   bit[0]   = TRACED[0]
//
// At 200 MSPS with a 16 MB ring the LA stores ~4.2 ms of continuous 5-lane
// waveform, more than enough to hold the boot-then-func_test window.
//
// Everything else (DDR3 controller, la_ddr_writer/reader, fpga_core_net,
// dbg_regfile) is identical to trace_ddr_blackbox_top; only the tap point
// changes.

`default_nettype none

module trace_pin_la_top #(
    parameter integer LENGTH = 64
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

    // DDR3
    inout  wire [15:0] ddr3_dq,
    inout  wire [1:0]  ddr3_dqs_n, ddr3_dqs_p,
    output wire [14:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_ras_n, ddr3_cas_n, ddr3_we_n, ddr3_reset_n,
    output wire        ddr3_ck_p, ddr3_ck_n,
    output wire        ddr3_cke, ddr3_odt,
    output wire [1:0]  ddr3_dm,

    output wire        led0, led1
);
    wire rst = ~rst_n;

    // ---- system clocks: 50 -> 125 / 125@90 / 100 ----
    wire clkfb, clk125_u, clk125_90_u, clk100_u, mmcm_sys_locked;
    MMCME2_BASE #(
        .CLKIN1_PERIOD(20.0), .CLKFBOUT_MULT_F(20.0), .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(8.0),
        .CLKOUT1_DIVIDE(8), .CLKOUT1_PHASE(90.0),
        .CLKOUT3_DIVIDE(10),
        .CLKOUT0_PHASE(0.0), .CLKOUT3_PHASE(0.0)
    ) u_sysmmcm (
        .CLKIN1(sys_clk_50), .CLKFBIN(clkfb), .CLKFBOUT(clkfb),
        .CLKOUT0(clk125_u), .CLKOUT1(clk125_90_u), .CLKOUT3(clk100_u),
        .LOCKED(mmcm_sys_locked), .RST(rst), .PWRDWN(1'b0)
    );
    wire clk125, clk125_90, clk100;
    BUFG b0(.I(clk125_u), .O(clk125));
    BUFG b1(.I(clk125_90_u), .O(clk125_90));
    BUFG b3(.I(clk100_u), .O(clk100));

    reg [3:0] rst_sync = 4'hf;
    always @(posedge clk125 or posedge rst)
        if (rst) rst_sync <= 4'hf;
        else     rst_sync <= {rst_sync[2:0], ~mmcm_sys_locked};
    wire sys_rst = rst_sync[3];

    // ---- MIG 200 MHz reference clock (also used as our LA sample clock) ----
    wire sys_clk_200, clk200_locked;
    clock u_clock (
        .clk_out1(sys_clk_200), .resetn(rst_n),
        .locked(clk200_locked), .clk_in1(sys_clk_50)
    );

    // ---- IBUF the 5 trace pins (post-IBUF level = what our IDDR sees) ----
    wire tclk_ibuf;
    wire [3:0] tdata_ibuf;
    IBUF u_ib_c (.I(trace_clk_in),     .O(tclk_ibuf));
    IBUF u_ib_0 (.I(trace_data_in[0]), .O(tdata_ibuf[0]));
    IBUF u_ib_1 (.I(trace_data_in[1]), .O(tdata_ibuf[1]));
    IBUF u_ib_2 (.I(trace_data_in[2]), .O(tdata_ibuf[2]));
    IBUF u_ib_3 (.I(trace_data_in[3]), .O(tdata_ibuf[3]));

    // ---- pin-level sampler in the 200 MHz domain ----
    // Simple double-flop synchroniser per line (tolerate metastability). This
    // is a *pin activity* recorder, not a source-synchronous receiver, so we
    // do not need edge-centred sampling.
    reg [4:0] pin_s0 = 0, pin_s1 = 0;
    always @(posedge sys_clk_200) begin
        pin_s0 <= {tclk_ibuf, tdata_ibuf};
        pin_s1 <= pin_s0;
    end
    wire [7:0] la_byte  = {3'b000, pin_s1};
    // Continuously valid. Freeze gate is driven from the reader (busy).

    // ---- DDR3 controller ----
    wire        ui_clk, ui_rst, ddr3_busy;
    wire        wr_start, wr_data_req, wr_addr_req, wr_done;
    wire [127:0]wr_data;
    wire [28:0] wr_addr;
    wire        rd_start, rd_addr_req, rd_data_vld, rd_done;
    wire [28:0] rd_addr;
    wire [127:0]rd_data;
    wire        mig_calib_raw;

    ddr3_ctrl u_ddr3 (
        .sys_clk(sys_clk_200), .sys_rst_n(clk200_locked & mmcm_sys_locked),
        .ui_clk(ui_clk), .ui_rst(ui_rst), .calib_complete(mig_calib_raw),
        .ddr3_busy(ddr3_busy),
        .ddr3_wr_start(wr_start), .ddr3_wr_data_req(wr_data_req),
        .ddr3_wr_data(wr_data), .ddr3_wr_addr_req(wr_addr_req),
        .ddr3_wr_addr(wr_addr), .ddr3_wr_done(wr_done),
        .ddr3_rd_start(rd_start), .ddr3_rd_addr_req(rd_addr_req),
        .ddr3_rd_addr(rd_addr), .ddr3_rd_data_vld(rd_data_vld),
        .ddr3_rd_data(rd_data), .ddr3_rd_done(rd_done),
        .ddr3_addr(ddr3_addr), .ddr3_ba(ddr3_ba), .ddr3_cas_n(ddr3_cas_n),
        .ddr3_ck_n(ddr3_ck_n), .ddr3_ck_p(ddr3_ck_p), .ddr3_cke(ddr3_cke),
        .ddr3_ras_n(ddr3_ras_n), .ddr3_reset_n(ddr3_reset_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_dq(ddr3_dq), .ddr3_dqs_n(ddr3_dqs_n), .ddr3_dqs_p(ddr3_dqs_p),
        .ddr3_dm(ddr3_dm), .ddr3_odt(ddr3_odt)
    );

    reg calib_done = 0;
    always @(posedge ui_clk) if (!ui_rst) calib_done <= 1'b1;

    // ---- black-box writer: la_byte (@ 200 MHz) -> DDR3 ring ----
    // Ring 16 MB = 1M 128-bit words. 200 MHz * 1 B/tick = 200 MB/s of writes;
    // DDR3 sustains far more, so drop should be zero.
    wire [28:0] wr_ptr_words;
    wire [31:0] words_written, wr_lost_bytes;
    la_ddr_writer #(.LENGTH(LENGTH), .RING_BASE(29'd0),
                    .RING_WORDS(29'h0800000)) u_bb (
        .cap_clk(sys_clk_200), .cap_rst(sys_rst),
        .cap_byte(la_byte), .cap_valid_in(1'b1), .freeze(rb_busy),
        .ui_clk(ui_clk), .ui_rst(ui_rst | ~calib_done), .ddr3_busy(ddr3_busy),
        .ddr3_wr_start(wr_start), .ddr3_wr_data_req(wr_data_req),
        .ddr3_wr_data(wr_data), .ddr3_wr_addr_req(wr_addr_req),
        .ddr3_wr_addr(wr_addr), .ddr3_wr_done(wr_done),
        .wr_ptr_words(wr_ptr_words), .words_written(words_written),
        .wr_lost_bytes(wr_lost_bytes)
    );

    // ---- reader (P2b-2 readback via :5555 self-TX) ----
    localparam [7:0] REG_ARM = 8'h20;
    localparam [31:0] READ_WORDS = 32'd262144;   // 256K words = 4 MB snapshot
    // read the most-recently-written region
    wire [15:0] ext_addr;
    wire [7:0]  ext_data;
    wire [7:0]  csr_addr_w, csr_data_w;
    wire        csr_we_w;
    reg  arm_125 = 0;
    always @(posedge clk125) arm_125 <= csr_we_w && (csr_addr_w == REG_ARM);

    localparam [28:0] RING_APP = 29'h0800000;
    wire [28:0] READ_SPAN = READ_WORDS[25:0] << 3;
    reg [28:0] wrptr_c0=0, wrptr_c1=0;
    always @(posedge clk125) begin wrptr_c0<=wr_ptr_words; wrptr_c1<=wrptr_c0; end
    wire [28:0] rd_start_addr =
        (wrptr_c1 >= READ_SPAN) ? (wrptr_c1 - READ_SPAN)
                                : (RING_APP + wrptr_c1 - READ_SPAN);

    wire [7:0] rb_tdata;
    wire       rb_tvalid, rb_tready, rb_busy;
    wire [1:0] rd_dbg_state;
    wire [31:0]rd_dbg_wleft, rd_dbg_wdone;
    la_ddr_reader #(.LENGTH(LENGTH), .RING_BASE(29'd0)) u_rd (
        .clk125(clk125), .sys_rst(sys_rst),
        .arm(arm_125), .read_words(READ_WORDS), .start_addr(rd_start_addr),
        .ui_clk(ui_clk), .ui_rst(ui_rst | ~calib_done),
        .ddr3_rd_start(rd_start), .ddr3_rd_addr_req(rd_addr_req),
        .ddr3_rd_addr(rd_addr), .ddr3_rd_data_vld(rd_data_vld),
        .ddr3_rd_data(rd_data), .ddr3_rd_done(rd_done),
        .stream_tdata(rb_tdata), .stream_tvalid(rb_tvalid),
        .stream_tready(rb_tready), .busy(rb_busy),
        .dbg_state(rd_dbg_state), .dbg_words_left(rd_dbg_wleft),
        .dbg_words_done(rd_dbg_wdone)
    );

    // ---- Ethernet (readback stream + CSR/status paged readout) ----
    // status readout (paged): expose la_byte live-level + counters.
    wire [7:0] status_byte =
        (ext_addr == 16'hFF00) ? words_written[7:0]  :
        (ext_addr == 16'hFF01) ? words_written[15:8] :
        (ext_addr == 16'hFF02) ? words_written[23:16]:
        (ext_addr == 16'hFF03) ? words_written[31:24]:
        (ext_addr == 16'hFF04) ? wr_lost_bytes[7:0]  :
        (ext_addr == 16'hFF05) ? wr_lost_bytes[15:8] :
        (ext_addr == 16'hFF06) ? wr_lost_bytes[23:16]:
        (ext_addr == 16'hFF07) ? wr_lost_bytes[31:24]:
        (ext_addr == 16'hFF08) ? la_byte             :
        (ext_addr == 16'hFF09) ? {6'b0, calib_done, mig_calib_raw} :
        (ext_addr == 16'hFF0A) ? {6'b0, rd_dbg_state}:
        (ext_addr == 16'hFF0B) ? rd_dbg_wleft[7:0]   :
        (ext_addr == 16'hFF0C) ? rd_dbg_wleft[15:8]  :
        (ext_addr == 16'hFF0D) ? rd_dbg_wdone[7:0]   :
        (ext_addr == 16'hFF0E) ? rd_dbg_wdone[15:8]  :
        (ext_addr == 16'hFF70) ? 8'h4C : // 'L' for LA
        (ext_addr == 16'hFF71) ? 8'h41 : // 'A'
        8'h00;
    assign ext_data = status_byte;

    fpga_core_net #(
        .TARGET("XILINX"),
        .STREAM(1),
        .UDP_CHECKSUM_GEN_ENABLE(0),
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
        .dbg_selftx_state(), .dbg_selftx_stuck(),
        .dbg_tx_fifo_overflow(), .dbg_rx_fifo_overflow(),
        .dbg_rx_bad_frame(),
        .ext_addr(ext_addr), .ext_data(ext_data),
        .csr_addr(csr_addr_w), .csr_data(csr_data_w), .csr_we(csr_we_w),
        .stream_tdata(rb_tdata), .stream_tvalid(rb_tvalid & rb_busy),
        .stream_tready(rb_tready)
    );

    assign led0 = calib_done;
    assign led1 = rb_busy;
    assign phy_mdio = 1'bz;
    assign phy_mdc  = 1'b0;
endmodule

`default_nettype wire
