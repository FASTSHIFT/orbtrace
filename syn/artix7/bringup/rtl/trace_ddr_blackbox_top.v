// trace_ddr_blackbox_top
// =======================
// Proposal 32 P2b (method X): on-chip logic-analyzer BLACK BOX.
// Taps trace bytes at the capture SOURCE (trace_capture_direct.cap_byte, in the
// TRACECLK domain) and records them into DDR3 via an INDEPENDENT AsyncFIFO,
// separate from any real-time path, as untainted ground truth for decoder
// cross-check. Status + (P2b-2) ring readback exposed over the :5001/:5556 path.
//
// P2b-1 (this step): capture -> la_ddr_writer -> DDR3 ring; expose writer
// status (calib, words_written, wr_ptr, wr_lost, TRACECLK activity) over :5001
// page 0xFF5x. Confirms trace bytes flow into DDR3 with no loss. The DDR3
// read-back/crosscheck (:5556) is P2b-2.
//
// Clocks (from the 50MHz board oscillator):
//   sys MMCM : 50 -> 125 / 125@90 / 100   (Ethernet + dbg, clk125)
//   clock IP : 50 -> 200                  (MIG sys_clk_i; MIG makes ui_clk=50)
//   TRACECLK : external, drives trace_capture_direct's own capture domain

`default_nettype none

module trace_ddr_blackbox_top #(
    parameter integer LENGTH   = 64,
    parameter [31:0]  BUILD_ID = 32'hDEADBEEF
) (
    input  wire        sys_clk_50,
    input  wire        rst_n,

    // RGMII (RTL8211E)
    input  wire        phy_rx_clk,
    input  wire [3:0]  phy_rxd,
    input  wire        phy_rx_ctl,
    output wire        phy_tx_clk,
    output wire [3:0]  phy_txd,
    output wire        phy_tx_ctl,
    output wire        phy_reset_n,
    inout  wire        phy_mdio,
    output wire        phy_mdc,

    // trace capture pins
    input  wire        trace_clk_in,
    input  wire [3:0]  trace_data_in,

    // DDR3
    output wire [14:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_cas_n,
    output wire [0:0]  ddr3_ck_n,
    output wire [0:0]  ddr3_ck_p,
    output wire [0:0]  ddr3_cke,
    output wire        ddr3_ras_n,
    output wire        ddr3_reset_n,
    output wire        ddr3_we_n,
    inout  wire [15:0] ddr3_dq,
    inout  wire [1:0]  ddr3_dqs_n,
    inout  wire [1:0]  ddr3_dqs_p,
    output wire [1:0]  ddr3_dm,
    output wire [0:0]  ddr3_odt,

    output wire        led0,          // sys mmcm locked
    output wire        led1           // black-box recording activity
);
    wire rst = ~rst_n;

    // ---- system clocks (50 -> 125 / 125@90 / 100) ----
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

    // ---- MIG reference clock (50 -> 200MHz) ----
    wire sys_clk_200, clk200_locked;
    clock u_clock (
        .clk_out1(sys_clk_200), .resetn(rst_n),
        .locked(clk200_locked), .clk_in1(sys_clk_50)
    );

    // ================= trace capture front-end (TRACECLK domain) ===========
    wire        cap_clk;       // == TRACECLK via BUFG (trace_capture_direct)
    wire        cap_clk90;     // same as cap_clk in direct mode
    wire [3:0]  trace_a, trace_b;
    wire        cap_locked;
    wire [7:0]  cap_byte;
    wire        cap_valid;
    wire        raw_clk_ibuf;
    wire [3:0]  raw_data_ibuf;
    trace_capture_direct #(.WIDTH(4)) u_cap (
        .rst(sys_rst),
        .trace_clk_p(trace_clk_in), .trace_data_p(trace_data_in),
        .trace_clk(cap_clk), .clk90_out(cap_clk90),
        .trace_a(trace_a), .trace_b(trace_b),
        .mmcm_locked(cap_locked),
        .raw_clk_ibuf(raw_clk_ibuf), .raw_data_ibuf(raw_data_ibuf),
        .cap_byte(cap_byte), .cap_valid(cap_valid)
    );

    // ================= DDR3 controller (ui_clk domain) =====================
    wire        ui_clk, ui_rst, ddr3_busy;
    wire        wr_start, wr_data_req, wr_addr_req, wr_done;
    wire [127:0]wr_data;
    wire [28:0] wr_addr;
    // read interface driven by la_ddr_reader (P2b-2 readback)
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

    // ================= black-box writer (method X) =========================
    wire [28:0] wr_ptr_words;
    wire [31:0] words_written, wr_lost_bytes;
    la_ddr_writer #(.LENGTH(LENGTH), .RING_BASE(29'd0),
                    .RING_WORDS(29'h0100000)) u_bb (   // 16MB ring
        .cap_clk(cap_clk), .cap_rst(sys_rst | ~cap_locked),
        .cap_byte(cap_byte), .cap_valid(cap_valid),
        .ui_clk(ui_clk), .ui_rst(ui_rst | ~calib_done), .ddr3_busy(ddr3_busy),
        .ddr3_wr_start(wr_start), .ddr3_wr_data_req(wr_data_req),
        .ddr3_wr_data(wr_data), .ddr3_wr_addr_req(wr_addr_req),
        .ddr3_wr_addr(wr_addr), .ddr3_wr_done(wr_done),
        .wr_ptr_words(wr_ptr_words), .words_written(words_written),
        .wr_lost_bytes(wr_lost_bytes)
    );

    // ================= black-box reader (P2b-2 readback) ===================
    // A :5002 CSR write to REG_ARM (0x20) arms a one-shot readback of
    // READ_WORDS 128-bit words from the ring start; the byte stream is sent via
    // the fpga_core_net self-TX path to the host (:5555), received by
    // trace_stream_rx.py. Host disables the STM32 ETM first so the ring is
    // static (clean snapshot) during readback.
    localparam [7:0] REG_ARM = 8'h20;
    localparam [31:0] READ_WORDS = 32'd262144;   // 256K words = 4MB snapshot
    reg  arm_125 = 0;
    always @(posedge clk125) arm_125 <= csr_we_w && (csr_addr_w == REG_ARM);

    wire [7:0] rb_tdata;
    wire       rb_tvalid, rb_tready, rb_busy;
    wire [1:0] rd_dbg_state;
    wire [31:0]rd_dbg_wleft, rd_dbg_wdone;
    la_ddr_reader #(.LENGTH(LENGTH), .RING_BASE(29'd0)) u_rd (
        .clk125(clk125), .sys_rst(sys_rst),
        .arm(arm_125), .read_words(READ_WORDS),
        .ui_clk(ui_clk), .ui_rst(ui_rst | ~calib_done),
        .ddr3_rd_start(rd_start), .ddr3_rd_addr_req(rd_addr_req),
        .ddr3_rd_addr(rd_addr), .ddr3_rd_data_vld(rd_data_vld),
        .ddr3_rd_data(rd_data), .ddr3_rd_done(rd_done),
        .stream_tdata(rb_tdata), .stream_tvalid(rb_tvalid),
        .stream_tready(rb_tready), .busy(rb_busy),
        .dbg_state(rd_dbg_state), .dbg_words_left(rd_dbg_wleft),
        .dbg_words_done(rd_dbg_wdone)
    );

    // ---- CDC ui_clk status -> clk125 (atomic toggle snapshot) ----
    reg        snap_tog = 0;
    reg [21:0] snap_div = 0;
    reg [31:0] snap_words, snap_lost;
    reg [28:0] snap_ptr;
    reg        snap_calib, snap_migcal;
    always @(posedge ui_clk) begin
        snap_div <= snap_div + 1'b1;
        if (&snap_div) begin
            snap_words  <= words_written;
            snap_lost   <= wr_lost_bytes;
            snap_ptr    <= wr_ptr_words;
            snap_calib  <= calib_done;
            snap_migcal <= mig_calib_raw;
            snap_tog    <= ~snap_tog;
        end
    end
    reg tog_s0=0, tog_s1=0, tog_s2=0;
    always @(posedge clk125) begin tog_s0<=snap_tog; tog_s1<=tog_s0; tog_s2<=tog_s1; end
    wire snap_valid = tog_s1 ^ tog_s2;
    reg [31:0] words_125=0, lost_125=0;
    reg [28:0] ptr_125=0;
    reg        calib_125=0, migcal_125=0;
    always @(posedge clk125) if (snap_valid) begin
        words_125 <= snap_words; lost_125 <= snap_lost; ptr_125 <= snap_ptr;
        calib_125 <= snap_calib; migcal_125 <= snap_migcal;
    end

    // ---- TRACECLK activity flag (cap_valid toggling), synced to clk125 ----
    reg cap_tog = 0;
    always @(posedge cap_clk) if (cap_valid) cap_tog <= ~cap_tog;
    reg ct0=0, ct1=0, ct2=0;
    always @(posedge clk125) begin ct0<=cap_tog; ct1<=ct0; ct2<=ct1; end
    reg [20:0] noact=0; reg traceclk_active=0;
    always @(posedge clk125) begin
        if (ct1^ct2) begin noact<=0; traceclk_active<=1'b1; end
        else if (!noact[20]) noact<=noact+1'b1; else traceclk_active<=1'b0;
    end

    // ================= Ethernet + dbg_regfile (clk125) =====================
    wire [7:0]  csr_addr_w, csr_data_w; wire csr_we_w;
    wire [15:0] ext_addr; wire [7:0] ext_data;
    wire dbg_rx_good, dbg_rx_bad, dbg_tx_valid;
    wire [1:0] dbg_selftx_state; wire dbg_selftx_stuck;
    wire dbg_tx_fifo_ovf, dbg_rx_fifo_ovf, dbg_rx_bad_frame;
    wire [7:0] dbg_rdata;
    dbg_regfile u_dbg (
        .clk(clk125), .rst(sys_rst), .clr(1'b0),
        .e_no_traceclk(1'b0), .e_mmcm_unlock(1'b0), .e_cap_overflow(1'b0),
        .e_selftx_stuck(dbg_selftx_stuck), .e_rx_bad_frame(dbg_rx_bad_frame),
        .e_tx_fifo_ovf(dbg_tx_fifo_ovf), .e_rx_fifo_ovf(dbg_rx_fifo_ovf),
        .sys_mmcm_locked(mmcm_sys_locked), .trace_mmcm_locked(calib_125),
        .traceclk_active(traceclk_active),
        .selftx_state(dbg_selftx_state), .pkt_active(1'b0),
        .lost_cnt(lost_125),
        .gpio_clk_level(1'b0), .gpio_data_level(4'd0),
        .gpio_clk_edge(1'b0), .gpio_data_edge(4'd0),
        .addr(ext_addr[7:0]), .rdata(dbg_rdata)
    );

    // readout page 0xFF5x: black-box status; 0xFF7x: BUILD_ID
    wire dbg_page = (ext_addr[15:8]==8'hFF) && (ext_addr[7:4]>=4'h1) && (ext_addr[7:4]<=4'h4);
    wire [7:0] bb_status =
        (ext_addr==16'hFF50) ? 8'hB0 :                            // MAGIC black-box
        (ext_addr==16'hFF51) ? {5'b0, traceclk_active, migcal_125, calib_125} :
        (ext_addr==16'hFF52) ? words_125[7:0]   :
        (ext_addr==16'hFF53) ? words_125[15:8]  :
        (ext_addr==16'hFF54) ? words_125[23:16] :
        (ext_addr==16'hFF55) ? words_125[31:24] :
        (ext_addr==16'hFF56) ? lost_125[7:0]    :
        (ext_addr==16'hFF57) ? lost_125[15:8]   :
        (ext_addr==16'hFF58) ? lost_125[23:16]  :
        (ext_addr==16'hFF59) ? lost_125[31:24]  :
        (ext_addr==16'hFF5A) ? ptr_125[7:0]     :
        (ext_addr==16'hFF5B) ? ptr_125[15:8]    :
        (ext_addr==16'hFF5C) ? ptr_125[23:16]   :
        (ext_addr==16'hFF5D) ? {3'b0, ptr_125[28:24]} :
        // reader observability (P2b-3 debug)
        (ext_addr==16'hFF60) ? {5'b0, rb_busy, rd_dbg_state} :
        (ext_addr==16'hFF61) ? rd_dbg_wleft[7:0]   :
        (ext_addr==16'hFF62) ? rd_dbg_wleft[15:8]  :
        (ext_addr==16'hFF63) ? rd_dbg_wleft[23:16] :
        (ext_addr==16'hFF64) ? rd_dbg_wleft[31:24] :
        (ext_addr==16'hFF65) ? rd_dbg_wdone[7:0]   :
        (ext_addr==16'hFF66) ? rd_dbg_wdone[15:8]  :
        (ext_addr==16'hFF67) ? rd_dbg_wdone[23:16] :
        (ext_addr==16'hFF68) ? rd_dbg_wdone[31:24] :
        (ext_addr==16'hFF70) ? BUILD_ID[7:0]    :
        (ext_addr==16'hFF71) ? BUILD_ID[15:8]   :
        (ext_addr==16'hFF72) ? BUILD_ID[23:16]  :
        (ext_addr==16'hFF73) ? BUILD_ID[31:24]  :
        8'h00;
    wire bb_page = (ext_addr[15:8]==8'hFF) &&
                   ((ext_addr[7:4]==4'h5) || (ext_addr[7:4]==4'h6) || (ext_addr[7:4]==4'h7));
    assign ext_data = dbg_page ? dbg_rdata : bb_page ? bb_status : 8'h00;

    // STREAM=1: the DDR3 ring readback (reader) is the self-TX source; on arm
    // it streams READ_WORDS*16 bytes to :5555 (received by trace_stream_rx.py).
    // Each packet carries the 4-byte seq prefix so the host detects any gap.
    fpga_core_net #(
        .TARGET("XILINX"), .STREAM(1),
        .UDP_CHECKSUM_GEN_ENABLE(0),
        .STREAM_DEST_IP({8'd192,8'd168,8'd10,8'd245}),
        .STREAM_DEST_PORT(16'd5555),
        // packet payload == one DDR3 read burst (64 words * 16 = 1024 bytes) so
        // each burst fills exactly one packet — no cross-burst straddling that
        // would leave a final partial packet wedging the self-TX FSM.
        .STREAM_PKT_BYTES(16'd1024)
    ) u_eth (
        .clk(clk125), .clk90(clk125_90), .rst(sys_rst),
        .btnu(1'b0), .btnl(1'b0), .btnd(1'b0), .btnr(1'b0), .btnc(1'b0),
        .sw(8'h0), .led(),
        .phy_rx_clk(phy_rx_clk), .phy_rxd(phy_rxd), .phy_rx_ctl(phy_rx_ctl),
        .phy_tx_clk(phy_tx_clk), .phy_txd(phy_txd), .phy_tx_ctl(phy_tx_ctl),
        .phy_reset_n(phy_reset_n), .phy_int_n(1'b1), .phy_pme_n(1'b1),
        .uart_rxd(1'b1), .uart_txd(),
        .dbg_rx_good_frame(dbg_rx_good), .dbg_rx_bad_fcs(dbg_rx_bad), .dbg_tx_axis_tvalid(dbg_tx_valid),
        .dbg_selftx_state(dbg_selftx_state), .dbg_selftx_stuck(dbg_selftx_stuck),
        .dbg_tx_fifo_overflow(dbg_tx_fifo_ovf), .dbg_rx_fifo_overflow(dbg_rx_fifo_ovf),
        .dbg_rx_bad_frame(dbg_rx_bad_frame),
        .ext_addr(ext_addr), .ext_data(ext_data),
        .csr_addr(csr_addr_w), .csr_data(csr_data_w), .csr_we(csr_we_w),
        .stream_tdata(rb_tdata), .stream_tvalid(rb_tvalid), .stream_tready(rb_tready)
    );

    // ---- LED ----
    reg [24:0] hb = 0;
    always @(posedge clk125) hb <= hb + 1'b1;
    assign led0 = mmcm_sys_locked;
    assign led1 = traceclk_active ? hb[24] : 1'b0;   // blink while recording

    assign phy_mdio = 1'bz;
    assign phy_mdc  = 1'b0;

endmodule

`default_nettype wire
